// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.sol";
import {LARPBurner} from "../src/LARPBurner.sol";
import {IMDNames} from "../src/IMDNames.sol";
import {LARPLinks} from "../src/LARPLinks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary, PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @dev Keep sync and the paid call in one external frame: separate top-level calls in Forge can clear transient
/// storage, hiding the permissionless PoolManager pre-sync attack.
contract SyncedPayer {
    IPoolManager immutable pm;
    Currency immutable currency;

    constructor(IPoolManager manager, address token) {
        pm = manager;
        currency = Currency.wrap(token);
    }

    function pay(address target, bytes calldata data) external payable returns (bytes memory result) {
        pm.sync(currency);
        bool ok;
        (ok, result) = target.call{value: msg.value, gas: 10_000_000}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }
}

contract LARPBurnerSettlementTest is Base {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    SyncedPayer payer;

    function setUp() public {
        _deploy();
        payer = new SyncedPayer(IPoolManager(address(pm)), address(imd));
    }

    function _price(PoolKey memory key) internal view returns (uint160 price) {
        (price,,,) = IPoolManager(address(pm)).getSlot0(key.toId());
    }

    function _burn(uint256 minImd) internal returns (uint256) {
        return abi.decode(payer.pay(address(burner), abi.encodeCall(LARPBurner.burn, (minImd))), (uint256));
    }

    function test_PreSyncCannotParkWaitingEthOrChooseTheBackup() public {
        _fillPool4();
        _fillBackup();
        _fillPair();
        vm.deal(address(burner), 1 ether);
        uint160 pool4Before = _price(pool4);
        uint160 backupBefore = _price(backup);
        uint256 supply = imd6900.totalSupply();

        uint256 bought = _burn(0);

        assertGt(bought, 0);
        assertEq(address(burner).balance, 0.9 ether);
        assertLt(_price(pool4), pool4Before, "the fee used POOL4");
        assertEq(_price(backup), backupBefore, "pre-sync cannot select the backup");
        assertEq(imd.balanceOf(IMD_BURN), bought - bought * 690 / 10_000);
        assertLt(imd6900.totalSupply(), supply, "the share still buys and burns IMD6900");
        assertEq(burner.burn(0), 0, "the successful sale used this block's allowance");
        assertEq(address(burner).balance, 0.9 ether);
    }

    function test_PreSyncCannotParkTheHooklessRoute() public {
        _fillBackup(); // POOL4 has no liquidity, so the native settlement on route 1 must work too.
        vm.deal(address(burner), 0.1 ether);
        uint160 before = _price(backup);
        uint256 bought = _burn(0);
        assertGt(bought, 0);
        assertLt(_price(backup), before);
        assertEq(address(burner).balance, 0);
        assertEq(imd.balanceOf(IMD_BURN), bought, "no pair liquidity: all IMD reaches the executor");
    }

    function test_PreSyncCannotParkARegistrationFee() public {
        _fillPool4();
        _fillBackup();
        bytes32 label = bytes32("frens");
        uint256 price = names.priceOf(label);
        bytes memory result =
            payer.pay{value: price}(address(names), abi.encodeCall(IMDNames.register, (label, address(payer), 0)));
        assertEq(names.ownerOf(abi.decode(result, (uint256))), address(payer));
        _feeSold();
    }

    function test_PreSyncCannotParkAResaleToll() public {
        _fillPool4();
        _fillBackup();
        uint256 id = _register(alice, "frens");
        vm.prank(alice);
        names.transferFrom(alice, address(payer), id);
        identity.mint(address(payer), 0);
        uint256 before = imd.balanceOf(IMD_BURN);
        payer.pay{value: names.tollOf(id)}(address(names), abi.encodeCall(IMDNames.link, (id, 0, 0)));
        (, bool live) = names.identityOf(id);
        assertTrue(live);
        assertEq(names.tollOf(id), 0);
        assertGt(imd.balanceOf(IMD_BURN), before, "the toll bought IMD");
        _feeSold();
    }

    function test_PreSyncCannotParkACrewFee() public {
        _fillPool4();
        _fillBackup();
        identity.mint(address(payer), 0);
        bytes memory result = payer.pay{value: names.crewPrice()}(
            address(links), abi.encodeCall(LARPLinks.foundCrew, (0, bytes32("frens"), true, 0))
        );
        assertEq(links.crewOf(0), abi.decode(result, (uint256)));
        _feeSold();
    }

    function test_PreSyncStillHonoursMinImdAndRollsBackTheAllowance() public {
        _fillPool4();
        vm.deal(address(burner), 1 ether);
        uint160 before = _price(pool4);
        vm.expectRevert(LARPBurner.TooLittleIMD.selector);
        payer.pay(address(burner), abi.encodeCall(LARPBurner.burn, (type(uint256).max)));
        assertEq(address(burner).balance, 1 ether);
        assertEq(_price(pool4), before);
        assertEq(imd.balanceOf(IMD_BURN), 0);
        assertGt(_burn(1), 0, "a reverted sale did not consume the allowance");
        assertEq(address(burner).balance, 0.9 ether);
    }

    function test_ParkedWaitingEthDoesNotConsumeTheBlocksAllowance() public {
        vm.deal(address(burner), 1 ether);
        assertEq(burner.burn(0), 0, "both pools empty: a genuine refusal");
        assertEq(address(burner).balance, 1 ether);
        _fillPool4(); // Liquidity becomes available in the same block.
        assertGt(burner.burn(0), 0, "the unsold ETH can be retried in this block");
        assertEq(address(burner).balance, 0.9 ether);
        assertEq(burner.burn(0), 0, "only a successful sale consumes the allowance");
        assertEq(address(burner).balance, 0.9 ether);
    }

    function _feeSold() internal view {
        assertEq(address(burner).balance, 0, "the fee was sold, not parked");
        assertGt(imd.balanceOf(IMD_BURN), 0);
        assertEq(imd.balanceOf(address(burner)), 0);
        assertEq(imd.balanceOf(0x000000000000000000000000000000000000dEaD), 0);
    }
}
