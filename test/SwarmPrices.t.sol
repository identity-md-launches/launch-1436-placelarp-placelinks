// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.sol";
import {SwarmPrices, Attestation} from "../src/SwarmPrices.sol";

contract SwarmPricesTest is Base {
    event PricesChanged(bytes32 indexed requestId, SwarmPrices.Prices prices);

    address proposer = makeAddr("proposer");

    function setUp() public {
        _deploy();
        _fillPool4();
        identity.mint(alice, 0);
        imd.mint(proposer, 100 ether);
        vm.prank(proposer);
        imd.approve(address(names), type(uint256).max);
    }

    // --- helpers ---

    function _p(uint64 s, uint64 f, uint64 l, uint64 c) internal pure returns (SwarmPrices.Prices memory) {
        return SwarmPrices.Prices(s, f, l, c, 690);
    }

    function _now() internal view returns (SwarmPrices.Prices memory p) {
        (p.short, p.four, p.long, p.crew, p.share) = names.prices();
    }

    function _propose(SwarmPrices.Prices memory next) internal returns (bytes32 id) {
        vm.prank(proposer);
        id = names.propose(next, 0.5 ether);
    }

    /// @dev An attestation as IMD's oracle signs it: EIP-712 "IdentityMD Oracle" v2, for `forContract`.
    function _attest(
        bytes32 requestId,
        bool answer,
        uint16 panel,
        uint16 quorum,
        uint16 agreed,
        uint64 expiresAt,
        address forContract,
        uint256 key
    ) internal view returns (Attestation memory a, bytes memory sig) {
        a = Attestation({
            requestId: requestId,
            chainId: block.chainid,
            questionHash: keccak256("the question"),
            answerType: 0,
            answer: abi.encode(answer),
            figure: 0,
            fromBlock: uint64(block.number > 7200 ? block.number - 7200 : 0),
            toBlock: uint64(block.number),
            blockHash: blockhash(block.number > 0 ? block.number - 1 : 0),
            panelJobId: bytes32(bytes16(keccak256("panel job"))),
            panelSize: panel,
            quorum: quorum,
            agreed: agreed,
            issuedAt: uint64(block.timestamp),
            expiresAt: expiresAt
        });
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(
                    keccak256(
                        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
                    ),
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock,
                    a.toBlock
                ),
                abi.encode(a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt)
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IdentityMD Oracle"),
                keccak256("2"),
                block.chainid,
                forContract
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        sig = abi.encodePacked(r, s, v);
    }

    function _yes(bytes32 requestId) internal view returns (Attestation memory a, bytes memory sig) {
        return _attest(requestId, true, 9, 7, 9, uint64(block.timestamp + 1 days), address(names), oracleKey);
    }

    function _deliver(bytes32 id, Attestation memory a, bytes memory sig) internal returns (bool) {
        return intake.deliver(id, a, sig);
    }

    function _status(bytes32 id) internal view returns (SwarmPrices.Status) {
        return names.proposal(id).status;
    }

    // --- the start ---

    function test_StartPrices() public view {
        SwarmPrices.Prices memory p = _now();
        assertEq(p.short, 0.0069 ether);
        assertEq(p.four, 0.00169 ether);
        assertEq(p.long, 0.00069 ether);
        assertEq(p.crew, 0.00069 ether);
        assertEq(names.priceOf(_label("kek")), 0.0069 ether);
        assertEq(names.priceOf(_label("pepe")), 0.00169 ether);
        assertEq(names.priceOf(_label("frens")), 0.00069 ether);
        assertEq(names.crewPrice(), 0.00069 ether);
    }

    // --- proposing: permissionless, paid to IMD's oracle, the question written by the contract ---

    function test_AnyoneProposesAndTheContractWritesTheQuestion() public {
        bytes32 id = _propose(_p(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether));
        assertEq(imd.balanceOf(intake.treasury()), 0.5 ether, "IMD's oracle was paid");
        assertEq(imd.balanceOf(address(names)), 0, "nothing stays");
        assertEq(uint8(_status(id)), uint8(SwarmPrices.Status.Pending));

        string memory body = string(intake.lastBody());
        string memory question = vm.parseJsonString(body, ".question");
        assertTrue(
            _contains(
                question,
                "Current terms: 1-3 letter names 0.0069 ETH, 4 letter names 0.00169 ETH, 5+ letter names 0.00069 ETH, crews 0.00069 ETH, IMD6900 share 6.9%."
            )
        );
        assertTrue(
            _contains(
                question,
                "Proposed terms: 1-3 letter names 0.005 ETH, 4 letter names 0.0012 ETH, 5+ letter names 0.0005 ETH, crews 0.0005 ETH, IMD6900 share 6.9%."
            )
        );
        assertTrue(_contains(question, "LARP proposal #1 "));
        assertEq(vm.parseJsonString(body, ".answerType"), "bool");
        assertEq(vm.parseJsonString(body, ".evidence"), "panel");
        assertEq(vm.parseJsonUint(body, ".panelSize"), 9);
        assertEq(vm.parseJsonUint(body, ".quorum"), 7);
        assertEq(vm.parseJsonUint(body, ".chainId"), block.chainid);
        assertTrue(
            _contains(
                question, "a 5+ letter name costs between 1 and 5 US dollars, a crew costs between 1 and 5 US dollars"
            )
        );
        assertTrue(_contains(vm.parseJsonString(body, ".definitions.guidelines"), "1 to 5 US dollars"));
        assertTrue(vm.parseJsonBool(body, ".allowAmbiguous"));
    }

    function test_Guardrails() public {
        SwarmPrices.Prices[7] memory bad = [
            _p(0.0069 ether, 0.00169 ether, 0.000009 ether, 0.00069 ether), // under MIN_PRICE (and > 2x down)
            _p(0.0139 ether, 0.00169 ether, 0.00069 ether, 0.00069 ether), // more than 2x up
            _p(0.0069 ether, 0.00169 ether, 0.00034 ether, 0.00069 ether), // more than 2x down
            _p(0.0069 ether, 0.00169 ether, 0.00069 ether, 0.0014 ether), // the crew, more than 2x up
            _p(0.0016 ether, 0.00169 ether, 0.00069 ether, 0.00069 ether), // short names under 4 letter names (and > 2x)
            _p(0.0069 ether, 0.001 ether, 0.0013 ether, 0.00069 ether), // 4 letter names under 5+ letter names
            _p(0.0069 ether, 0.0069 ether, 0.0069 ether, 0.00069 ether) // 5+ letters 10x up
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(proposer);
            vm.expectRevert(SwarmPrices.OutOfBounds.selector);
            names.propose(bad[i], 0.5 ether);
        }
    }

    function test_TheOracleMustBePaid() public {
        SwarmPrices.Prices memory same = _now();
        vm.prank(proposer);
        vm.expectRevert(); // the Intake's PriceNotMet
        names.propose(same, 0.4 ether);
    }

    // --- the verdict ---

    function test_ApprovedThenAnyoneExecutes() public {
        SwarmPrices.Prices memory next = _p(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether);
        bytes32 id = _propose(next);
        (Attestation memory a, bytes memory sig) = _yes(id);
        assertTrue(_deliver(id, a, sig), "the callback fits the Intake's 200,000 gas");
        assertEq(uint8(_status(id)), uint8(SwarmPrices.Status.Approved));

        vm.expectEmit(address(names));
        emit PricesChanged(id, next);
        vm.prank(makeAddr("anyone"));
        names.execute(id);

        assertEq(names.priceOf(_label("frens")), 0.0005 ether);
        assertEq(names.priceOf(_label("kek")), 0.005 ether);
        assertEq(names.crewPrice(), 0.0005 ether);
        assertEq(names.epoch(), 1);
        assertEq(uint8(_status(id)), uint8(SwarmPrices.Status.Executed));

        // and the new prices are what names and crews cost
        vm.deal(carol, 1 ether);
        vm.prank(carol);
        names.register{value: 0.0005 ether}(_label("cheaper"), carol, 0);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        links.foundCrew{value: 0.0005 ether}(0, _label("cheap-crew"), true, 0);
    }

    function test_ARejectedProposalChangesNothing() public {
        bytes32 id = _propose(_p(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether));
        (Attestation memory a, bytes memory sig) =
            _attest(id, false, 9, 7, 9, uint64(block.timestamp + 1 days), address(names), oracleKey);
        _deliver(id, a, sig);
        assertEq(uint8(_status(id)), uint8(SwarmPrices.Status.Rejected));
        vm.expectRevert(SwarmPrices.NotApproved.selector);
        names.execute(id);
        assertEq(names.priceOf(_label("frens")), 0.00069 ether);
    }

    function test_AWeakPanelIsARejection() public {
        uint16[4][4] memory weak = [
            [uint16(8), 7, 8, 0], // a panel under 9
            [uint16(9), 6, 9, 0], // a quorum under 7
            [uint16(9), 7, 6, 0], // fewer agreed than the quorum
            [uint16(10), 7, 10, 0] // 7 of 10 is under 7 in 9
        ];
        for (uint256 i; i < weak.length; ++i) {
            bytes32 id = _propose(_p(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether));
            (Attestation memory a, bytes memory sig) = _attest(
                id,
                true,
                weak[i][0],
                weak[i][1],
                weak[i][2],
                uint64(block.timestamp + 1 days),
                address(names),
                oracleKey
            );
            _deliver(id, a, sig);
            assertEq(uint8(_status(id)), uint8(SwarmPrices.Status.Rejected));
        }
    }

    function test_AnExpiredVerdictIsARejection() public {
        bytes32 id = _propose(_p(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether));
        (Attestation memory a, bytes memory sig) =
            _attest(id, true, 9, 7, 9, uint64(block.timestamp - 1), address(names), oracleKey);
        _deliver(id, a, sig);
        assertEq(uint8(_status(id)), uint8(SwarmPrices.Status.Rejected));
    }

    function test_OnlyTheOraclesSignatureForThisContractCounts() public {
        bytes32 id = _propose(_p(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether));
        (Attestation memory a, bytes memory sig) =
            _attest(id, true, 9, 7, 9, uint64(block.timestamp + 1 days), address(names), 0xBAD);
        assertFalse(_deliver(id, a, sig), "another key: refused");
        (a, sig) = _attest(id, true, 9, 7, 9, uint64(block.timestamp + 1 days), address(links), oracleKey);
        assertFalse(_deliver(id, a, sig), "signed for another contract: refused");
        (a, sig) = _yes(id);
        sig[64] = sig[64] == bytes1(uint8(27)) ? bytes1(uint8(28)) : bytes1(uint8(27));
        assertFalse(_deliver(id, a, sig), "a tampered signature: refused");
        assertEq(uint8(_status(id)), uint8(SwarmPrices.Status.Pending), "still waiting for a real verdict");
        (a, sig) = _yes(id);
        assertTrue(_deliver(id, a, sig));
    }

    function test_OnlyTheIntakeDeliversAndOnlyForItsOwnProposals() public {
        bytes32 id = _propose(_p(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether));
        (Attestation memory a, bytes memory sig) = _yes(id);
        vm.expectRevert(SwarmPrices.NotIntake.selector);
        names.onVerdict(id, a, sig);
        vm.expectRevert(SwarmPrices.NotIntake.selector);
        names.onNoVerdict(id, 2, bytes32("disagreed"), 0, 0, "");
        // an answer to someone else's question, named at this contract: no proposal of ours
        vm.prank(address(intake));
        vm.expectRevert(SwarmPrices.NotPending.selector);
        names.onVerdict(keccak256("someone else's ask"), a, sig);
    }

    function test_NoVerdictClosesTheProposal() public {
        bytes32 id = _propose(_p(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether));
        assertTrue(intake.fail(id, 2, bytes32("disagreed")));
        assertEq(uint8(_status(id)), uint8(SwarmPrices.Status.Failed));
        (Attestation memory a, bytes memory sig) = _yes(id);
        assertFalse(_deliver(id, a, sig), "a closed proposal takes no verdict");
    }

    // --- executing ---

    function test_AVerdictCannotApproveAnotherPendingProposal() public {
        bytes32 first = _propose(_p(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether));
        SwarmPrices.Prices memory other = _p(0.008 ether, 0.002 ether, 0.0008 ether, 0.0008 ether);
        other.share = 1380;
        bytes32 second = _propose(other);
        (Attestation memory a, bytes memory sig) = _yes(first);
        assertTrue(_deliver(first, a, sig));
        vm.prank(address(intake));
        vm.expectRevert(SwarmPrices.BadVerdictSignature.selector);
        names.onVerdict(second, a, sig);
        assertEq(uint8(_status(second)), uint8(SwarmPrices.Status.Pending));
        assertEq(names.proposal(second).decidedAt, 0);
        vm.expectRevert(SwarmPrices.NotApproved.selector);
        names.execute(second);
        names.execute(first);
        assertEq(names.imd6900ShareBps(), 690, "the unrelated share change was not approved");
    }

    function testFuzz_AWrongRequestCannotSettleAPendingProposal(bytes32 wrongRequest) public {
        bytes32 id = _propose(_p(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether));
        vm.assume(wrongRequest != id);
        (Attestation memory a, bytes memory sig) = _yes(wrongRequest);
        assertFalse(_deliver(id, a, sig));
        assertEq(uint8(_status(id)), uint8(SwarmPrices.Status.Pending));
        assertEq(names.proposal(id).decidedAt, 0);
        (a, sig) = _yes(id);
        assertTrue(_deliver(id, a, sig), "a mismatched delivery does not close the request");
        names.execute(id);
        assertEq(names.priceOf(bytes32("frens")), 0.0005 ether);
    }

    function test_ChangingTheSignedRequestIdInvalidatesTheSignature() public {
        bytes32 first = _propose(_p(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether));
        bytes32 second = _propose(_p(0.008 ether, 0.002 ether, 0.0008 ether, 0.0008 ether));
        (Attestation memory a, bytes memory sig) = _yes(first);
        a.requestId = second;
        assertFalse(_deliver(second, a, sig), "matching the parameter cannot repair a signature for another id");
        assertEq(uint8(_status(first)), uint8(SwarmPrices.Status.Pending));
        assertEq(uint8(_status(second)), uint8(SwarmPrices.Status.Pending));
        (a, sig) = _yes(second);
        assertTrue(_deliver(second, a, sig));
        assertFalse(_deliver(second, a, sig), "a matching verdict still settles only once");
    }

    function _approved(SwarmPrices.Prices memory next) internal returns (bytes32 id) {
        id = _propose(next);
        (Attestation memory a, bytes memory sig) = _yes(id);
        _deliver(id, a, sig);
    }

    function test_OneChangeAWeek() public {
        bytes32 first = _approved(_p(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether));
        names.execute(first);
        bytes32 second = _approved(_p(0.004 ether, 0.001 ether, 0.0004 ether, 0.0004 ether));
        vm.expectRevert(SwarmPrices.Cooling.selector);
        names.execute(second);
        vm.warp(block.timestamp + 7 days);
        names.execute(second);
        assertEq(names.priceOf(_label("frens")), 0.0004 ether);
    }

    function test_AProposalForOldPricesGoesStale() public {
        bytes32 a = _approved(_p(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether));
        bytes32 b = _approved(_p(0.008 ether, 0.002 ether, 0.0008 ether, 0.0008 ether));
        names.execute(a);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(SwarmPrices.Stale.selector);
        names.execute(b);
    }

    function test_AVerdictMustBeUsedWithinTwoWeeks() public {
        bytes32 id = _approved(_p(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether));
        vm.warp(block.timestamp + 14 days + 1);
        vm.expectRevert(SwarmPrices.NotApproved.selector);
        names.execute(id);
    }

    function test_ExecutedOnce() public {
        bytes32 id = _approved(_p(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether));
        names.execute(id);
        vm.expectRevert(SwarmPrices.NotApproved.selector);
        names.execute(id);
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool m = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    m = false;
                    break;
                }
            }
            if (m) return true;
        }
        return false;
    }
}

