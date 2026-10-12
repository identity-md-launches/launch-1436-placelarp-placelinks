// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.sol";
import {Trader} from "./LARPBurner.invariant.t.sol";
import {LARPBurner, IShareSource} from "../src/LARPBurner.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey as V4PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title The IMD6900 leg is bounded by the pair pool's depth (AUDIT.md L-16), and a payer's floor is its own (L-17)
/// @notice The swarm can vote the IMD6900 share up to 100% (four weekly proposals from 6.9%). Before L-16 the leg then
/// sold the whole burn into the pair pool at any price, and a searcher could wrap anyone's permissionless `burn(0)`
/// over ETH waiting in the burner between a buy and a sell on the pair and keep part of the value meant for the
/// IMD6900 burn, through the pair's 6.9% fee each way. Now one call sells the pool at most 2% of its own $IMD depth
/// (`PAIR_LEG_BPS`), and what the share makes above that goes to IMD's burn.
contract LARPBurnerPairLegTest is Base {
    Trader trader;
    V4PoolKey feePair;
    bool imdIs0;
    address attacker = makeAddr("attacker");

    event Burned(uint256 imdBurned, uint256 imdSpent, uint256 imd6900Burned);

    function setUp() public {
        _deploy();
        _fillPool4();
        _fillBackup(); // quoteImd needs both ETH pools
        _fillPair();
        trader = new Trader(pm);
        // a second IMD6900/$IMD pool charging 6.9% each way, as the real pair hook does, at the same price and depth
        // as Base's (~1,000 $IMD of virtual reserve)
        imdIs0 = address(imd) < address(imd6900);
        feePair = imdIs0
            ? V4PoolKey(Currency.wrap(address(imd)), Currency.wrap(address(imd6900)), 69_000, 60, IHooks(address(0)))
            : V4PoolKey(Currency.wrap(address(imd6900)), Currency.wrap(address(imd)), 69_000, 60, IHooks(address(0)));
        pm.initialize(feePair, TickMath.getSqrtPriceAtTick(imdIs0 ? int24(92_100) : int24(-92_100)));
        adder.add(feePair, 1e23);
    }

    /// @dev A burner on the fee-charging pair, reading its share from IMD Names like the launched one.
    function _burnerOnFeePair() internal returns (LARPBurner) {
        return new LARPBurner(
            address(pm),
            address(imd),
            10_000,
            60,
            address(0),
            10_000,
            200,
            address(imd6900),
            69_000,
            60,
            address(0),
            address(names)
        );
    }

    /// @dev IMD Names answers `bps` to the burner's share read (what four approved proposals reach for 10,000).
    function _share(uint256 bps) internal {
        vm.mockCall(address(names), abi.encodeWithSelector(IShareSource.imd6900ShareBps.selector), abi.encode(bps));
    }

    /// @dev The sandwich: `front` $IMD buys IMD6900 on the pair, anyone's `burn(0)` sells 0.1 ETH of waiting royalties
    /// (and the leg sells into the pair), the IMD6900 is sold back. Returns the attacker's $IMD profit.
    function _sandwich(LARPBurner b, uint256 front) internal returns (int256 profit) {
        vm.deal(address(b), 0.1 ether); // royalties waiting in the burner
        uint256 start = imd.balanceOf(attacker);
        imd.mint(attacker, front);
        vm.startPrank(attacker);
        imd.approve(address(trader), type(uint256).max);
        imd6900.approve(address(trader), type(uint256).max);
        uint256 before6900 = imd6900.balanceOf(attacker);
        trader.swap(feePair, imdIs0, front);
        uint256 got6900 = imd6900.balanceOf(attacker) - before6900;
        b.burn{gas: 8_000_000}(0);
        trader.swap(feePair, !imdIs0, got6900);
        vm.stopPrank();
        profit = int256(imd.balanceOf(attacker)) - int256(start + front);
    }

    // --- L-16: the leg is bounded by the pool's depth ---

    /// @dev At the swarm-allowed 100% share, sandwiching the leg over 0.1 ETH of waiting royalties loses (it paid
    /// about +40 $IMD on this pool before L-16), for a small and a large front-run alike.
    function test_TheIMD6900LegIsNotWorthSandwichingAtAnyShare() public {
        _share(10_000);
        LARPBurner b = _burnerOnFeePair();
        assertEq(b.shareBps(), 10_000);
        int256 profit = _sandwich(b, 500 ether);
        emit log_named_int("attacker's $IMD profit at 100%, 500 $IMD front (wei)", profit);
        assertLt(profit, 0, "a sandwich of the IMD6900 leg must lose at 100%");
        vm.roll(block.number + 1);
        profit = _sandwich(b, 50 ether);
        assertLt(profit, 0, "and with a small front-run");
        vm.roll(block.number + 1);
        _share(690);
        profit = _sandwich(b, 30 ether);
        assertLt(profit, 0, "and at the launch share, as before (AUDIT I-11)");
    }

    /// @dev At 100%, a full MAX_BURN burn sells the pair pool exactly 2% of its $IMD depth and sends the rest of the
    /// share to IMD's burn; the IMD6900 bought is burned.
    function test_AtAHundredPercentOnlyThePoolsRoomBuysIMD6900() public {
        _share(10_000);
        uint256 room = _pairRoom();
        assertApproxEqRel(room, 20 ether, 0.01e18, "2% of ~1,000 $IMD");
        uint256 pmImd = imd.balanceOf(address(pm));
        uint256 supply = imd6900.totalSupply();
        uint256 got = burner.burn{value: 0.1 ether}(0);
        assertGt(got, 150 ether, "0.1 ETH buys well over the room");
        // the PoolManager paid out `got` on POOL4 and took the leg back on the pair
        assertEq(imd.balanceOf(address(pm)) + got - pmImd, room, "exactly the room went into the pair pool");
        assertEq(imd.balanceOf(IMD_BURN), got - room, "the rest of the 100% share went to IMD's burn");
        assertLt(imd6900.totalSupply(), supply, "the IMD6900 was burned");
        assertEq(imd.balanceOf(address(burner)), 0);
    }

    /// @dev The launch share of a full MAX_BURN burn fits under the cap: 6.9% is sold whole, as before.
    function test_TheLaunchShareOfAFullBurnIsNotClipped() public {
        uint256 pmImd = imd.balanceOf(address(pm));
        uint256 got = burner.burn{value: 0.1 ether}(0);
        uint256 share = got * 690 / 10_000;
        assertLt(share, _pairRoom(), "6.9% of MAX_BURN is under the pool's room");
        assertEq(imd.balanceOf(address(pm)) + got - pmImd, share, "exactly 6.9% went into the pair pool");
        assertEq(imd.balanceOf(IMD_BURN), got - share);
    }

    /// @dev The room follows the pool: twice the liquidity, twice the room; a drained pool, no leg at all (the share
    /// goes to IMD's burn without a try, and the Burned event says so).
    function test_TheRoomFollowsThePoolsDepth() public {
        uint256 room = _pairRoom();
        _fillPair();
        uint256 doubled = _pairRoom();
        assertApproxEqAbs(doubled, room * 2, 2, "twice the liquidity, twice the room");
        _share(10_000);
        imd.mint(address(burner), 100 ether);
        uint256 pmImd = imd.balanceOf(address(pm));
        burner.burnImd();
        assertEq(imd.balanceOf(address(pm)) - pmImd, doubled, "the leg sold the doubled room");

        // a burner on a pair pool with a price but no liquidity: nothing is sold there
        LARPBurner empty = new LARPBurner(
            address(pm),
            address(imd),
            10_000,
            60,
            address(0),
            10_000,
            200,
            address(imd6900),
            69_000,
            200,
            address(0),
            address(names)
        );
        V4PoolKey memory bare = imdIs0
            ? V4PoolKey(Currency.wrap(address(imd)), Currency.wrap(address(imd6900)), 69_000, 200, IHooks(address(0)))
            : V4PoolKey(Currency.wrap(address(imd6900)), Currency.wrap(address(imd)), 69_000, 200, IHooks(address(0)));
        pm.initialize(bare, TickMath.getSqrtPriceAtTick(imdIs0 ? int24(92_000) : int24(-92_000)));
        assertEq(_pairRoomOf(bare), 0, "no liquidity, no room");
        imd.mint(address(empty), 10 ether);
        uint256 dead = imd.balanceOf(IMD_BURN);
        vm.expectEmit(true, true, true, true, address(empty));
        emit Burned(10 ether, 0, 0);
        empty.burnImd{gas: 500_000}(); // under a leg's budget: with no room there is no leg to fund
        assertEq(imd.balanceOf(IMD_BURN) - dead, 10 ether);
    }

    // --- L-17: minImd is the payer's own floor ---

    /// @dev A payer's `minImd` bounds what its own fee bought, pro rata of the one sale, not what the ETH already
    /// waiting bought alongside: with 0.0993 ETH of royalties waiting, a floor the fee alone can't meet is refused,
    /// and a floor at the quote goes through.
    function test_MinImdIsCheckedAgainstThePayersOwnFee() public {
        bytes32 label = _label("alice");
        uint256 price = names.priceOf(label);
        assertEq(price, 0.00069 ether);
        uint256 quote = burner.quoteImd(price);
        vm.deal(address(burner), 0.1 ether - price); // royalties waiting: the sale is MAX_BURN in all
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(LARPBurner.TooLittleIMD.selector);
        names.register{value: price}(label, alice, 5 * quote); // the whole sale (~198 $IMD) would have covered this

        vm.prank(alice);
        uint256 id = names.register{value: price}(label, alice, quote * 97 / 100); // 1% fee, a little slippage
        assertEq(names.ownerOf(id), alice);
        assertEq(address(burner).balance, 0, "the fee and the waiting ETH were sold together");
    }

    /// @dev The same from `burn` itself: the floor is the sender's part; a sender with no ETH of its own (a keeper's
    /// `burn(min)`) still floors the whole sale, as before.
    function test_BurnFloorsTheSendersPartOrTheWholeSaleWhenItSendsNothing() public {
        vm.deal(address(burner), 0.09 ether);
        uint256 whole = burner.quoteImd(0.1 ether);
        uint256 own = burner.quoteImd(0.01 ether);
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        vm.expectRevert(LARPBurner.TooLittleIMD.selector);
        burner.burn{value: 0.01 ether}(own * 11 / 10); // more than 0.01 ETH buys
        uint256 got = burner.burn{value: 0.01 ether}(own * 97 / 100);
        assertApproxEqRel(got, whole, 0.03e18, "the sale was the whole 0.1 ETH");
        vm.stopPrank();

        vm.roll(block.number + 1);
        vm.deal(address(burner), 0.1 ether);
        vm.expectRevert(LARPBurner.TooLittleIMD.selector);
        burner.burn(whole * 11 / 10); // a keeper's floor is on the whole sale
        burner.burn(whole * 97 / 100);
        assertEq(address(burner).balance, 0);
    }
}
