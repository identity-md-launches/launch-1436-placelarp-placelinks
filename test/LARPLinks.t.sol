// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base, MockIMD, MockDistributor} from "./Base.sol";
import {LARPLinks} from "../src/LARPLinks.sol";

contract LARPLinksTest is Base {
    event Frens(uint256 indexed a, uint256 indexed b);
    event FrenAsked(uint256 indexed from, uint256 indexed to);
    event CrewFounded(uint256 indexed crewId, uint256 indexed captain, bytes32 name, bool open);
    event AllocProven(address indexed wallet, uint64 indexed launch, uint256 round, uint256 amount);

    uint256 constant CREW = 0.00069 ether;

    function setUp() public {
        _deploy();
        _fillPool4();
        identity.mint(alice, 0);
        identity.mint(alice, 1);
        identity.mint(bob, 2);
        identity.mint(carol, 3);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
    }

    // ------------------------------------------------------------------ frens

    function test_FrensTakeTwo() public {
        vm.expectEmit(address(links));
        emit FrenAsked(0, 2);
        vm.prank(alice);
        links.fren(0, 2);
        assertTrue(links.asked(0, 2));
        assertFalse(links.isFren(0, 2));

        vm.expectEmit(address(links));
        emit Frens(0, 2);
        vm.prank(bob);
        links.fren(2, 0);
        assertTrue(links.isFren(0, 2));
        assertTrue(links.isFren(2, 0));
        assertFalse(links.asked(0, 2));
        assertEq(links.frenCount(0), 1);
        assertEq(links.frenCount(2), 1);
    }

    function test_FrenRules() public {
        vm.startPrank(alice);
        vm.expectRevert(LARPLinks.SelfFren.selector);
        links.fren(0, 0);
        vm.expectRevert(LARPLinks.NoSuchIdentity.selector);
        links.fren(0, 99);
        vm.expectRevert(LARPLinks.NotYourIdentity.selector);
        links.fren(2, 0);
        links.fren(0, 2);
        vm.expectRevert(LARPLinks.AlreadyAsked.selector);
        links.fren(0, 2);
        vm.stopPrank();
        vm.prank(bob);
        links.fren(2, 0);
        vm.prank(alice);
        vm.expectRevert(LARPLinks.AlreadyFrens.selector);
        links.fren(0, 2);
    }

    function test_Unfren() public {
        vm.prank(alice);
        links.fren(0, 2);
        vm.prank(bob);
        links.fren(2, 0);
        vm.prank(bob);
        links.unfren(2, 0);
        assertFalse(links.isFren(0, 2));
        assertEq(links.frenCount(0), 0);
        assertEq(links.frenCount(2), 0);
    }

    function test_WithdrawAndDeclineAsks() public {
        vm.prank(alice);
        links.fren(0, 2);
        vm.prank(alice);
        links.unfren(0, 2); // withdraw
        assertFalse(links.asked(0, 2));

        vm.prank(alice);
        links.fren(0, 3);
        vm.prank(carol);
        links.unfren(3, 0); // decline
        assertFalse(links.asked(0, 3));
        assertEq(links.frenCount(3), 0);
    }

    function test_FrensPassWithTheIdentity() public {
        vm.prank(alice);
        links.fren(0, 2);
        vm.prank(bob);
        links.fren(2, 0);
        vm.prank(alice);
        identity.transferFrom(alice, carol, 0);
        assertTrue(links.isFren(0, 2), "the link is between identities");
        vm.prank(carol);
        links.unfren(0, 2); // the new holder can cut it
        assertFalse(links.isFren(0, 2));
    }

    // ------------------------------------------------------------------ crews

    function _found(address who, uint256 captain, string memory name, bool open) internal returns (uint256) {
        vm.prank(who);
        return links.foundCrew{value: CREW}(captain, _label(name), open, 0);
    }

    function test_FoundingACrewBurnsIMD() public {
        uint256 before = imd.balanceOf(IMD_BURN);
        vm.expectEmit(address(links));
        emit CrewFounded(1, 0, _label("kek-crew"), true);
        uint256 id = _found(alice, 0, "kek-crew", true);
        assertEq(id, 1);
        assertGt(imd.balanceOf(IMD_BURN), before, "the fee bought $IMD for 0x..dEaD");
        assertEq(address(links).balance, 0);
        assertEq(address(burner).balance, 0);
        (uint256 captain, bytes32 name, uint256 members, bool open, bool alive) = links.crew(1);
        assertEq(captain, 0);
        assertEq(name, _label("kek-crew"));
        assertEq(members, 1);
        assertTrue(open);
        assertTrue(alive);
        assertEq(links.crewOf(0), 1);
        assertEq(links.crewByName(_label("kek-crew")), 1);
    }

    function test_FoundACrewWithImd() public {
        _fillBackup();
        _fillPair();
        imd.mint(alice, 1_000 ether);
        vm.prank(alice);
        imd.approve(address(links), type(uint256).max);
        uint256 due = burner.quoteImd(CREW);
        uint256 dead = imd.balanceOf(IMD_BURN);
        vm.prank(alice);
        vm.expectRevert(LARPLinks.TooMuchImd.selector);
        links.foundCrewWithImd(0, _label("imd-crew"), true, due - 1);
        vm.prank(alice);
        uint256 id = links.foundCrewWithImd(0, _label("imd-crew"), true, due);
        assertEq(links.crewOf(0), id);
        assertEq(imd.balanceOf(alice), 1_000 ether - due);
        assertEq(imd.balanceOf(IMD_BURN) - dead, due - due * 690 / 10_000);
    }

    function test_CrewFoundingRules() public {
        vm.startPrank(alice);
        vm.expectRevert(LARPLinks.WrongPrice.selector);
        links.foundCrew{value: 0.001 ether}(0, _label("crew"), true, 0);
        vm.expectRevert(LARPLinks.BadName.selector);
        links.foundCrew{value: CREW}(0, _label("Crew"), true, 0);
        vm.expectRevert(LARPLinks.NotYourIdentity.selector);
        links.foundCrew{value: CREW}(2, _label("crew"), true, 0);
        links.foundCrew{value: CREW}(0, _label("crew"), true, 0);
        vm.expectRevert(LARPLinks.InACrew.selector);
        links.foundCrew{value: CREW}(0, _label("crew2"), true, 0);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(LARPLinks.NameTaken.selector);
        links.foundCrew{value: CREW}(2, _label("crew"), true, 0);
    }

    function test_OpenAndClosedCrews() public {
        uint256 open = _found(alice, 0, "open-crew", true);
        uint256 closed = _found(bob, 2, "closed-crew", false);

        vm.prank(carol);
        links.join(3, open);
        assertEq(links.crewOf(3), open);
        vm.prank(carol);
        links.leave(3);

        vm.prank(carol);
        vm.expectRevert(LARPLinks.NotInvited.selector);
        links.join(3, closed);
        vm.prank(bob);
        links.invite(closed, 3, true);
        vm.prank(carol);
        links.join(3, closed);
        assertEq(links.crewOf(3), closed);
        assertFalse(links.invited(closed, 3), "an invitation is used once");
        (,, uint256 members,,) = links.crew(closed);
        assertEq(members, 2);

        vm.prank(carol);
        vm.expectRevert(LARPLinks.InACrew.selector);
        links.join(3, open);
    }

    function test_CaptainsRun() public {
        uint256 id = _found(alice, 0, "crew", true);
        vm.prank(bob);
        links.join(2, id);

        vm.startPrank(bob);
        vm.expectRevert(LARPLinks.NotCaptain.selector);
        links.kick(id, 0);
        vm.expectRevert(LARPLinks.NotCaptain.selector);
        links.setOpen(id, false);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(LARPLinks.CaptainStays.selector);
        links.leave(0);

        vm.prank(alice);
        links.kick(id, 2);
        assertEq(links.crewOf(2), 0);
        vm.prank(alice);
        vm.expectRevert(LARPLinks.NotInCrew.selector);
        links.kick(id, 2);
    }

    function test_PassTheCaptaincy() public {
        uint256 id = _found(alice, 0, "crew", true);
        vm.prank(bob);
        links.join(2, id);
        vm.prank(alice);
        vm.expectRevert(LARPLinks.NotInCrew.selector);
        links.passCaptain(id, 3);
        vm.prank(alice);
        links.passCaptain(id, 2);
        (uint256 captain,,,,) = links.crew(id);
        assertEq(captain, 2);
        vm.prank(alice);
        links.leave(0); // no longer the captain
        vm.prank(alice);
        vm.expectRevert(LARPLinks.NotCaptain.selector);
        links.setOpen(id, false);
    }

    function test_TheCaptaincyPassesWithTheIdentity() public {
        uint256 id = _found(alice, 0, "crew", true);
        vm.prank(alice);
        identity.transferFrom(alice, carol, 0);
        vm.prank(carol);
        links.setOpen(id, false);
        (,,, bool open,) = links.crew(id);
        assertFalse(open);
    }

    function test_Disband() public {
        uint256 id = _found(alice, 0, "crew", true);
        vm.prank(bob);
        links.join(2, id);
        vm.prank(alice);
        links.disband(id);
        assertEq(links.crewOf(0), 0);
        assertEq(links.crewOf(2), 0, "every member is crewless");
        assertEq(links.crewByName(_label("crew")), 0, "the name is free");
        vm.prank(bob);
        vm.expectRevert(LARPLinks.NoSuchCrew.selector);
        links.join(2, id);
        // and both can found or join again
        uint256 again = _found(bob, 2, "crew", true);
        assertEq(again, 2);
        vm.prank(alice);
        links.join(0, again);
        (,, uint256 members,,) = links.crew(again);
        assertEq(members, 2);
    }

    // ------------------------------------------------------------ the jeet board

    function _leaf(address wallet, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(wallet, amount))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    struct Drop {
        MockIMD token;
        MockDistributor distributor;
        bytes32[4] leaves;
    }

    /// @dev A swarm launch paying alice 1,000, bob 2,000, carol 3,000 and a stranger 4,000 of its token in round 0.
    function _launch(uint64 number) internal returns (Drop memory d) {
        d.token = new MockIMD();
        d.distributor = new MockDistributor(address(d.token));
        d.leaves =
            [_leaf(alice, 1_000e18), _leaf(bob, 2_000e18), _leaf(carol, 3_000e18), _leaf(address(0xBEEF), 4_000e18)];
        d.distributor.setRoot(0, _pair(_pair(d.leaves[0], d.leaves[1]), _pair(d.leaves[2], d.leaves[3])));
        launcher.set(number, address(d.distributor));
    }

    function _proof(Drop memory d, uint256 i) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = d.leaves[i ^ 1];
        p[1] = i < 2 ? _pair(d.leaves[2], d.leaves[3]) : _pair(d.leaves[0], d.leaves[1]);
    }

    function test_ProveAnAllocation() public {
        Drop memory d = _launch(737);
        vm.expectEmit(address(links));
        emit AllocProven(alice, 737, 0, 1_000e18);
        vm.prank(carol); // anyone can
        links.proveAlloc(737, 0, alice, 1_000e18, _proof(d, 0));
        assertEq(links.allocOf(alice, address(d.distributor), 0), 1_000e18);
        assertEq(links.launchCount(alice), 1);
    }

    function test_BadAllocations() public {
        Drop memory d = _launch(737);
        vm.expectRevert(LARPLinks.BadProof.selector);
        links.proveAlloc(737, 0, alice, 1_001e18, _proof(d, 0));
        vm.expectRevert(LARPLinks.BadProof.selector);
        links.proveAlloc(737, 0, bob, 1_000e18, _proof(d, 0));
        vm.expectRevert(LARPLinks.UnknownLaunch.selector);
        links.proveAlloc(738, 0, alice, 1_000e18, _proof(d, 0));
        vm.expectRevert(LARPLinks.UnknownRound.selector);
        links.proveAlloc(737, 1, alice, 1_000e18, _proof(d, 0));
        vm.expectRevert(LARPLinks.BadAlloc.selector);
        links.proveAlloc(737, 0, alice, 0, _proof(d, 0));
        vm.expectRevert(LARPLinks.BadAlloc.selector);
        links.proveAlloc(737, 0, address(0), 1_000e18, _proof(d, 0));
        links.proveAlloc(737, 0, alice, 1_000e18, _proof(d, 0));
        vm.expectRevert(LARPLinks.AlreadyProven.selector);
        links.proveAlloc(737, 0, alice, 1_000e18, _proof(d, 0));
    }

    function test_AnInnerNodeIsNotALeaf() public {
        Drop memory d = _launch(737);
        // the pair (alice, bob) is a node of the tree; it can't pass as a leaf of any wallet and amount: leaves are
        // hashed twice, and an amount is under 2^128 (a node's hash rarely is)
        bytes32[] memory p = new bytes32[](1);
        p[0] = _pair(d.leaves[2], d.leaves[3]);
        vm.expectRevert();
        links.proveAlloc(737, 0, address(uint160(uint256(d.leaves[0]))), uint256(d.leaves[1]), p);
        vm.expectRevert(LARPLinks.BadProof.selector);
        links.proveAlloc(737, 0, address(uint160(uint256(d.leaves[0]))), uint256(d.leaves[1]) >> 128, p);
    }

    function test_JeetsAreReadLive() public {
        Drop memory d = _launch(737);
        links.proveAlloc(737, 0, alice, 1_000e18, _proof(d, 0));
        links.proveAlloc(737, 0, bob, 2_000e18, _proof(d, 1));
        links.proveAlloc(737, 0, carol, 3_000e18, _proof(d, 2));

        // nobody claimed yet: nobody jeeted
        (uint256 level, uint256 points) = links.jeetOf(alice);
        assertEq(level, 1);
        assertEq(points, 0);

        d.distributor.claim(0, alice, 1_000e18);
        d.distributor.claim(0, bob, 2_000e18);
        d.distributor.claim(0, carol, 3_000e18);
        // alice holds all, bob sells half, carol sells everything
        vm.prank(bob);
        d.token.transfer(address(0xdead), 1_000e18);
        vm.prank(carol);
        d.token.transfer(address(0xdead), 3_000e18);

        (, points) = links.jeetOf(alice);
        assertEq(points, 0);
        (, points) = links.jeetOf(bob);
        assertEq(points, 5_000);
        (, points) = links.jeetOf(carol);
        assertEq(points, 10_000);

        LARPLinks.LaunchJeet memory j = links.launchJeet(bob, 0);
        assertEq(j.number, 737);
        assertEq(j.token, address(d.token));
        assertEq(j.allocated, 2_000e18);
        assertEq(j.claimed, 2_000e18);
        assertEq(j.held, 1_000e18);
        assertEq(j.jeetBps, 5_000);

        // buying back is holding again; more than the allocation counts as the allocation
        d.token.mint(carol, 10_000e18);
        (, points) = links.jeetOf(carol);
        assertEq(points, 0);
    }

    function test_RanksAcrossLaunches() public {
        Drop memory a = _launch(737);
        Drop memory b = _launch(739);
        Drop memory c = _launch(1042);
        Drop[3] memory drops = [a, b, c];
        for (uint256 i; i < 3; ++i) {
            links.proveAlloc(uint64([737, 739, 1042][i]), 0, carol, 3_000e18, _proof(drops[i], 2));
            drops[i].distributor.claim(0, carol, 3_000e18);
        }
        (address holder, uint256 level, uint256 points, uint8 tier) = links.rankOf(3);
        assertEq(holder, carol);
        assertEq(level, 3);
        assertEq(points, 0);
        assertEq(tier, 1);
        assertEq(links.titleOf(tier), "Diamond Hands");

        // carol jeets two launches out of three: 66% on average
        vm.startPrank(carol);
        a.token.transfer(address(0xdead), 3_000e18);
        b.token.transfer(address(0xdead), 3_000e18);
        vm.stopPrank();
        (, level, points, tier) = links.rankOf(3);
        assertEq(points, 20_000);
        assertEq(tier, 4);
        assertEq(links.titleOf(tier), "Jeet");

        vm.prank(carol);
        c.token.transfer(address(0xdead), 3_000e18);
        (,, points, tier) = links.rankOf(3);
        assertEq(points, 30_000);
        assertEq(links.titleOf(tier), "Jeet Lord");
    }

    /// @dev Audit fix: the board reads in pages, so a wallet with hundreds of launches stays readable.
    function test_JeetsInPages() public {
        for (uint64 n = 1; n <= 5; ++n) {
            Drop memory d = _launch(n);
            links.proveAlloc(n, 0, carol, 3_000e18, _proof(d, 2));
            d.distributor.claim(0, carol, 3_000e18);
            if (n % 2 == 1) {
                vm.prank(carol);
                d.token.transfer(address(0xdead), 3_000e18); // launches 1, 3 and 5 jeeted
            }
        }
        (uint256 level, uint256 points) = links.jeetOf(carol);
        assertEq(level, 5);
        assertEq(points, 30_000);
        assertEq(links.jeetOfRange(carol, 0, 2), 10_000);
        assertEq(links.jeetOfRange(carol, 2, 2), 10_000);
        assertEq(links.jeetOfRange(carol, 4, 2), 10_000, "a page past the end stops at the end");
        assertEq(links.jeetOfRange(carol, 5, 10), 0);
        assertEq(links.jeetOfRange(carol, 99, type(uint256).max), 0);
        assertEq(links.jeetOfRange(carol, 1, type(uint256).max), 20_000);
    }

    function test_Tiers() public view {
        assertEq(links.tierOf(0, 0), 0);
        assertEq(links.titleOf(0), "Lurker");
        assertEq(links.tierOf(1, 999), 1);
        assertEq(links.tierOf(1, 1_000), 2);
        assertEq(links.titleOf(2), "Holder");
        assertEq(links.tierOf(2, 6_999), 2);
        assertEq(links.tierOf(1, 3_500), 3);
        assertEq(links.titleOf(3), "Paper Hands");
        assertEq(links.tierOf(1, 8_999), 4);
        assertEq(links.tierOf(1, 9_000), 5);
        assertEq(links.tierOf(4, 40_000), 5);
    }

    function test_TheRankIsTheHoldersNow() public {
        Drop memory d = _launch(737);
        links.proveAlloc(737, 0, carol, 3_000e18, _proof(d, 2));
        d.distributor.claim(0, carol, 3_000e18);
        vm.prank(carol);
        d.token.transfer(address(0xdead), 3_000e18);
        (,,, uint8 tier) = links.rankOf(3);
        assertEq(tier, 5);
        vm.prank(carol);
        identity.transferFrom(carol, alice, 3);
        (address holder, uint256 level,, uint8 t) = links.rankOf(3);
        assertEq(holder, alice);
        assertEq(level, 0);
        assertEq(t, 0, "alice has no launch proven");
    }

    function test_AnUnreadableTokenCountsAsHeld() public {
        Drop memory d = _launch(737);
        links.proveAlloc(737, 0, carol, 3_000e18, _proof(d, 2));
        d.distributor.claim(0, carol, 3_000e18);
        vm.prank(carol);
        d.token.transfer(address(0xdead), 3_000e18);
        vm.etch(address(d.token), hex"fe"); // balanceOf now always reverts
        (, uint256 points) = links.jeetOf(carol);
        assertEq(points, 0);
    }

    function test_AGasHungryTokenCantSinkTheBoard() public {
        Drop memory d = _launch(737);
        links.proveAlloc(737, 0, carol, 3_000e18, _proof(d, 2));
        d.distributor.claim(0, carol, 3_000e18);
        // balanceOf loops forever: each read is capped, the view still answers
        vm.etch(address(d.token), hex"5b5f56");
        uint256 g = gasleft();
        (uint256 level,) = links.jeetOf(carol);
        assertEq(level, 1);
        assertLt(g - gasleft(), 200_000);
    }

    // ------------------------------------------------------------------ cards

    function test_Card() public {
        // a name, a crew, a fren and a rank
        uint256 kek = _register(alice, "kekmaster");
        vm.prank(alice);
        names.link(kek, 0, 0);
        vm.prank(alice);
        links.foundCrew{value: CREW}(0, _label("kek-crew"), true, 0);
        vm.prank(alice);
        links.fren(0, 2);
        vm.prank(bob);
        links.fren(2, 0);

        LARPLinks.Card memory c = links.cardOf(0);
        assertEq(c.holder, alice);
        assertEq(c.name, "kekmaster.imd");
        assertFalse(c.faceLive);
        assertEq(c.crewId, 1);
        assertEq(c.crewName, _label("kek-crew"));
        assertTrue(c.captain);
        assertEq(c.frens, 1);
        assertEq(c.level, 0);
        assertEq(c.title, "Lurker");
    }
}
