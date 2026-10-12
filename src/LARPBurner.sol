// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @dev The few Uniswap v4 PoolManager types and calls the burner needs (ABI-identical to v4-core's).
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManagerLike {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
    function extsload(bytes32 slot) external view returns (bytes32);
}

interface IBurnable {
    function burn(uint256 amount) external;
}

/// @dev IMD Names: the swarm-voted share of the $IMD that buys IMD6900 (SwarmPrices)
interface IShareSource {
    function imd6900ShareBps() external view returns (uint256);
}

/// @title LARP burner: every fee buys $IMD and burns it, by the IMD6900 frens
/// @notice Every fee and royalty of the LARP protocol ends here, as ETH or as $IMD, and leaves only burned.
/// - ETH buys $IMD: on POOL4, IMD's ETH/$IMD pool, so every fee is volume there; if POOL4 can't take the trade, on the
///   hookless ETH/$IMD pool (1%, tick spacing 200), which nobody can close; if neither can, the ETH waits here for
///   anyone's next `burn`.
/// - Of the $IMD, a share the IMD swarm votes (IMD Names' `imd6900ShareBps`: 6.9% at launch, anywhere from 0 to 100%)
///   buys IMD6900 on the IMD6900/$IMD pool, buying pressure, and that IMD6900 is burned (its supply shrinks). The rest
///   goes to IMD's own burn, its BurnExecutor (IMD_BURN), which anyone can send on to Base, where it is burned out of
///   $IMD's supply. If the IMD6900 buy can't happen, that share goes to IMD's burn too. One call sells the pool at most
///   2% of its own $IMD depth (PAIR_LEG_BPS): a leg that small is a loss to sandwich through the pair's fee, whatever
///   the swarm's share; what the share makes above it goes to IMD's burn.
/// @dev No owner, no roles, no upgrades. At most MAX_BURN of ETH is spent per call, and of the ETH that was already
/// waiting here at most MAX_BURN leaves per block, however many calls: small trades aren't worth sandwiching against
/// these pools' fees, and a batch of calls in one transaction can't make a big one. Royalties a market paid in WETH
/// are unwrapped on the way. A leg that runs code a third party controls (POOL4's hook; the pair hook and IMD6900)
/// gets a fixed gas budget: a caller can't starve it, and if it eats the whole budget it is skipped, not fatal.
contract LARPBurner {
    /// @notice Where $IMD goes: IMD's own burn, its BurnExecutor on Ethereum. It holds the $IMD it is sent until anyone
    /// calls its `bridgeToBaseBurnReceiver` (paying LayerZero's fee), which sends it to Base, where a contract with no
    /// owner burns it (`burn()`, anyone). IMD (its owner) can redirect or rescue what it holds: the same trust as every
    /// other $IMD burn, unlike 0x…dEaD, which parks $IMD without lowering its supply.
    address public constant IMD_BURN = 0xe29386719C155B6847aD5a4E97C6674f10ffc750;
    /// @notice The most ETH one call spends, and the most of the ETH that was already waiting here that leaves per
    /// block (the rest waits for the next block). A caller's own fee, up to this, always goes through.
    uint256 public constant MAX_BURN = 0.1 ether;
    /// @dev The gas a leg that runs third-party code gets (route 0 through POOL4's hook; the IMD6900 leg through the
    /// pair hook and IMD6900's proxy): several times the heaviest leg measured (~800k). A caller who can't fund the
    /// whole budget is refused before the try; a leg that spends all of it fails on its own account and is skipped.
    uint256 internal constant LEG_GAS = 3_000_000;
    /// @dev What a call needs after a budgeted leg was refused: the send to IMD_BURN (or the next route's own check) and
    /// its events.
    uint256 internal constant AFTER_GAS = 150_000;
    /// @dev WETH9 on Ethereum: royalties paid in WETH (offers on Seaport, Blur) are unwrapped and sold with the ETH.
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    /// @notice The share of the $IMD that buys IMD6900 on the IMD6900/$IMD pool, in basis points, until the swarm sets
    /// another, and whenever IMD Names can't answer (see `shareBps`).
    uint256 public constant POOL_SHARE_BPS = 690;
    /// @notice The most the swarm's share can be: all of it.
    uint256 public constant MAX_SHARE_BPS = 10_000;
    /// @dev The most $IMD one call sells into the IMD6900/$IMD pool, as a share of the pool's own $IMD depth (the
    /// virtual $IMD reserve its liquidity and price make, read from the PoolManager): 2%, so the leg moves the pool's
    /// price by about that much, which the pair's 6.9% fee each way makes a loss to sandwich at any swarm share (the
    /// break-even is near 10%). What the share makes above it goes to IMD's burn, as a failed leg's share does. At
    /// launch the pool holds ~125 $IMD and MAX_BURN buys ~25, so 6.9% of a full burn (1.7 $IMD) fits under the cap
    /// (2.5 $IMD); the swarm raising the share above what the pool can take sends the excess to IMD's burn, never to
    /// a searcher.
    uint256 internal constant PAIR_LEG_BPS = 200;
    /// @dev The gas IMD Names' share read gets: a storage read, with room.
    uint256 internal constant SHARE_GAS = 30_000;
    /// @dev v4-core TickMath.MIN_SQRT_PRICE + 1 and MAX_SQRT_PRICE - 1: trade as far as the pool goes.
    uint160 internal constant MIN_PRICE_LIMIT = 4295128740;
    uint160 internal constant MAX_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341;
    uint256 private constant _LOCK = uint256(keccak256("larp.burner.lock"));
    uint8 internal constant TO_PAIR = 2;

    /// @notice Uniswap v4's PoolManager.
    IPoolManagerLike public immutable POOL_MANAGER;
    /// @notice $IMD.
    address public immutable IMD;
    /// @notice The first ETH route, POOL4: fee, tick spacing and hook.
    uint24 public immutable POOL4_FEE;
    int24 public immutable POOL4_SPACING;
    address public immutable POOL4_HOOK;
    /// @notice The second ETH route, the hookless pool: fee and tick spacing.
    uint24 public immutable BACKUP_FEE;
    int24 public immutable BACKUP_SPACING;
    /// @notice IMD6900, and its $IMD pool: fee, tick spacing and hook.
    address public immutable IMD6900;
    uint24 public immutable PAIR_FEE;
    int24 public immutable PAIR_SPACING;
    address public immutable PAIR_HOOK;
    /// @notice IMD Names, whose swarm-voted `imd6900ShareBps` sets the IMD6900 share (zero: always POOL_SHARE_BPS).
    address public immutable NAMES;

    /// @dev The block in which ETH that was already waiting here was last spent, and how much of it in that block.
    uint64 internal _burnBlock;
    uint192 internal _burnedInBlock;

    /// @notice `eth` bought `imd` $IMD on route `route` (0 = POOL4, 1 = the hookless pool).
    event Bought(uint256 eth, uint256 imd, uint8 route);
    /// @notice No route could take `eth`: it waits here for the next `burn`.
    event Parked(uint256 eth);
    /// @notice `imdSpent` $IMD bought `imd6900Burned` IMD6900, burned; `imdBurned` $IMD went to IMD's burn (IMD_BURN).
    event Burned(uint256 imdBurned, uint256 imdSpent, uint256 imd6900Burned);

    error ZeroAddress();
    error NotPoolManager();
    error TooLittleIMD();
    error TooLittleGas();
    error Reentered();
    error Unfilled();
    error NoPrice();
    error TransferFailed();
    /// @notice A tick spacing above Uniswap v4's largest (32767).
    error BadSpacing();

    constructor(
        address poolManager,
        address imd,
        uint24 pool4Fee,
        uint24 pool4Spacing,
        address pool4Hook,
        uint24 backupFee,
        uint24 backupSpacing,
        address imd6900,
        uint24 pairFee,
        uint24 pairSpacing,
        address pairHook,
        address names
    ) {
        if (poolManager == address(0) || imd == address(0) || imd6900 == address(0)) {
            revert ZeroAddress();
        }
        POOL_MANAGER = IPoolManagerLike(poolManager);
        IMD = imd;
        POOL4_FEE = pool4Fee;
        POOL4_SPACING = _spacing(pool4Spacing);
        POOL4_HOOK = pool4Hook;
        BACKUP_FEE = backupFee;
        BACKUP_SPACING = _spacing(backupSpacing);
        IMD6900 = imd6900;
        PAIR_FEE = pairFee;
        PAIR_SPACING = _spacing(pairSpacing);
        PAIR_HOOK = pairHook;
        NAMES = names;
    }

    /// @notice The share of the $IMD that buys IMD6900 now, in basis points: IMD Names' swarm-voted one, or
    /// POOL_SHARE_BPS (6.9%) if IMD Names isn't there, doesn't answer within SHARE_GAS, or answers more than all.
    function shareBps() public view returns (uint256) {
        address n = NAMES;
        if (n.code.length == 0) return POOL_SHARE_BPS;
        (bool ok, bytes memory r) =
            n.staticcall{gas: SHARE_GAS}(abi.encodeWithSelector(IShareSource.imd6900ShareBps.selector));
        if (!ok || r.length != 32) return POOL_SHARE_BPS;
        uint256 s = abi.decode(r, (uint256));
        return s > MAX_SHARE_BPS ? POOL_SHARE_BPS : s;
    }

    /// @dev A tick spacing, taken unsigned (deployers' manifests take no signed constructor arguments) and stored as the
    /// int24 every PoolKey uses. v4's spacings run from 1 to 32767 (TickMath.MAX_TICK_SPACING).
    function _spacing(uint24 s) private pure returns (int24) {
        if (s > 32767) revert BadSpacing();
        return int24(s);
    }

    /// @dev One burn at a time: a burn can't run inside a burn.
    modifier locked() {
        uint256 slot = _LOCK;
        bool busy;
        assembly {
            busy := tload(slot)
        }
        if (busy) revert Reentered();
        assembly {
            tstore(slot, 1)
        }
        _;
        assembly {
            tstore(slot, 0)
        }
    }

    /// @notice Fees and royalties in ETH arrive here; anyone can send.
    receive() external payable {}

    /// @notice Spends the ETH here (with what is sent), up to MAX_BURN, on $IMD (POOL4, else the hookless pool), then
    /// burns all the $IMD here (the swarm's share through IMD6900). Reverts if the sender's own ETH bought less than
    /// `minImd`; with no route, the ETH waits and this reverts only if `minImd` is set.
    /// @dev What is sent goes first, up to MAX_BURN; the rest of the call's cap comes from the ETH that was already
    /// waiting here (fees above the cap, royalties, parked fees), of which at most MAX_BURN leaves per block, so a
    /// batch of calls in one transaction sells no more than one call would. `minImd` is checked against the sender's
    /// own part of what this call bought (its share of the one sale, pro rata: the ETH already waiting can't make up
    /// for a fee sold at a bad price); with a fee above MAX_BURN, that is the first MAX_BURN of it. A call that sends
    /// nothing checks `minImd` against the whole sale. Needs a gas limit of about 3.4M (LEG_GAS for the POOL4 leg and
    /// again for the IMD6900 leg, sequentially); less is refused, never degraded.
    function burn(uint256 minImd) external payable locked returns (uint256 imd) {
        _unwrapWeth();
        uint256 own = msg.value < MAX_BURN ? msg.value : MAX_BURN;
        uint256 waiting = address(this).balance - own;
        uint256 spent = _burnBlock == uint64(block.number) ? _burnedInBlock : 0;
        if (waiting != 0) {
            uint256 room = MAX_BURN - own;
            if (room > MAX_BURN - spent) room = MAX_BURN - spent;
            if (waiting > room) waiting = room;
        }
        uint256 eth = own + waiting;
        if (eth != 0) {
            for (uint8 route; route < 2; ++route) {
                (bool ok, bytes memory result) = _tryUnlock(route, eth);
                if (ok) {
                    imd = abi.decode(result, (uint256));
                    // Only ETH actually sold consumes the block's allowance. The lock covers both routes.
                    if (waiting != 0) {
                        _burnBlock = uint64(block.number);
                        _burnedInBlock = uint192(spent + waiting);
                    }
                    emit Bought(eth, imd, route);
                    break;
                }
            }
            if (imd == 0) emit Parked(eth);
        }
        // the floor is the sender's: its own ETH's part of the sale, not what the waiting ETH bought alongside
        uint256 mine = own == 0 ? imd : imd * own / eth;
        if (mine < minImd) revert TooLittleIMD();
        _burnImd();
    }

    /// @notice Burns all the $IMD here: the swarm's share (`shareBps`) buys IMD6900, burned; the rest goes to IMD's burn.
    /// Fees paid in $IMD land here and
    /// are burned at once; anyone can call it.
    function burnImd() external locked {
        _burnImd();
    }

    /// @notice What `eth` is worth in $IMD now: the higher of POOL4's and the hookless pool's spot quotes (moving one
    /// pool can't lower it). Reverts unless both pools have liquidity in range.
    function quoteImd(uint256 eth) external view returns (uint256) {
        uint256 a = _spot(PoolKey(address(0), IMD, POOL4_FEE, POOL4_SPACING, POOL4_HOOK), eth);
        uint256 b = _spot(PoolKey(address(0), IMD, BACKUP_FEE, BACKUP_SPACING, address(0)), eth);
        if (a == 0 || b == 0) revert NoPrice();
        return a > b ? a : b;
    }

    /// @notice The PoolManager's callback: route 0 or 1 sells exactly `amount` ETH for $IMD (to here); route 2 sells
    /// exactly `amount` $IMD for IMD6900 and burns it. All of it or nothing.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (uint8 route, uint256 amount) = abi.decode(data, (uint8, uint256));
        if (route == TO_PAIR) {
            (PoolKey memory pair, bool imdIs0) = _pairKey();
            int256 delta = POOL_MANAGER.swap(
                pair, SwapParams(imdIs0, -int256(amount), imdIs0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT), ""
            );
            (int128 imdDelta, int128 outDelta) =
                imdIs0 ? (int128(delta >> 128), int128(delta)) : (int128(delta), int128(delta >> 128));
            if (imdDelta != -int128(int256(amount)) || outDelta <= 0) revert Unfilled();
            POOL_MANAGER.sync(IMD);
            _send(IMD, address(POOL_MANAGER), amount);
            POOL_MANAGER.settle();
            uint256 out = uint128(outDelta);
            POOL_MANAGER.take(IMD6900, address(this), out);
            IBurnable(IMD6900).burn(out);
            return abi.encode(out);
        }
        PoolKey memory key = route == 0
            ? PoolKey(address(0), IMD, POOL4_FEE, POOL4_SPACING, POOL4_HOOK)
            : PoolKey(address(0), IMD, BACKUP_FEE, BACKUP_SPACING, address(0));
        int256 d = POOL_MANAGER.swap(key, SwapParams(true, -int256(amount), MIN_PRICE_LIMIT), "");
        int128 ethDelta = int128(d >> 128);
        int128 bought = int128(d);
        if (ethDelta != -int128(int256(amount)) || bought <= 0) revert Unfilled();
        // sync is permissionless and persists for the transaction: clear any prior ERC-20 sync before paying ETH.
        POOL_MANAGER.sync(address(0));
        POOL_MANAGER.settle{value: amount}();
        POOL_MANAGER.take(IMD, address(this), uint128(bought));
        return abi.encode(uint256(uint128(bought)));
    }

    /// @dev The swarm's share of the $IMD here, up to PAIR_LEG_BPS of the pair pool's $IMD depth, buys IMD6900 (burned)
    /// if the pair pool takes it; everything left goes to IMD's burn.
    function _burnImd() internal {
        uint256 held = _imdHeld();
        if (held == 0) return;
        uint256 share = held * shareBps() / 10_000;
        uint256 room = _pairRoom();
        if (share > room) share = room;
        uint256 burned6900;
        if (share != 0) {
            (bool ok, bytes memory result) = _tryUnlock(TO_PAIR, share);
            if (ok) burned6900 = abi.decode(result, (uint256));
            else share = 0;
        }
        uint256 rest = _imdHeld();
        if (rest != 0) _send(IMD, IMD_BURN, rest);
        emit Burned(rest, share, burned6900);
    }

    /// @dev One unlock that may fail. A leg is skipped only for a failure of its own, never because the caller sent
    /// too little gas (a caller can't pick a route, park a fee or skip the IMD6900 buy that way):
    /// - The legs that run code a third party controls (route 0 through POOL4's hook; the IMD6900 leg through the pair
    ///   hook and IMD6900, a proxy) run on a fixed budget, LEG_GAS. Unless the call can fund the whole budget it is
    ///   refused (TooLittleGas) before the try, so the leg gets the same gas whatever the caller sent; a leg that
    ///   spends all of it (a loop, a hostile upgrade) failed on its own account and is skipped like any other refusal,
    ///   so no third party can halt the burner.
    /// - The hookless route runs only the immutable PoolManager and $IMD, so it gets all the gas, and a failure that
    ///   left no more than 1/4 of it ran out of gas (an out-of-gas d frames deep hands back about d/64, EIP-150; a
    ///   genuine revert hands back nearly all) and reverts the call.
    function _tryUnlock(uint8 route, uint256 amount) internal returns (bool ok, bytes memory result) {
        bytes memory data = abi.encode(route, amount);
        if (route == 1) {
            uint256 gasBefore = gasleft();
            try POOL_MANAGER.unlock(data) returns (bytes memory r) {
                return (true, r);
            } catch {
                if (gasleft() <= gasBefore / 4) revert TooLittleGas();
                return (false, "");
            }
        }
        // a call gets at most 63/64 of the gas left (EIP-150): this much is needed for the leg to get all of LEG_GAS
        if (gasleft() < LEG_GAS + LEG_GAS / 63 + AFTER_GAS) revert TooLittleGas();
        try POOL_MANAGER.unlock{gas: LEG_GAS}(data) returns (bytes memory r) {
            return (true, r);
        } catch {
            return (false, "");
        }
    }

    /// @dev Royalties a market paid in WETH: unwrapped, so they join the ETH and are sold the same way. WETH9's
    /// `withdraw` pays through `receive`. Where WETH has no code (a test chain) or refuses, nothing happens.
    function _unwrapWeth() internal {
        (bool ok, bytes memory r) = WETH.staticcall(abi.encodeWithSelector(0x70a08231, address(this))); // balanceOf
        if (!ok || r.length < 32) return;
        uint256 held = abi.decode(r, (uint256));
        if (held == 0) return;
        (ok,) = WETH.call(abi.encodeWithSelector(0x2e1a7d4d, held)); // withdraw
    }

    /// @dev `eth` in $IMD at a pool's spot price, or 0 if the pool has no price or no liquidity in range.
    function _spot(PoolKey memory key, uint256 eth) internal view returns (uint256) {
        (uint160 sqrtPrice, uint128 liquidity) = _state(key);
        if (sqrtPrice == 0 || liquidity == 0) return 0;
        return FullMath.mulDiv(FullMath.mulDiv(eth, sqrtPrice, 1 << 96), sqrtPrice, 1 << 96);
    }

    /// @dev The IMD6900/$IMD pool's key, and whether $IMD is its currency0.
    function _pairKey() internal view returns (PoolKey memory pair, bool imdIs0) {
        imdIs0 = IMD < IMD6900;
        pair = imdIs0
            ? PoolKey(IMD, IMD6900, PAIR_FEE, PAIR_SPACING, PAIR_HOOK)
            : PoolKey(IMD6900, IMD, PAIR_FEE, PAIR_SPACING, PAIR_HOOK);
    }

    /// @dev The most $IMD one call sells into the pair pool: PAIR_LEG_BPS of the pool's virtual $IMD reserve at its
    /// current price (liquidity / sqrtPrice for a currency0, liquidity * sqrtPrice for a currency1: what its curve has
    /// in range, so the leg moves the price by about PAIR_LEG_BPS). 0 when the pool has no price or no liquidity, so
    /// the leg isn't tried and the share goes to IMD's burn.
    function _pairRoom() internal view returns (uint256) {
        (PoolKey memory pair, bool imdIs0) = _pairKey();
        (uint160 sqrtPrice, uint128 liquidity) = _state(pair);
        if (sqrtPrice == 0 || liquidity == 0) return 0;
        uint256 reserve =
            imdIs0 ? FullMath.mulDiv(liquidity, 1 << 96, sqrtPrice) : FullMath.mulDiv(liquidity, sqrtPrice, 1 << 96);
        return reserve * PAIR_LEG_BPS / 10_000;
    }

    /// @dev A pool's price and liquidity in range, from the PoolManager's storage (pools slot 6: Slot0, then
    /// feeGrowthGlobal0 and 1, then liquidity).
    function _state(PoolKey memory key) internal view returns (uint160 sqrtPrice, uint128 liquidity) {
        bytes32 state = keccak256(abi.encode(keccak256(abi.encode(key)), uint256(6)));
        sqrtPrice = uint160(uint256(POOL_MANAGER.extsload(state)));
        liquidity = uint128(uint256(POOL_MANAGER.extsload(bytes32(uint256(state) + 3))));
    }

    function _imdHeld() internal view returns (uint256 held) {
        (bool ok, bytes memory r) = IMD.staticcall(abi.encodeWithSelector(0x70a08231, address(this)));
        if (ok && r.length >= 32) held = abi.decode(r, (uint256));
    }

    function _send(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, bytes memory r) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!ok || (r.length != 0 && !abi.decode(r, (bool)))) revert TransferFailed();
    }
}
