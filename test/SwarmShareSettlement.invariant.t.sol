// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base, MockIMD, MockIMD6900, MockIntake} from "./Base.sol";
import {SwarmHandler} from "./SwarmPrices.invariant.t.sol";
import {IMDNames} from "../src/IMDNames.sol";
import {LARPBurner, IBurnable} from "../src/LARPBurner.sol";
import {SwarmPrices, Attestation} from "../src/SwarmPrices.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey as V4PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @dev The real names governance and real local v4 pair share one call sequence.
/// The share is never vm.store'd or mocked: only signed, approved execution can
/// change it. The one injected failure models IMD6900 refusing its own burn.
contract ShareSettlementHandler is SwarmHandler {
    LARPBurner public immutable burner;
    MockIMD6900 public immutable token6900;
    address public immutable poolManager;
    V4PoolKey internal pairKey;
    bool public pairRefuses;
    uint256 public clippedBurns;
    uint256 public donated;
    uint256 public spentOnPair;
    uint256 public burns;
    uint256 public gasRefusals;
    uint256 public fallbackBurns;

    constructor(
        IMDNames n,
        MockIntake intake_,
        MockIMD imd_,
        uint256 key,
        LARPBurner b,
        MockIMD6900 t,
        V4PoolKey memory pairKey_
    ) SwarmHandler(n, intake_, imd_, key) {
        burner = b;
        token6900 = t;
        poolManager = address(b.POOL_MANAGER());
        pairKey = pairKey_;
    }

    /// @dev The most one call may sell into the pair pool (AUDIT.md L-16): 2% of the pool's virtual $IMD reserve at
    /// its current price, computed from the PoolManager's state independently of the burner.
    function pairRoom() public view returns (uint256) {
        (uint160 sqrtPrice,,,) = StateLibrary.getSlot0(IPoolManager(poolManager), PoolIdLibrary.toId(pairKey));
        uint128 liquidity = StateLibrary.getLiquidity(IPoolManager(poolManager), PoolIdLibrary.toId(pairKey));
        if (sqrtPrice == 0 || liquidity == 0) return 0;
        uint256 reserve = Currency.unwrap(pairKey.currency0) == address(imd)
            ? FullMath.mulDiv(liquidity, 1 << 96, sqrtPrice)
            : FullMath.mulDiv(liquidity, sqrtPrice, 1 << 96);
        return reserve * 200 / 10_000;
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 0, 1_000 ether);
        imd.mint(address(burner), amount);
        donated += amount;
    }

    function pairAvailability(bool refuses) external {
        pairRefuses = refuses;
        if (refuses) {
            vm.mockCallRevert(address(token6900), abi.encodeWithSelector(IBurnable.burn.selector), "burn refused");
        } else {
            vm.clearMockedCalls();
        }
    }

    function approvePending(uint256 which) external {
        if (ids.length == 0) return;
        bytes32 id = ids[which % ids.length];
        SwarmPrices.Status before = names.proposal(id).status;
        (Attestation memory a, bytes memory sig) =
            _attest(id, true, 9, 7, 9, uint64(block.timestamp + 1 days), oracleKey);
        bool ok = intake.deliver(id, a, sig);
        if (before != SwarmPrices.Status.Pending) {
            assertFalse(ok);
            assertEq(uint8(names.proposal(id).status), uint8(before));
            return;
        }
        assertTrue(ok);
        sawValidApproval[id] = true;
        lastSeen[id] = SwarmPrices.Status.Approved;
        ++verdicts;
    }

    function burn(bool tooLittleGas, uint256 callerSeed) external {
        uint256 held = imd.balanceOf(address(burner));
        uint256 share = held * expected.share / 10_000;
        // the leg is the voted share, clipped to the pool's room (L-16); the clipped part is IMD's burn's
        uint256 room = pairRoom();
        bool clipped = share > room;
        if (clipped) share = room;
        uint256 poolImd = imd.balanceOf(poolManager);
        uint256 pool6900 = token6900.balanceOf(poolManager);
        uint256 supply = token6900.totalSupply();
        uint256 canonical = imd.balanceOf(burner.IMD_BURN());
        vm.prank(proposers[callerSeed % 3]);
        (bool ok, bytes memory result) =
            address(burner).call{gas: tooLittleGas ? 500_000 : 5_000_000}(abi.encodeCall(burner.burnImd, ()));
        if (tooLittleGas && share != 0) {
            assertFalse(ok, "caller gas cannot choose whether the voted share is spent");
            assertEq(bytes4(result), LARPBurner.TooLittleGas.selector);
            assertEq(imd.balanceOf(address(burner)), held);
            assertEq(imd.balanceOf(poolManager), poolImd);
            assertEq(imd.balanceOf(burner.IMD_BURN()), canonical);
            assertEq(token6900.balanceOf(poolManager), pool6900);
            assertEq(token6900.totalSupply(), supply);
            ++gasRefusals;
            return;
        }
        assertTrue(ok, "a fully funded burn remains live");
        uint256 spent = imd.balanceOf(poolManager) - poolImd;
        assertEq(spent, pairRefuses ? 0 : share, "the executed share within the room, or zero on a refused pair");
        assertLe(spent, room, "one call never sells the pair more than 2% of its depth");
        assertEq(imd.balanceOf(burner.IMD_BURN()) - canonical, held - spent, "the rest, clipped or refused, is IMD's");
        assertEq(
            token6900.totalSupply() - token6900.balanceOf(poolManager),
            supply - pool6900,
            "every token taken from the pair is destroyed"
        );
        if (spent != 0) assertLt(token6900.totalSupply(), supply);
        else assertEq(token6900.totalSupply(), supply);
        assertEq(imd.balanceOf(address(burner)), 0);
        assertEq(token6900.balanceOf(address(burner)), 0);
        spentOnPair += spent;
        ++burns;
        if (pairRefuses && share != 0) ++fallbackBurns;
        if (clipped && !pairRefuses) ++clippedBurns;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SwarmShareSettlementInvariantTest is Base {
    ShareSettlementHandler internal handler;
    uint256 internal initialSupply6900;
    uint256 internal initialPool6900;
    uint256 internal initialPoolImd;

    function setUp() public {
        _deploy();
        _fillPair();
        initialSupply6900 = imd6900.totalSupply();
        initialPool6900 = imd6900.balanceOf(address(pm));
        initialPoolImd = imd.balanceOf(address(pm));
        handler = new ShareSettlementHandler(names, intake, imd, oracleKey, burner, imd6900, pair);
        assertEq(handler.pairRoom(), _pairRoom(), "the handler's room is Base's independent reading");
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = handler.propose.selector;
        selectors[1] = handler.proposeShare.selector;
        selectors[2] = handler.verdict.selector;
        selectors[3] = handler.approvePending.selector;
        selectors[4] = handler.forge.selector;
        selectors[5] = handler.stranger.selector;
        selectors[6] = handler.fail.selector;
        selectors[7] = handler.execute.selector;
        selectors[8] = handler.pass.selector;
        selectors[9] = handler.donate.selector;
        selectors[10] = handler.burn.selector;
        selectors[11] = handler.pairAvailability.selector;
        selectors[12] = handler.burn.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_ShareTracksOnlyApprovedExecutedTerms() public view {
        (uint64 s, uint64 f, uint64 l, uint64 c, uint16 share) = handler.expected();
        (uint64 actualS, uint64 actualF, uint64 actualL, uint64 actualC, uint16 actualShare) = names.prices();
        assertEq(actualS, s);
        assertEq(actualF, f);
        assertEq(actualL, l);
        assertEq(actualC, c);
        assertEq(actualShare, share);
        assertEq(burner.shareBps(), share);
        assertEq(names.imd6900ShareBps(), share);
        assertLe(share, 10_000);
        assertEq(names.epoch(), handler.executions());
        assertEq(names.lastChange(), handler.lastChangeSeen());
        assertEq(names.proposalCount(), handler.proposals());
        for (uint256 i; i < handler.idCount(); ++i) {
            bytes32 id = handler.ids(i);
            SwarmPrices.Status status = names.proposal(id).status;
            assertEq(uint8(status), uint8(handler.lastSeen(id)));
            if (status == SwarmPrices.Status.Executed) assertTrue(handler.sawValidApproval(id));
        }
    }

    function invariant_EveryDonatedImdIsWaitingSpentOrAtTheCanonicalBurn() public view {
        assertEq(handler.donated(), imd.balanceOf(address(burner)) + handler.spentOnPair() + imd.balanceOf(IMD_BURN));
        assertEq(imd.balanceOf(address(pm)) - initialPoolImd, handler.spentOnPair());
        assertEq(imd.balanceOf(0x000000000000000000000000000000000000dEaD), 0);
        assertEq(imd.balanceOf(address(names)), 0);
        assertEq(address(names).balance, 0);
    }

    function invariant_ThePairOutputReallyLeavesTotalSupply() public view {
        assertEq(initialSupply6900 - imd6900.totalSupply(), initialPool6900 - imd6900.balanceOf(address(pm)));
        assertEq(imd6900.balanceOf(address(burner)), 0);
        assertEq(imd6900.balanceOf(IMD_BURN), 0);
    }

    function _changeShare(uint16 share) internal {
        uint256 index = handler.idCount();
        uint256 oldShare = burner.shareBps();
        handler.proposeShare(0, share, false);
        handler.approvePending(index);
        assertEq(burner.shareBps(), oldShare, "even an approval needs execution");
        handler.pass(7 days);
        handler.execute(index, 1);
        assertEq(burner.shareBps(), share);
    }

    function test_VotedShareCanReachZeroAndAllWithSettlementAtEveryStep() public {
        uint16[12] memory shares = [uint16(345), 173, 87, 0, 100, 200, 400, 800, 1600, 3200, 6400, 10_000];
        for (uint256 i; i < shares.length; ++i) {
            _changeShare(shares[i]);
            handler.donate(100 ether);
            handler.burn(false, i);
            invariant_ShareTracksOnlyApprovedExecutedTerms();
            invariant_EveryDonatedImdIsWaitingSpentOrAtTheCanonicalBurn();
            invariant_ThePairOutputReallyLeavesTotalSupply();
        }
        assertEq(handler.executions(), 12);
        assertEq(handler.burns(), 12);
        // 100 $IMD at 32%, 64% and 100% is above the pool's ~20 $IMD room: those legs were clipped, not sold whole
        assertEq(handler.clippedBurns(), 3, "the three shares above the room were clipped (L-16)");
        assertLe(handler.spentOnPair(), 9 * handler.pairRoom() + 3 * 25 ether);
    }

    function test_CallerGasCannotBypassShareButARefusingDependencyCanFallBack() public {
        handler.donate(100 ether);
        handler.burn(true, 0);
        assertEq(handler.gasRefusals(), 1);
        handler.pairAvailability(true);
        handler.burn(false, 1);
        assertEq(handler.fallbackBurns(), 1);
        assertEq(imd.balanceOf(IMD_BURN), 100 ether);
        handler.pairAvailability(false);
        handler.donate(100 ether);
        handler.burn(false, 2);
        assertEq(handler.spentOnPair(), 6.9 ether);
        invariant_EveryDonatedImdIsWaitingSpentOrAtTheCanonicalBurn();
        invariant_ThePairOutputReallyLeavesTotalSupply();
    }
}
