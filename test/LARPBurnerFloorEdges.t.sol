// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.sol";
import {LARPBurner} from "../src/LARPBurner.sol";

/// @title The payer's `minImd` floor is its own, whatever ETH is waiting (AUDIT.md L-17), at every size
/// @notice `LARPBurnerPairLeg.t.sol` pins two points of the fix. These properties walk the space: any fee from one
/// wei to MAX_BURN, any amount of royalties waiting from nothing to a block's full allowance. The oracle is the
/// burner's own spot quote for the payer's ETH alone: a floor above it can never be met by the waiting ETH's part of
/// the sale, and a floor a little under it is always met while the pools are deep. The exact boundary is pinned by
/// replaying the same call from a snapshot.
contract LARPBurnerFloorEdgesTest is Base {
    function setUp() public {
        _deploy();
        _fillPool4();
        _fillBackup();
        _fillPair();
        vm.deal(alice, 10 ether);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_TheWaitingEthNeverMeetsThePayersFloor(uint256 own, uint256 waiting) public {
        // from 10,000 wei: below that the swap's wei rounding alone is more than the 3% the "met" floor allows
        own = bound(own, 10_000, 0.1 ether);
        waiting = bound(waiting, 0, 0.1 ether);
        vm.deal(address(burner), waiting);
        uint256 spotOwn = burner.quoteImd(own);
        uint256 spotAll = burner.quoteImd(own + waiting > 0.1 ether ? 0.1 ether : own + waiting);
        assertGe(spotAll, spotOwn);

        // above what the payer's ETH alone can buy at spot: refused, even though the whole sale would cover it
        vm.prank(alice);
        vm.expectRevert(LARPBurner.TooLittleIMD.selector);
        burner.burn{value: own}(spotOwn + spotOwn / 100 + 1);
        assertEq(address(burner).balance, waiting, "a refused burn leaves the waiting ETH where it was");

        // a little under the payer's own spot (the pools' 1% fee and a 0.1 ETH trade's slippage on 1,000 ETH): met
        vm.prank(alice);
        uint256 got = burner.burn{value: own}(spotOwn * 97 / 100);
        assertGt(got, 0);
        assertLe(got, spotAll, "a sale never beats the spot quote of what was sold");
        uint256 left = own + waiting > 0.1 ether ? own + waiting - 0.1 ether : 0;
        assertEq(address(burner).balance, left, "the fee and the waiting ETH were sold together, up to the cap");
    }

    /// @dev Dust: a fee of one or two wei beside waiting ETH is still floored on its own part (refused above its own
    /// spot), and goes through with no floor.
    function test_ADustFeeIsFlooredOnItsOwnPart() public {
        uint256[3] memory fees = [uint256(1), 2, 999];
        for (uint256 i; i < fees.length; ++i) {
            vm.deal(address(burner), 0.05 ether);
            uint256 spotOwn = burner.quoteImd(fees[i]);
            vm.prank(alice);
            vm.expectRevert(LARPBurner.TooLittleIMD.selector);
            burner.burn{value: fees[i]}(spotOwn + spotOwn / 100 + 1);
            vm.prank(alice);
            assertGt(burner.burn{value: fees[i]}(0), 0, "the waiting ETH is still sold");
            assertEq(address(burner).balance, 0);
            vm.roll(block.number + 1);
        }
    }

    /// @dev The boundary itself: the floor exactly equal to the payer's pro-rata part passes, one wei more fails, and
    /// the whole sale's size is the same either way (the floor never changes what is sold).
    function test_TheFloorBoundaryIsThePayersProRataPartToTheWei() public {
        vm.deal(address(burner), 0.07 ether);
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 got = burner.burn{value: 0.03 ether}(0);
        vm.revertToState(snap);
        uint256 mine = got * 0.03 ether / 0.1 ether;
        assertLt(mine, got, "the waiting ETH bought the rest");

        vm.prank(alice);
        vm.expectRevert(LARPBurner.TooLittleIMD.selector);
        burner.burn{value: 0.03 ether}(mine + 1);

        vm.prank(alice);
        assertEq(burner.burn{value: 0.03 ether}(mine), got, "the same sale, floored exactly at the payer's part");
    }

    /// @dev A fee above MAX_BURN: the payer's own part is the first MAX_BURN, the excess waits, and the floor is
    /// judged against the whole call's sale (all of it the payer's).
    function test_AFeeAboveTheCapIsFlooredOnTheFirstTenthOfAnEther() public {
        uint256 spotCap = burner.quoteImd(0.1 ether);
        vm.prank(alice);
        vm.expectRevert(LARPBurner.TooLittleIMD.selector);
        burner.burn{value: 0.5 ether}(spotCap + spotCap / 100 + 1);
        vm.prank(alice);
        uint256 got = burner.burn{value: 0.5 ether}(spotCap * 97 / 100);
        assertLe(got, spotCap);
        assertEq(address(burner).balance, 0.4 ether, "the excess waits for later calls");
    }

    /// @dev Nothing sent and nothing waiting: a zero floor is met by a sale of nothing, any floor is not.
    function test_AnEmptyBurnMeetsOnlyAZeroFloor() public {
        assertEq(address(burner).balance, 0);
        assertEq(burner.burn(0), 0);
        vm.expectRevert(LARPBurner.TooLittleIMD.selector);
        burner.burn(1);
    }
}
