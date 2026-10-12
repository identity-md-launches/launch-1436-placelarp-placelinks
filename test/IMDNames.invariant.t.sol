// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {Base, MockIMD} from "./Base.sol";
import {MockNFT} from "./Mocks.sol";
import {IMDNames} from "../src/IMDNames.sol";
import {IIMDNames} from "../src/IIMDNames.sol";
import {LARP} from "../src/LARP.sol";
import {ILARP} from "../src/ILARP.sol";
import {LARPBurner} from "../src/LARPBurner.sol";

/// @dev The NFT ledger is modeled independently of IMDNames. Links are checked as
/// bijections through the public API, not by copying _link's bookkeeping.
contract NamesLifecycleHandler is Test {
    IMDNames public immutable names;
    LARP public immutable larp;
    LARPBurner public immutable burner;
    MockNFT public immutable identity;
    MockIMD public immutable imd;
    address[4] public actors;
    address[8] public agents;
    bytes32[12] public labels = [
        bytes32("a"),
        bytes32("ab"),
        bytes32("abc"),
        bytes32("abcd"),
        bytes32("abcde"),
        bytes32("sixsix"),
        bytes32("a-b"),
        bytes32("1234"),
        bytes32("abcdefghijklmnopqrstuvwxyz012345"),
        bytes32("nine-nine"),
        bytes32("ten10"),
        bytes32("last")
    ];
    mapping(uint256 => address) public expectedOwner;
    mapping(uint256 => address) public lastPayer;
    mapping(uint256 => address) public identityOwner;
    mapping(uint256 => address) public agentHolder;
    mapping(uint256 => bool) public agentEnabled;
    mapping(uint256 => mapping(address => string)) public expectedText;
    mapping(address => uint256) public expectedPrimary;
    uint256 public minted;
    uint256 public ethFees;
    uint256 public registrations;
    uint256 public transfers;
    uint256 public linksPaid;
    uint256 public refused;

    constructor(IMDNames n, LARP l, LARPBurner b, MockNFT i, MockIMD token) {
        names = n;
        larp = l;
        burner = b;
        identity = i;
        imd = token;
        for (uint256 a; a < 4; ++a) {
            actors[a] = makeAddr(string.concat("names holder ", vm.toString(a)));
            vm.deal(actors[a], 100 ether);
            imd.mint(actors[a], 1_000_000 ether);
            vm.prank(actors[a]);
            imd.approve(address(names), type(uint256).max);
        }
        for (uint256 id; id < 8; ++id) {
            agents[id] = makeAddr(string.concat("names agent ", vm.toString(id)));
            identityOwner[id] = actors[id % 4];
            identity.mint(identityOwner[id], id);
            vm.deal(agents[id], 100 ether);
            imd.mint(agents[id], 1_000_000 ether);
            vm.prank(agents[id]);
            imd.approve(address(names), type(uint256).max);
        }
        // Every generated sequence starts with transferable NFTs and live links,
        // including identity 0 and each of the three price bands.
        for (uint256 id; id < 4; ++id) {
            _register(id, actors[id], actors[id], false);
            vm.prank(actors[id]);
            names.link(uint256(labels[id]), id, 0);
        }
    }

    function registerName(uint256 labelSeed, uint256 payerSeed, uint256 toSeed, bool inImd) external {
        uint256 index = labelSeed % labels.length;
        address payer = actors[payerSeed % 4];
        address to = actors[toSeed % 4];
        if (expectedOwner[index] != address(0)) {
            uint256 fee = names.priceOf(labels[index]);
            vm.prank(payer);
            vm.expectRevert(ERC721.TokenAlreadyExists.selector);
            names.register{value: fee}(labels[index], to, 0);
            ++refused;
            return;
        }
        _register(index, payer, to, inImd);
    }

    function _register(uint256 index, address payer, address to, bool inImd) internal {
        uint256 price = names.priceOf(labels[index]);
        uint256 beforeEth = payer.balance;
        uint256 beforeImd = imd.balanceOf(payer);
        uint256 due = inImd ? burner.quoteImd(price) : 0;
        vm.prank(payer);
        uint256 id =
            inImd ? names.registerWithImd(labels[index], to, due) : names.register{value: price}(labels[index], to, 0);
        assertEq(id, uint256(labels[index]));
        assertEq(payer.balance, beforeEth - (inImd ? 0 : price), "only the payer funds registration");
        assertEq(imd.balanceOf(payer), beforeImd - due, "exact IMD quote is charged");
        if (!inImd) ethFees += price;
        expectedOwner[index] = to;
        lastPayer[index] = to; // gifting registration pays the recipient's first link
        ++minted;
        ++registrations;
    }

    function transferName(uint256 seed, uint256 toSeed, uint8 mode) external {
        uint256 index = _existing(seed);
        uint256 tokenId = uint256(labels[index]);
        address from = expectedOwner[index];
        address to = actors[toSeed % 4];
        address operator = agents[index % 8];
        uint256 beforeEth = address(burner).balance;
        uint256 beforeImd = imd.balanceOf(burner.IMD_BURN());
        mode %= 5;
        if (mode == 1) {
            vm.prank(from);
            names.approve(operator, tokenId);
            assertEq(names.getApproved(tokenId), operator);
        } else if (mode == 2) {
            vm.prank(from);
            names.setApprovalForAll(operator, true);
            assertTrue(names.isApprovedForAll(from, operator));
        }
        vm.prank(mode == 1 || mode == 2 ? operator : from);
        if (mode == 3) names.safeTransferFrom(from, to, tokenId);
        else if (mode == 4) names.safeTransferFrom(from, to, tokenId, abi.encode(seed));
        else names.transferFrom(from, to, tokenId);
        if (mode == 2) {
            vm.prank(from);
            names.setApprovalForAll(operator, false);
            assertFalse(names.isApprovedForAll(from, operator));
        }
        expectedOwner[index] = to;
        assertEq(names.getApproved(tokenId), address(0), "all transfer forms clear token approval");
        assertEq(address(burner).balance, beforeEth);
        assertEq(imd.balanceOf(burner.IMD_BURN()), beforeImd, "the mandatory toll is paid on linking");
        ++transfers;
    }

    function transferIdentity(uint256 seed, uint256 toSeed) external {
        uint256 id = seed % 8;
        address from = identityOwner[id];
        address to = actors[toSeed % 4];
        vm.prank(from);
        identity.transferFrom(from, to, id);
        identityOwner[id] = to;
    }

    function changeAgent(uint256 seed, bool enable) external {
        uint256 id = seed % 8;
        address holder = identityOwner[id];
        uint256 nonce = larp.nonces(holder);
        vm.prank(holder);
        larp.setAgent(id, enable ? agents[id] : address(0));
        agentEnabled[id] = enable;
        agentHolder[id] = holder;
        assertEq(larp.nonces(holder), nonce + 1);
    }

    function resign(uint256 seed) external {
        uint256 id = seed % 8;
        vm.prank(agents[id]);
        if (!agentEnabled[id]) {
            vm.expectRevert(ILARP.NotTheAgent.selector);
            larp.resignAgent(id);
            ++refused;
        } else {
            larp.resignAgent(id);
            agentEnabled[id] = false;
        }
    }

    function linkName(uint256 nameSeed, uint256 identitySeed, bool asAgent, bool inImd) external {
        uint256 index = _existing(nameSeed);
        uint256 id = identitySeed % 8;
        address holder = identityOwner[id];
        address caller = asAgent ? agents[id] : holder;
        uint256 tokenId = uint256(labels[index]);
        if (asAgent && !_agentLive(id)) {
            vm.prank(caller);
            vm.expectRevert(IIMDNames.NotYourIdentity.selector);
            names.link(tokenId, id, 0);
            ++refused;
            return;
        }
        if (expectedOwner[index] != holder) {
            vm.prank(caller);
            vm.expectRevert(IIMDNames.NotYourName.selector);
            names.link(tokenId, id, 0);
            ++refused;
            return;
        }
        uint256 toll = holder == lastPayer[index] ? 0 : names.priceOf(labels[index]);
        uint256 beforeEth = caller.balance;
        uint256 beforeImd = imd.balanceOf(caller);
        uint256 due = inImd && toll != 0 ? burner.quoteImd(toll) : 0;
        vm.prank(caller);
        if (inImd) names.linkWithImd(tokenId, id, due);
        else names.link{value: toll}(tokenId, id, 0);
        assertEq(caller.balance, beforeEth - (inImd ? 0 : toll));
        assertEq(imd.balanceOf(caller), beforeImd - due);
        if (!inImd) ethFees += toll;
        if (toll != 0) ++linksPaid;
        lastPayer[index] = holder;
        assertEq(names.nameOf(id), names.nameOfToken(tokenId));
        (uint256 linked, bool live) = names.identityOf(tokenId);
        assertEq(linked, id);
        assertTrue(live);
    }

    function unlinkName(uint256 seed, bool asAgent) external {
        uint256 id = seed % 8;
        bool liveAgent = asAgent && _agentLive(id);
        vm.prank(liveAgent ? agents[id] : identityOwner[id]);
        names.unlink(id);
        assertEq(names.nameOf(id), "");
    }

    function setTextAndPrimary(uint256 seed, uint256 value, bool asAgent) external {
        uint256 id = seed % 8;
        address holder = identityOwner[id];
        address caller = asAgent && _agentLive(id) ? agents[id] : holder;
        string memory textValue = vm.toString(value);
        vm.prank(caller);
        names.setText(id, "url", textValue);
        expectedText[id][holder] = textValue;
        if (caller != holder) {
            vm.prank(caller);
            vm.expectRevert(IIMDNames.NotYourIdentity.selector);
            names.setPrimary(id);
            ++refused;
        } else {
            vm.prank(holder);
            names.setPrimary(id);
            expectedPrimary[holder] = id + 1;
        }
    }

    /// @dev Mutations that start before payment must all roll back if the caller's
    /// limit fails, even after unrelated transfers/links/agent changes.
    function refusePayment(uint256 seed, bool inImd) external {
        uint256 index = _existing(seed);
        uint256 id = seed % 8;
        address holder = identityOwner[id];
        uint256 tokenId = uint256(labels[index]);
        if (expectedOwner[index] != holder) {
            vm.prank(expectedOwner[index]);
            names.transferFrom(expectedOwner[index], holder, tokenId);
            expectedOwner[index] = holder;
        }
        string memory oldName = names.nameOf(id);
        (uint256 oldId, bool oldLive) = names.identityOf(tokenId);
        uint256 toll = holder == lastPayer[index] ? 0 : names.priceOf(labels[index]);
        uint256 beforeEth = holder.balance;
        uint256 beforeImd = imd.balanceOf(holder);
        if (inImd && toll != 0) {
            uint256 due = burner.quoteImd(toll);
            vm.prank(holder);
            vm.expectRevert(IIMDNames.TooMuchImd.selector);
            names.linkWithImd(tokenId, id, due - 1);
        } else {
            vm.prank(holder);
            vm.expectRevert(IIMDNames.WrongPrice.selector);
            names.link{value: toll + 1}(tokenId, id, 0);
        }
        assertEq(holder.balance, beforeEth);
        assertEq(imd.balanceOf(holder), beforeImd);
        assertEq(names.nameOf(id), oldName, "failed link retains the previous name");
        (uint256 afterId, bool afterLive) = names.identityOf(tokenId);
        assertEq(afterId, oldId);
        assertEq(afterLive, oldLive);
        assertEq(names.tollOf(tokenId), toll, "a failed payment never marks a toll paid");
        ++refused;
    }

    function unauthorized(uint256 seed) external {
        uint256 index = _existing(seed);
        uint256 tokenId = uint256(labels[index]);
        address stranger = address(this);
        vm.prank(stranger);
        vm.expectRevert(ERC721.NotOwnerNorApproved.selector);
        names.transferFrom(expectedOwner[index], stranger, tokenId);
        vm.prank(stranger);
        vm.expectRevert(ERC721.NotOwnerNorApproved.selector);
        names.approve(stranger, tokenId);
        vm.prank(stranger);
        vm.expectRevert(IIMDNames.NotYourIdentity.selector);
        names.setText(seed % 8, "url", "forged");
        ++refused;
    }

    function _agentLive(uint256 id) internal view returns (bool) {
        return agentEnabled[id] && agentHolder[id] == identityOwner[id];
    }

    function _existing(uint256 seed) internal view returns (uint256 index) {
        index = seed % labels.length;
        while (expectedOwner[index] == address(0)) index = (index + 1) % labels.length;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract IMDNamesLifecycleInvariantTest is Base {
    NamesLifecycleHandler internal handler;
    uint256 internal initialPmEth;

    function setUp() public {
        _deploy();
        _fillPool4();
        _fillBackup();
        _fillPair();
        initialPmEth = address(pm).balance;
        handler = new NamesLifecycleHandler(names, larp, burner, identity, imd);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.registerName.selector;
        selectors[1] = handler.transferName.selector;
        selectors[2] = handler.transferIdentity.selector;
        selectors[3] = handler.changeAgent.selector;
        selectors[4] = handler.resign.selector;
        selectors[5] = handler.linkName.selector;
        selectors[6] = handler.unlinkName.selector;
        selectors[7] = handler.setTextAndPrimary.selector;
        selectors[8] = handler.refusePayment.selector;
        selectors[9] = handler.unauthorized.selector;
        selectors[10] = handler.linkName.selector; // give link moves a second share of calls
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_NftBalancesEqualTheIndependentOwnershipLedger() public view {
        uint256 total;
        for (uint256 a; a < 4; ++a) {
            address holder = handler.actors(a);
            uint256 count;
            for (uint256 i; i < 12; ++i) {
                if (handler.expectedOwner(i) != holder) continue;
                ++count;
                assertEq(names.ownerOf(uint256(handler.labels(i))), holder);
            }
            assertEq(names.balanceOf(holder), count);
            total += count;
        }
        assertEq(total, handler.minted(), "transfers neither mint nor destroy names");
    }

    function invariant_LiveLinksRoundTripAndRequireBothAssets() public view {
        for (uint256 i; i < 12; ++i) {
            bytes32 label = handler.labels(i);
            address owner = handler.expectedOwner(i);
            (bool exists, address resolved, uint256 id, bool live) = names.resolve(label);
            assertEq(exists, owner != address(0));
            assertEq(resolved, owner);
            (bool byName, address fullOwner, uint256 fullId, bool fullLive) =
                names.resolveName(names.nameOfToken(uint256(label)));
            assertEq(byName, exists);
            assertEq(fullOwner, resolved);
            assertEq(fullId, id);
            assertEq(fullLive, live);
            if (live) {
                assertEq(identity.ownerOf(id), owner, "live link requires the same holder");
                assertEq(names.nameOf(id), names.nameOfToken(uint256(label)));
                assertEq(names.tollOf(uint256(label)), 0, "live link is paid");
            }
        }
        for (uint256 id; id < 8; ++id) {
            string memory full = names.nameOf(id);
            if (bytes(full).length == 0) continue;
            (bool exists, address owner, uint256 back, bool live) = names.resolveName(full);
            assertTrue(exists && live, "no dangling reverse links");
            assertEq(back, id, "one name cannot resolve two identities");
            assertEq(owner, identity.ownerOf(id));
        }
    }

    function invariant_OnlyTheLastPayingHolderHasAFreeLink() public view {
        for (uint256 i; i < 12; ++i) {
            address owner = handler.expectedOwner(i);
            if (owner == address(0)) continue;
            uint256 toll = names.tollOf(uint256(handler.labels(i)));
            if (owner == handler.lastPayer(i)) assertEq(toll, 0);
            else assertEq(toll, names.priceOf(handler.labels(i)));
        }
    }

    function invariant_RecordsAndAgentsFollowTheirRecordedHolder() public view {
        for (uint256 id; id < 8; ++id) {
            address owner = handler.identityOwner(id);
            assertEq(identity.ownerOf(id), owner);
            assertEq(names.text(id, "url"), handler.expectedText(id, owner));
            (bool ok, address returnedHolder) = larp.canAct(id, handler.agents(id));
            assertEq(ok, handler.agentEnabled(id) && handler.agentHolder(id) == owner);
            assertEq(returnedHolder, owner);
        }
        for (uint256 a; a < 4; ++a) {
            address actor = handler.actors(a);
            uint256 primary = handler.expectedPrimary(actor);
            (uint256 id, string memory full, bool live) = names.primaryOf(actor);
            if (primary == 0) {
                assertFalse(live);
                assertEq(full, "");
            } else {
                assertEq(id, primary - 1);
                assertEq(live, identity.ownerOf(id) == actor);
                assertEq(full, live ? names.nameOf(id) : "");
            }
        }
    }

    function invariant_NameFeesAreForwardedAndEthIsConserved() public view {
        assertEq(address(names).balance, 0);
        assertEq(imd.balanceOf(address(names)), 0);
        assertEq(imd.balanceOf(address(burner)), 0);
        assertEq(imd6900.balanceOf(address(burner)), 0);
        assertEq(handler.ethFees(), address(pm).balance - initialPmEth + address(burner).balance);
        assertEq(imd.balanceOf(0x000000000000000000000000000000000000dEaD), 0);
    }

    /// @dev Deterministic reachability check: the handlers must actually reach
    /// paid resale, both currencies, approval transfers and refusals.
    function test_HandlerExercisesPaidResalesAndRejectsFailures() public {
        handler.transferName(0, 1, 1);
        handler.linkName(0, 1, false, true);
        handler.transferName(0, 2, 2);
        handler.changeAgent(2, true);
        handler.linkName(0, 2, true, false);
        handler.registerName(4, 0, 3, true);
        handler.registerName(5, 0, 3, false);
        handler.refusePayment(0, true);
        handler.unauthorized(4);
        handler.setTextAndPrimary(2, 69, true);
        handler.transferIdentity(2, 1);
        handler.linkName(0, 2, true, false);
        handler.resign(2);
        assertEq(handler.linksPaid(), 2);
        assertEq(handler.transfers(), 2);
        assertEq(handler.registrations(), 6);
        assertGt(handler.refused(), 0);
        invariant_NftBalancesEqualTheIndependentOwnershipLedger();
        invariant_LiveLinksRoundTripAndRequireBothAssets();
        invariant_OnlyTheLastPayingHolderHasAFreeLink();
        invariant_RecordsAndAgentsFollowTheirRecordedHolder();
        invariant_NameFeesAreForwardedAndEthIsConserved();
    }
}