/// @dev IMD Names stand-ins for the burner's share read: one that reverts, one that answers more than all, one that
///      burns all the gas it gets
contract RevertingShare {
    function imd6900ShareBps() external pure returns (uint256) {
        revert("no");
    }
}

contract TooMuchShare {
    function imd6900ShareBps() external pure returns (uint256) {
        return 10_001;
    }
}

contract GasEatingShare {
    function imd6900ShareBps() external view returns (uint256 s) {
        while (gasleft() > 100) s++;
    }
}

/// @title The IMD6900 share: 6.9% at launch, swarm-voted with the prices, 0 to 100%; the rest goes to IMD's burn
contract SwarmShareTest is Base {
    address proposer = makeAddr("proposer");

    function setUp() public {
        _deploy();
        _fillPool4();
        _fillPair();
        imd.mint(proposer, 100 ether);
        vm.prank(proposer);
        imd.approve(address(names), type(uint256).max);
    }

    function _terms(uint16 share) internal view returns (SwarmPrices.Prices memory p) {
        (p.short, p.four, p.long, p.crew,) = names.prices();
        p.share = share;
    }

    function _yes(bytes32 requestId) internal view returns (Attestation memory a, bytes memory sig) {
        a = Attestation({
            requestId: requestId,
            chainId: block.chainid,
            questionHash: keccak256("the question"),
            answerType: 0,
            answer: abi.encode(true),
            figure: 0,
            fromBlock: uint64(block.number > 7200 ? block.number - 7200 : 0),
            toBlock: uint64(block.number),
            blockHash: blockhash(block.number > 0 ? block.number - 1 : 0),
            panelJobId: bytes32(bytes16(keccak256("panel job"))),
            panelSize: 9,
            quorum: 7,
            agreed: 9,
            issuedAt: uint64(vm.getBlockTimestamp()), // not block.timestamp: via-IR may reuse a read from before a warp
            expiresAt: uint64(vm.getBlockTimestamp() + 1 days)
        });
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(
                    keccak256(
                        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
                    ),
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock,
                    a.toBlock
                ),
                abi.encode(a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt)
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IdentityMD Oracle"),
                keccak256("2"),
                block.chainid,
                address(names)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(oracleKey, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        sig = abi.encodePacked(r, s, v);
    }

    /// @dev Proposes, approves and applies a share, a week after the last change
    function _set(uint16 share) internal {
        SwarmPrices.Prices memory next = _terms(share); // read before the prank: a read would take it
        vm.prank(proposer);
        bytes32 id = names.propose(next, 0.5 ether);
        (Attestation memory a, bytes memory sig) = _yes(id);
        intake.deliver(id, a, sig);
        names.execute(id);
        vm.warp(vm.getBlockTimestamp() + 7 days);
    }

    /// @dev Burns `amount` $IMD through the burner; returns what reached IMD's burn
    function _burn(uint256 amount) internal returns (uint256 toImdBurn) {
        uint256 before = imd.balanceOf(burner.IMD_BURN());
        imd.mint(address(burner), amount);
        burner.burnImd{gas: 10_000_000}();
        toImdBurn = imd.balanceOf(burner.IMD_BURN()) - before;
    }

    function test_StartsAt6Point9AndTheBurnerReadsItFromIMDNames() public {
        assertEq(burner.NAMES(), address(names), "the burner knows IMD Names");
        assertEq(names.imd6900ShareBps(), 690);
        assertEq(burner.shareBps(), 690);
        assertEq(_burn(100 ether), 100 ether - 6.9 ether, "93.1% to IMD's burn");
        assertEq(imd.balanceOf(0x000000000000000000000000000000000000dEaD), 0, "nothing parked at 0x..dEaD");
    }

    function test_TheSwarmMovesTheShareAndTheBurnerFollows() public {
        _set(1380);
        assertEq(names.imd6900ShareBps(), 1380);
        assertEq(burner.shareBps(), 1380);
        assertEq(_burn(100 ether), 100 ether - 13.8 ether, "86.2% to IMD's burn");
    }

    /// @dev The share can reach 100%, but one burn never sells the pair pool more than 2% of its $IMD depth (the
    /// burner's PAIR_LEG_BPS; L-16): a leg that size is a loss to sandwich through the pair's fee whatever the
    /// swarm voted, and the rest of the share goes to IMD's burn instead of a searcher. Before L-16 a 1,000 $IMD
    /// burn at 100% sold all of it into a pool holding ~1,000 $IMD.
    function test_UpToAllOfIt() public {
        _set(1380);
        _set(2760);
        _set(5520);
        _set(10_000);
        assertEq(burner.shareBps(), 10_000);
        uint256 supply = imd6900.totalSupply();
        uint256 room = _pairRoom();
        assertApproxEqRel(room, 20 ether, 0.01e18, "2% of the pool's ~1,000 $IMD");
        uint256 pmImd = imd.balanceOf(address(pm));
        assertEq(_burn(1000 ether), 1000 ether - room, "all of it is the share, but only the pool's room buys IMD6900");
        assertEq(imd.balanceOf(address(pm)) - pmImd, room, "exactly the room went into the pair pool");
        assertLt(imd6900.totalSupply(), supply, "and the IMD6900 was burned");
        // a burn the pool can take whole at 100% is all IMD6900
        assertEq(_burn(10 ether), 0, "under the room, all of it bought IMD6900: nothing left for IMD's burn");
    }

    function test_AndDownToNothing() public {
        _set(345);
        _set(173); // half, rounded up: 172 would be less than half
        _set(87);
        _set(0); // the last point
        assertEq(burner.shareBps(), 0);
        assertEq(_burn(1000 ether), 1000 ether, "all of it to IMD's burn");
    }

    function test_ShareGuardrails() public {
        SwarmPrices.Prices memory tooHigh = _terms(1381); // more than 2x
        SwarmPrices.Prices memory tooLow = _terms(344); // less than half, more than a point
        SwarmPrices.Prices memory overAll = _terms(10_001); // more than all
        SwarmPrices.Prices memory point = _terms(790); // a point
        SwarmPrices.Prices memory twice = _terms(1380); // 2x
        SwarmPrices.Prices memory half = _terms(345); // half
        vm.startPrank(proposer);
        vm.expectRevert(SwarmPrices.OutOfBounds.selector);
        names.propose(tooHigh, 0.5 ether);
        vm.expectRevert(SwarmPrices.OutOfBounds.selector);
        names.propose(tooLow, 0.5 ether);
        vm.expectRevert(SwarmPrices.OutOfBounds.selector);
        names.propose(overAll, 0.5 ether);
        names.propose(point, 0.5 ether);
        names.propose(twice, 0.5 ether);
        names.propose(half, 0.5 ether);
        vm.stopPrank();
    }

    function test_TheQuestionNamesTheShare() public {
        SwarmPrices.Prices memory next = _terms(1380);
        vm.prank(proposer);
        names.propose(next, 0.5 ether);
        bytes memory body = intake.lastBody();
        assertTrue(_contains(string(body), "IMD6900 share 6.9%"), "the current share");
        assertTrue(_contains(string(body), "IMD6900 share 13.8%"), "the proposed share");
        assertTrue(_contains(string(body), "the IMD6900 share is between 0% and 100%"), "the guideline");
        // L-16: a rising share has a criterion of its own, the pair pool's depth, not only the bounds the contract
        // already enforces
        assertTrue(
            _contains(
                string(body),
                "if the IMD6900 share rises, the IMD6900/$IMD pool can take it: the proposed share of the $IMD that 0.1 ETH buys on IMD's ETH/$IMD pool is at most 2% of the IMD6900/$IMD pool's $IMD depth"
            ),
            "the share's criterion"
        );
        assertTrue(_contains(string(body), "Answer true if all six hold"), "six guidelines");
        assertTrue(_contains(string(body), "\"IMD6900/$IMD pool's $IMD depth\":\""), "the depth is defined");
    }

    function test_TheBurnerFallsBackTo6Point9() public {
        assertEq(_newBurner(address(pm), address(0)).shareBps(), 690, "no IMD Names");
        assertEq(_newBurner(address(pm), makeAddr("nothing there")).shareBps(), 690, "no code");
        assertEq(_newBurner(address(pm), address(new RevertingShare())).shareBps(), 690, "reverts");
        assertEq(_newBurner(address(pm), address(new TooMuchShare())).shareBps(), 690, "more than all");
        assertEq(_newBurner(address(pm), address(new GasEatingShare())).shareBps(), 690, "eats its gas");
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool ok = true;
            for (uint256 j; j < n.length && ok; ++j) {
                ok = h[i + j] == n[j];
            }
            if (ok) return true;
        }
        return false;
    }
}
