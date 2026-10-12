// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "forge-std/mocks/MockERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey as V4PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {LARP} from "../src/LARP.sol";
import {ILARP} from "../src/ILARP.sol";
import {IMDNames} from "../src/IMDNames.sol";
import {IIMDNames} from "../src/IIMDNames.sol";
import {LARPLinks} from "../src/LARPLinks.sol";
import {LARPBurner} from "../src/LARPBurner.sol";
import {Attestation} from "../src/SwarmPrices.sol";
import {MockNFT} from "./Mocks.sol";

/// @dev An ERC-1155 with the one read LARP makes, a free mint and a transfer.
contract Mock1155 {
    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[to][id] += amount;
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata) external {
        require(msg.sender == from, "not yours");
        balanceOf[from][id] -= amount;
        balanceOf[to][id] += amount;
    }

    function uri(uint256) external pure returns (string memory) {
        return "item://{id}";
    }
}

/// @dev $IMD for tests.
contract MockIMD is MockERC20 {
    constructor() {
        initialize("IMD", "IMD", 18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev IMD6900 for tests: anyone burns their own.
contract MockIMD6900 is MockERC20 {
    constructor() {
        initialize("IMD6900", "IMD6900", 18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external virtual {
        _burn(msg.sender, amount);
    }
}

/// @dev Adds full-range liquidity to a v4 pool (native ETH or ERC-20s), paid by the caller.
contract LiquidityAdder {
    IPoolManager immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function add(V4PoolKey memory key, int256 liquidity) external payable {
        pm.unlock(abi.encode(key, liquidity, msg.sender));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (V4PoolKey memory key, int256 liquidity, address payer) = abi.decode(data, (V4PoolKey, int256, address));
        (BalanceDelta delta,) = pm.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), liquidity, 0
            ),
            ""
        );
        _pay(key.currency0, uint256(uint128(-delta.amount0())), payer);
        _pay(key.currency1, uint256(uint128(-delta.amount1())), payer);
        if (address(this).balance > 0) payable(payer).transfer(address(this).balance);
        return "";
    }

    function _pay(Currency currency, uint256 amount, address payer) internal {
        if (Currency.unwrap(currency) == address(0)) {
            pm.settle{value: amount}();
        } else {
            pm.sync(currency);
            MockIMD(Currency.unwrap(currency)).transferFrom(payer, address(pm), amount);
            pm.settle();
        }
    }

    receive() external payable {}
}

/// @dev IMD's oracle Intake, as far as LARP uses it: takes the $IMD and the ask, and (as IMD's writer) hands the
/// verdict to the callback.
contract MockIntake {
    struct Ask {
        address payer;
        bytes body;
        address target;
        bytes4 selector;
        bytes4 onFailure;
        uint256 amount;
    }

    address public immutable treasury = address(0x7EA5);
    uint256 public count;
    bytes32 public nextRequestId;
    mapping(bytes32 => Ask) public asks;
    bytes public lastBody;

    /// @dev A published signature vector has a fixed request id; its proposal must use that same id.
    function setNextRequestId(bytes32 requestId) external {
        nextRequestId = requestId;
    }

    function requestWithFailure(
        bytes32,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external returns (bytes32 requestId) {
        require(amount >= 0.5 ether, "PriceNotMet");
        MockIMD(asset).transferFrom(msg.sender, treasury, amount);
        requestId = keccak256(abi.encode("intake", ++count));
        if (nextRequestId != bytes32(0)) {
            requestId = nextRequestId;
            delete nextRequestId;
        }
        asks[requestId] = Ask(msg.sender, body, callback.target, callback.selector, onFailure, amount);
        lastBody = body;
    }

    struct Callback {
        address target;
        bytes4 selector;
    }

    function deliver(bytes32 requestId, Attestation calldata a, bytes calldata sig) external returns (bool ok) {
        Ask storage ask = asks[requestId];
        (ok,) = ask.target.call{gas: 200_000}(abi.encodeWithSelector(ask.selector, requestId, a, sig));
    }

    function fail(bytes32 requestId, uint8 status, bytes32 reason) external returns (bool ok) {
        Ask storage ask = asks[requestId];
        (ok,) = ask.target.call{gas: 200_000}(
            abi.encodeWithSelector(ask.onFailure, requestId, status, reason, uint16(0), uint16(0), bytes(""))
        );
    }
}

/// @dev IMD's launcher, as far as LARP links reads it.
contract MockLauncher {
    mapping(uint64 => address) public distributorOf;

    function set(uint64 launch, address distributor) external {
        distributorOf[launch] = distributor;
    }
}

/// @dev A swarm airdrop, as far as LARP links reads it: roots per round, who claimed, the token. claim() pays out.
contract MockDistributor {
    address public immutable token;
    mapping(uint256 => bytes32) internal _roots;
    mapping(uint256 => mapping(address => bool)) public claimed;

    constructor(address token_) {
        token = token_;
    }

    function setRoot(uint256 round, bytes32 root) external {
        _roots[round] = root;
    }

    function roundOf(uint256 round) external view returns (bytes32, uint256, uint256, uint64) {
        require(_roots[round] != 0, "no round");
        return (_roots[round], 1e26, 0, 1);
    }

    function claim(uint256 round, address account, uint256 amount) external {
        claimed[round][account] = true;
        MockIMD(token).mint(account, amount);
    }
}

abstract contract Base is Test {
    // Uniswap v4's MIN_SQRT_PRICE + 1, as LARPBurner uses
    uint160 constant MIN_PRICE_LIMIT = 4295128740;

    address constant IMD_BURN = 0xe29386719C155B6847aD5a4E97C6674f10ffc750; // IMD's burn, its BurnExecutor: where LARP's $IMD goes

    MockNFT identity;
    MockIMD imd;
    MockIMD6900 imd6900;
    PoolManager pm;
    LiquidityAdder adder;
    V4PoolKey pool4;
    V4PoolKey backup;
    V4PoolKey pair;

    LARPBurner burner;
    MockIntake intake;
    uint256 oracleKey = 0x0A11CE0;
    address oracleSigner;
    LARP larp;
    IMDNames names;
    LARPLinks links;
    MockLauncher launcher;
    address artist = makeAddr("artist");

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    /// @dev The protocol on a local PoolManager, with POOL4 (1%, spacing 60) and the backup pool (1%, spacing 200)
    /// at 1 ETH ~ 2,000 IMD, and the IMD6900/IMD pair pool (no fee, spacing 60) at 1 IMD ~ 10,000 IMD6900, all
    /// initialized and empty.
    function _deploy() internal {
        identity = new MockNFT("identity://");
        imd = new MockIMD();
        imd6900 = new MockIMD6900();
        pm = new PoolManager(address(this));
        adder = new LiquidityAdder(IPoolManager(address(pm)));
        launcher = new MockLauncher();
        pool4 = V4PoolKey(Currency.wrap(address(0)), Currency.wrap(address(imd)), 10_000, 60, IHooks(address(0)));
        backup = V4PoolKey(Currency.wrap(address(0)), Currency.wrap(address(imd)), 10_000, 200, IHooks(address(0)));
        // tick ~ ln(2000)/ln(1.0001) ~ 76,000
        pm.initialize(pool4, TickMath.getSqrtPriceAtTick(76_020));
        pm.initialize(backup, TickMath.getSqrtPriceAtTick(76_000));
        bool imdIs0 = address(imd) < address(imd6900);
        pair = imdIs0
            ? V4PoolKey(Currency.wrap(address(imd)), Currency.wrap(address(imd6900)), 0, 60, IHooks(address(0)))
            : V4PoolKey(Currency.wrap(address(imd6900)), Currency.wrap(address(imd)), 0, 60, IHooks(address(0)));
        // price = currency1 per currency0: 10,000 IMD6900 per IMD (tick ~92,100), or its inverse
        pm.initialize(pair, TickMath.getSqrtPriceAtTick(imdIs0 ? int24(92_100) : int24(-92_100)));

        // the burner knows IMD Names (the swarm's IMD6900 share) before it exists, as the launch's CREATE3 placement
        // does: here, the address IMD Names gets three creations later (MockIntake, LARP, IMDNames)
        burner = _newBurner(address(pm), vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3));
        intake = new MockIntake();
        oracleSigner = vm.addr(oracleKey);
        larp = new LARP(address(identity));
        names = new IMDNames(address(identity), larp, address(burner), artist, address(intake), oracleSigner);
        links = new LARPLinks(address(identity), address(launcher), larp, names, address(burner));
        imd.mint(address(this), 1e30);
        imd.approve(address(adder), type(uint256).max);
        imd6900.mint(address(this), 1e33);
        imd6900.approve(address(adder), type(uint256).max);
        vm.deal(address(this), 10_000 ether);
    }

    function _newBurner(address poolManager, address names_) internal returns (LARPBurner) {
        return new LARPBurner(
            poolManager, address(imd), 10_000, 60, address(0), 10_000, 200, address(imd6900), 0, 60, address(0), names_
        );
    }

    function _newBurner(address poolManager) internal returns (LARPBurner) {
        return _newBurner(poolManager, address(0));
    }

    function _fillPair() internal {
        adder.add(pair, 1e23);
    }

    /// @dev The most $IMD one burn sells into a pair pool, as the burner caps it (PAIR_LEG_BPS): 2% of the pool's
    /// virtual $IMD reserve at its price (liquidity / sqrtPrice with $IMD as currency0, liquidity * sqrtPrice as
    /// currency1), 0 for an empty pool. Computed independently from the PoolManager's state.
    function _pairRoomOf(V4PoolKey memory key) internal view returns (uint256) {
        (uint160 sqrtPrice,,,) = StateLibrary.getSlot0(IPoolManager(address(pm)), PoolIdLibrary.toId(key));
        uint128 liquidity = StateLibrary.getLiquidity(IPoolManager(address(pm)), PoolIdLibrary.toId(key));
        if (sqrtPrice == 0 || liquidity == 0) return 0;
        uint256 reserve = Currency.unwrap(key.currency0) == address(imd)
            ? FullMath.mulDiv(liquidity, 1 << 96, sqrtPrice)
            : FullMath.mulDiv(liquidity, sqrtPrice, 1 << 96);
        return reserve * 200 / 10_000;
    }

    function _pairRoom() internal view returns (uint256) {
        return _pairRoomOf(pair);
    }

    function _fillPool4() internal {
        adder.add{value: 1_000 ether}(pool4, 1e21);
    }

    function _fillBackup() internal {
        adder.add{value: 1_000 ether}(backup, 1e21);
    }

    function _register(address who, string memory label) internal returns (uint256 tokenId) {
        bytes32 l = _label(label);
        uint256 price = names.priceOf(l);
        vm.deal(who, who.balance + price);
        vm.prank(who);
        tokenId = names.register{value: price}(l, who, 0);
    }

    function _label(string memory s) internal pure returns (bytes32 label) {
        assembly {
            label := mload(add(s, 0x20))
        }
        uint256 n = bytes(s).length;
        if (n < 32) label &= ~bytes32(type(uint256).max >> (8 * n));
    }

    receive() external payable {}
}
