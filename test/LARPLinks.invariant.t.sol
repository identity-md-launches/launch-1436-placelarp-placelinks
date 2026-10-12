// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Base, MockIMD} from "./Base.sol";
import {MockNFT} from "./Mocks.sol";
import {LARP} from "../src/LARP.sol";
import {LARPLinks} from "../src/LARPLinks.sol";
import {IMDNames} from "../src/IMDNames.sol";
import {LARPBurner} from "../src/LARPBurner.sol";

contract SocialLifecycleHandler is Test {
    LARPLinks public immutable links;
    LARP public immutable larp;
    IMDNames public immutable names;
    LARPBurner public immutable burner;
    MockNFT public immutable identity;
    MockIMD public immutable imd;
    address[4] public actors;
    address[8] public agents;
    bytes32[8] public labels = [
        bytes32("a"),
        bytes32("bc"),
        bytes32("def"),
        bytes32("crew"),
        bytes32("frens"),
        bytes32("a-b"),
        bytes32("123"),
        bytes32("last-crew")
    ];
    mapping(uint256 => bool) public ended;
    uint256 public founded;
    uint256 public ethFees;
    uint256 public imdFoundings;
    uint256 public friendships;
    uint256 public joins;
    uint256 public captainChanges;
    uint256 public disbands;
    uint256 public refused;

    constructor(LARPLinks k, LARP l, IMDNames n, LARPBurner b, MockNFT i, MockIMD token) {
        (links, larp, names, burner, identity, imd) = (k, l, n, b, i, token);
        for (uint256 a; a < 4; ++a) {
            actors[a] = makeAddr(string.concat("crew holder ", vm.toString(a)));
            vm.deal(actors[a], 100 ether);
            imd.mint(actors[a], 1_000_000 ether);
            vm.prank(actors[a]);
            imd.approve(address(links), type(uint256).max);
        }
        for (uint256 id; id < 8; ++id) {
            identity.mint(actors[id % 4], id);
            agents[id] = makeAddr(string.concat("crew agent ", vm.toString(id)));
            vm.deal(agents[id], 100 ether);
            imd.mint(agents[id], 1_000_000 ether);
            vm.prank(agents[id]);
            imd.approve(address(links), type(uint256).max);
        }
        _found(0, labels[0], true, false, actors[0]);
        _found(1, labels[1], false, true, actors[1]);
    }

    function found(uint256 seed, uint256 nameSeed, bool open, bool inImd, bool asAgent) external {
        uint256 id = seed % 8;
        bytes32 label = labels[nameSeed % 8];
        address caller = _controller(id, asAgent);
        bytes4 errorSelector;
        if (links.crewOf(id) != 0) errorSelector = LARPLinks.InACrew.selector;
        else if (links.crewByName(label) != 0) errorSelector = LARPLinks.NameTaken.selector;
        if (errorSelector != 0) {
            uint256 fee = names.crewPrice();
            vm.prank(caller);
            vm.expectRevert(errorSelector);
            links.foundCrew{value: fee}(id, label, open, 0);
            ++refused;
            return;
        }
        _found(id, label, open, inImd, caller);
    }

    function _found(uint256 id, bytes32 label, bool open, bool inImd, address caller) internal {
        uint256 fee = names.crewPrice();
        uint256 due = inImd ? burner.quoteImd(fee) : 0;
        uint256 beforeEth = caller.balance;
        uint256 beforeImd = imd.balanceOf(caller);
        vm.prank(caller);
        uint256 crewId =
            inImd ? links.foundCrewWithImd(id, label, open, due) : links.foundCrew{value: fee}(id, label, open, 0);
        ++founded;
        assertEq(crewId, founded, "crew ids are never reused, even after disband");
        assertEq(links.crewOf(id), crewId);
        assertEq(links.crewByName(label), crewId);
        assertEq(caller.balance, beforeEth - (inImd ? 0 : fee));
        assertEq(imd.balanceOf(caller), beforeImd - due);
        if (inImd) ++imdFoundings;
        else ethFees += fee;
    }

    function invite(uint256 crewSeed, uint256 memberSeed, bool yes, bool asAgent) external {
        uint256 crewId = 1 + crewSeed % founded;
        uint256 id = memberSeed % 8;
        (uint256 captain,,,, bool alive) = links.crew(crewId);
        vm.prank(_controller(captain, asAgent));
        if (!alive) {
            vm.expectRevert(LARPLinks.NoSuchCrew.selector);
            links.invite(crewId, id, yes);
            ++refused;
            return;
        }
        links.invite(crewId, id, yes);
        assertEq(links.invited(crewId, id), yes);
    }

    function joinOrLeave(uint256 seed, uint256 crewSeed, bool joining, bool asAgent) external {
        uint256 id = seed % 8;
        uint256 crewId = joining ? 1 + crewSeed % founded : links.crewOf(id);
        (uint256 captain,, uint256 members, bool open, bool alive) = links.crew(crewId);
        bytes4 errorSelector;
        if (joining) {
            if (!alive) errorSelector = LARPLinks.NoSuchCrew.selector;
            else if (links.crewOf(id) != 0) errorSelector = LARPLinks.InACrew.selector;
            else if (!open && !links.invited(crewId, id)) errorSelector = LARPLinks.NotInvited.selector;
        } else {
            if (crewId == 0) errorSelector = LARPLinks.NotInCrew.selector;
            else if (captain == id) errorSelector = LARPLinks.CaptainStays.selector;
        }
        vm.prank(_controller(id, asAgent));
        if (errorSelector != 0) vm.expectRevert(errorSelector);
        if (joining) links.join(id, crewId);
        else links.leave(id);
        if (errorSelector != 0) {
            ++refused;
            return;
        }
        (,, uint256 afterMembers,,) = links.crew(crewId);
        assertEq(afterMembers, joining ? members + 1 : members - 1);
        assertEq(links.crewOf(id), joining ? crewId : 0);
        if (joining) {
            assertFalse(links.invited(crewId, id), "joining consumes the invitation");
            ++joins;
        }
    }

    function manage(uint256 crewSeed, uint256 memberSeed, uint8 action, bool asAgent) external {
        uint256 crewId = 1 + crewSeed % founded;
        uint256 id = memberSeed % 8;
        (uint256 captain, bytes32 label, uint256 members, bool open, bool alive) = links.crew(crewId);
        action %= 4;
        bytes4 errorSelector;
        if (!alive) errorSelector = LARPLinks.NoSuchCrew.selector;
        else if (action < 2 && links.crewOf(id) != crewId) errorSelector = LARPLinks.NotInCrew.selector;
        else if (action == 1 && captain == id) errorSelector = LARPLinks.CaptainStays.selector;
        vm.prank(_controller(captain, asAgent));
        if (errorSelector != 0) vm.expectRevert(errorSelector);
        if (action == 0) links.passCaptain(crewId, id);
        else if (action == 1) links.kick(crewId, id);
        else if (action == 2) links.disband(crewId);
        else links.setOpen(crewId, !open);
        if (errorSelector != 0) {
            ++refused;
            return;
        }
        (uint256 afterCaptain,, uint256 afterMembers, bool afterOpen, bool afterAlive) = links.crew(crewId);
        if (action == 0) {
            assertEq(afterCaptain, id);
            assertEq(afterMembers, members);
            ++captainChanges;
        } else if (action == 1) {
            assertEq(links.crewOf(id), 0);
            assertEq(afterMembers, members - 1);
        } else if (action == 2) {
            assertFalse(afterAlive);
            assertEq(afterMembers, 0);
            assertEq(links.crewByName(label), 0);
            for (uint256 k; k < 8; ++k) {
                assertTrue(links.crewOf(k) != crewId);
            }
            ended[crewId] = true;
            ++disbands;
        } else {
            assertEq(afterOpen, !open);
            assertEq(afterMembers, members);
        }
    }

    function friendship(uint256 meSeed, uint256 themSeed, bool remove, bool asAgent) external {
        uint256 me = meSeed % 8;
        uint256 them = themSeed % 8;
        uint256 count = links.frenCount(me);
        bool wasFren = links.isFren(me, them);
        bool accepting = links.asked(them, me);
        bytes4 errorSelector;
        if (!remove) {
            if (me == them) errorSelector = LARPLinks.SelfFren.selector;
            else if (wasFren) errorSelector = LARPLinks.AlreadyFrens.selector;
            else if (links.asked(me, them)) errorSelector = LARPLinks.AlreadyAsked.selector;
        }
        vm.prank(_controller(me, asAgent));
        if (errorSelector != 0) vm.expectRevert(errorSelector);
        if (remove) links.unfren(me, them);
        else links.fren(me, them);
        if (errorSelector != 0) {
            ++refused;
            return;
        }
        if (remove) {
            assertFalse(links.isFren(me, them));
            assertFalse(links.asked(me, them));
            assertFalse(links.asked(them, me));
            assertEq(links.frenCount(me), wasFren ? count - 1 : count);
        } else if (accepting) {
            assertTrue(links.isFren(me, them));
            assertEq(links.frenCount(me), count + 1);
            ++friendships;
        } else {
            assertTrue(links.asked(me, them));
            assertEq(links.frenCount(me), count, "an unanswered ask is not a fren");
        }
    }

    function changeAgent(uint256 seed, bool enable) external {
        uint256 id = seed % 8;
        vm.prank(identity.ownerOf(id));
        larp.setAgent(id, enable ? agents[id] : address(0));
    }

    function sellIdentity(uint256 seed, uint256 buyerSeed) external {
        uint256 id = seed % 8;
        address from = identity.ownerOf(id);
        address to = actors[buyerSeed % 4];
        uint256 crewId = links.crewOf(id);
        uint256 frens = links.frenCount(id);
        vm.prank(from);
        identity.transferFrom(from, to, id);
        assertEq(links.crewOf(id), crewId, "social membership belongs to the identity");
        assertEq(links.frenCount(id), frens);
        if (from != to) {
            vm.prank(from);
            vm.expectRevert(LARPLinks.NotYourIdentity.selector);
            links.unfren(id, (id + 1) % 8);
            ++refused;
        }
    }

    function unauthorized(uint256 seed, uint256 crewSeed) external {
        uint256 id = seed % 8;
        uint256 crewId = 1 + crewSeed % founded;
        (,,,, bool alive) = links.crew(crewId);
        vm.prank(address(this));
        vm.expectRevert(alive ? LARPLinks.NotCaptain.selector : LARPLinks.NoSuchCrew.selector);
        links.disband(crewId);
        vm.prank(address(this));
        vm.expectRevert(LARPLinks.NotYourIdentity.selector);
        links.join(id, crewId);
        vm.prank(address(this));
        vm.expectRevert(LARPLinks.NotYourIdentity.selector);
        links.fren(id, (id + 1) % 8);
        ++refused;
    }

    function _controller(uint256 id, bool asAgent) internal view returns (address) {
        (bool ok,) = larp.canAct(id, agents[id]);
        return asAgent && ok ? agents[id] : identity.ownerOf(id);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract LARPLinksLifecycleInvariantTest is Base {
    SocialLifecycleHandler internal handler;
    uint256 internal initialPmEth;

    function setUp() public {
        _deploy();
        _fillPool4();
        _fillBackup();
        _fillPair();
        initialPmEth = address(pm).balance;
        handler = new SocialLifecycleHandler(links, larp, names, burner, identity, imd);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.found.selector;
        selectors[1] = handler.invite.selector;
        selectors[2] = handler.joinOrLeave.selector;
        selectors[3] = handler.manage.selector;
        selectors[4] = handler.friendship.selector;
        selectors[5] = handler.changeAgent.selector;
        selectors[6] = handler.sellIdentity.selector;
        selectors[7] = handler.unauthorized.selector;
        selectors[8] = handler.friendship.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_CrewMembershipCountsAndNamesAgree() public view {
        assertEq(links.crewCount(), handler.founded());
        uint256 totalMembers;
        for (uint256 crewId = 1; crewId <= handler.founded(); ++crewId) {
            (uint256 captain, bytes32 label, uint256 members,, bool alive) = links.crew(crewId);
            assertEq(alive, !handler.ended(crewId), "a disbanded crew never reopens");
            uint256 counted;
            for (uint256 id; id < 8; ++id) {
                if (links.crewOf(id) == crewId) ++counted;
            }
            assertEq(members, counted, "every member appears in the count exactly once");
            if (alive) {
                assertGt(members, 0);
                assertEq(links.crewOf(captain), crewId, "a captain must be a member");
                assertEq(links.crewByName(label), crewId, "live names map to their only crew");
            } else {
                assertEq(members, 0);
                assertTrue(links.crewByName(label) != crewId);
            }
            totalMembers += members;
        }
        uint256 assigned;
        for (uint256 id; id < 8; ++id) {
            if (links.crewOf(id) != 0) ++assigned;
        }
        assertEq(totalMembers, assigned);
        assertLe(totalMembers, 8, "one crew per identity");
    }

    function invariant_FriendshipIsASymmetricSimpleGraph() public view {
        uint256 degreeSum;
        for (uint256 a; a < 8; ++a) {
            uint256 degree;
            assertFalse(links.isFren(a, a));
            assertFalse(links.asked(a, a));
            for (uint256 b; b < 8; ++b) {
                bool frens = links.isFren(a, b);
                assertEq(frens, links.isFren(b, a));
                if (frens) {
                    ++degree;
                    assertFalse(links.asked(a, b));
                    assertFalse(links.asked(b, a));
                } else {
                    assertFalse(links.asked(a, b) && links.asked(b, a), "reciprocal asks become frens");
                }
            }
            assertEq(links.frenCount(a), degree);
            degreeSum += degree;
        }
        assertEq(degreeSum % 2, 0, "every friendship has two endpoints");
    }

    function invariant_CardsFollowTheCurrentHolderAndSocialState() public view {
        for (uint256 id; id < 8; ++id) {
            LARPLinks.Card memory card = links.cardOf(id);
            assertEq(card.holder, identity.ownerOf(id));
            assertEq(card.crewId, links.crewOf(id));
            assertEq(card.frens, links.frenCount(id));
            if (card.crewId == 0) {
                assertEq(card.crewName, bytes32(0));
                assertFalse(card.captain);
            } else {
                (uint256 captain, bytes32 label,,, bool alive) = links.crew(card.crewId);
                assertTrue(alive);
                assertEq(card.crewName, label);
                assertEq(card.captain, captain == id);
            }
        }
    }

    function invariant_CrewFeesAreForwardedAndEthIsConserved() public view {
        assertEq(address(links).balance, 0);
        assertEq(imd.balanceOf(address(links)), 0);
        assertEq(imd.balanceOf(address(burner)), 0);
        assertEq(imd6900.balanceOf(address(burner)), 0);
        assertEq(handler.ethFees(), address(pm).balance - initialPmEth + address(burner).balance);
        assertEq(imd.balanceOf(0x000000000000000000000000000000000000dEaD), 0);
    }

    function test_HandlerExercisesInvitationsSuccessionAndNameReuse() public {
        handler.joinOrLeave(2, 1, true, false); // closed crew refuses
        handler.invite(1, 2, true, false);
        handler.joinOrLeave(2, 1, true, false);
        handler.manage(1, 2, 0, false); // captaincy 1 -> 2
        handler.changeAgent(2, true);
        handler.manage(1, 1, 1, true); // agent kicks the old captain
        handler.friendship(2, 3, false, true);
        handler.friendship(3, 2, false, false);
        handler.sellIdentity(2, 3);
        handler.manage(1, 0, 2, true); // new holder disbands
        handler.found(2, 1, false, true, false); // same label, new crew id
        handler.unauthorized(2, 2);
        assertEq(handler.joins(), 1);
        assertEq(handler.friendships(), 1);
        assertEq(handler.captainChanges(), 1);
        assertEq(handler.disbands(), 1);
        assertEq(handler.founded(), 3);
        assertEq(handler.imdFoundings(), 2);
        assertGt(handler.refused(), 0);
        invariant_CrewMembershipCountsAndNamesAgree();
        invariant_FriendshipIsASymmetricSimpleGraph();
        invariant_CardsFollowTheCurrentHolderAndSocialState();
        invariant_CrewFeesAreForwardedAndEthIsConserved();
    }
}
