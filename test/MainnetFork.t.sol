// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LARP} from "../src/LARP.sol";
import {ILARP} from "../src/ILARP.sol";
import {IMDNames} from "../src/IMDNames.sol";
import {LARPLinks} from "../src/LARPLinks.sol";
import {LARPBurner} from "../src/LARPBurner.sol";
import {SwarmPrices, Attestation} from "../src/SwarmPrices.sol";

interface IERC721Like {
    function ownerOf(uint256) external view returns (address);
    function tokenURI(uint256) external view returns (string memory);
    function transferFrom(address, address, uint256) external;
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @dev The real thing on an Ethereum fork: identity.md, Worker Frens, POOL4, the hookless ETH/$IMD pool, IMD's
/// launcher, and real swarm airdrop proofs (test/fixtures/allocs.json, from GET api.imd.fun/launches/<id>?claims=1). Runs when
/// MAINNET_RPC_URL is set, skips otherwise (IMD's swarm builds without an RPC).
contract MainnetForkTest is Test {
    address constant IDENTITY = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant POOL4_HOOK = 0xc6C965Bd164c483e87d0B550671798e9A3602840;
    address constant IMD_BURN = 0xe29386719C155B6847aD5a4E97C6674f10ffc750; // IMD's burn, its BurnExecutor: where LARP's $IMD goes
    address constant ARTIST = 0x35dA9C0303507ddf708E87F2568EdDf12c47a059;
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant ORACLE_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    address constant PAIR_HOOK = 0x667f4621030aCfAfb1bD0B64d33610A8567f2A44;
    address constant LAUNCHER = 0xfF03410d0Fe5fa8f7F59F743de35E333D9857120;
    address constant WORKER_FRENS = 0x6900d042460d6bdbe68CE994F4dE36706797CCd4;
    address constant TREASURY = 0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F;
    address constant FULL_JEETER = 0x2A89C680d9d96A51f8dD52bD20AabC4A320E7dCA;
    address constant HALF_JEETER = 0x7d5E92853599B792cCb65A6E9B1fC26c663F6563;

    LARPBurner burner;
    LARP larp;
    IMDNames names;
    LARPLinks links;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        burner = new LARPBurner(
            POOL_MANAGER,
            IMD,
            10_000,
            60,
            POOL4_HOOK,
            10_000,
            200,
            TREASURY,
            0,
            60,
            PAIR_HOOK,
            vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2)
        );
        larp = new LARP(IDENTITY);
        names = new IMDNames(IDENTITY, larp, address(burner), ARTIST, INTAKE, ORACLE_SIGNER);
        links = new LARPLinks(IDENTITY, LAUNCHER, larp, names, address(burner));
    }

    modifier forked() {
        if (address(larp) == address(0)) vm.skip(true);
        _;
    }

    function _label(string memory s) internal pure returns (bytes32 label) {
        assembly {
            label := mload(add(s, 0x20))
        }
        uint256 n = bytes(s).length;
        if (n < 32) label &= ~bytes32(type(uint256).max >> (8 * n));
    }

    function test_AnIdentityWearsAWorkerFren() public forked {
        vm.prank(TREASURY);
        larp.setFace(806, WORKER_FRENS, 1);
        (,,, bool live) = larp.faceOf(806);
        assertTrue(live);
        assertEq(larp.faceURI(806), IERC721Like(WORKER_FRENS).tokenURI(1), "the fren's own on-chain art");
        assertEq(larp.avatarOf(806), "eip155:1/erc721:0x6900d042460d6bdbe68ce994f4de36706797ccd4/1");

        vm.prank(TREASURY);
        larp.equip(806, 1, WORKER_FRENS, 2, ILARP.Kind.ERC721);
        assertEq(larp.itemURI(806, 1), IERC721Like(WORKER_FRENS).tokenURI(2));

        address buyer = address(0xb0B0000000000000000000000000000000000B0B);
        vm.prank(TREASURY);
        IERC721Like(IDENTITY).transferFrom(TREASURY, buyer, 806);
        (,,, live) = larp.faceOf(806);
        assertFalse(live);
        assertEq(larp.faceURI(806), IERC721Like(IDENTITY).tokenURI(806));
    }

    event Bought(uint256 eth, uint256 imd, uint8 route);

    function test_ANameBuysRealIMDOnPool4AndBurnsIt() public forked {
        uint256 before = IERC20Like(IMD).balanceOf(IMD_BURN);
        uint256 supply6900 = IERC20Like(TREASURY).totalSupply();
        uint256 pairFees = IERC20Like(TREASURY).balanceOf(PAIR_HOOK);
        vm.deal(TREASURY, 1 ether);
        vm.expectEmit(true, false, true, false, address(burner));
        emit Bought(0.00069 ether, 0, 0); // route 0: POOL4
        vm.prank(TREASURY);
        uint256 id = names.register{value: 0.00069 ether}(_label("imd6900"), TREASURY, 0);
        uint256 burned = IERC20Like(IMD).balanceOf(IMD_BURN) - before;
        uint256 burned6900 = supply6900 - IERC20Like(TREASURY).totalSupply();
        emit log_named_decimal_uint("IMD bought on POOL4 and sent to 0x..dEaD (93.1%)", burned, 18);
        emit log_named_decimal_uint(
            "IMD6900 bought with the other 6.9% on the IMD6900/IMD pool, burned", burned6900, 18
        );
        assertGt(burned, 0);
        assertGt(burned6900, 0, "buying pressure on IMD6900, then a real burn");
        assertGt(IERC20Like(TREASURY).balanceOf(PAIR_HOOK), pairFees, "the pair hook kept its 6.9% fee for liquidity");
        assertEq(address(burner).balance, 0);
        assertEq(names.ownerOf(id), TREASURY);

        vm.prank(TREASURY);
        names.link(id, 806, 0);
        assertEq(names.nameOf(806), "imd6900.imd");
        (bool exists, address owner, uint256 imdId, bool linked) = names.resolveName("imd6900.imd");
        assertTrue(exists && linked);
        assertEq(owner, TREASURY);
        assertEq(imdId, 806);
        assertGt(bytes(names.tokenURI(id)).length, 1_000, "the built-in card renders");
    }

    /// @dev If POOL4 can't take a fee, the real hookless pool does (here: a burner pointed at a POOL4 that doesn't
    /// exist).
    function test_TheHooklessPoolTakesWhatPool4Cant() public forked {
        LARPBurner b = new LARPBurner(
            POOL_MANAGER,
            IMD,
            10_000,
            60,
            address(0x1234),
            10_000,
            200,
            TREASURY,
            0,
            60,
            PAIR_HOOK,
            vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2)
        );
        uint256 before = IERC20Like(IMD).balanceOf(IMD_BURN);
        vm.expectEmit(true, false, true, false, address(b));
        emit Bought(0.05 ether, 0, 1); // route 1
        uint256 got = b.burn{value: 0.05 ether}(0);
        emit log_named_decimal_uint("IMD bought on the hookless pool for 0.05 ETH", got, 18);
        assertGt(got, 0);
        assertEq(IERC20Like(IMD).balanceOf(IMD_BURN) - before, got - got * 690 / 10_000, "93.1% to 0x..dEaD");
    }

    /// @dev Paying in real $IMD at the two real pools' quote.
    function test_ANamePaidInRealImd() public forked {
        address payer = address(0x1dd0000000000000000000000000000000001dD0);
        uint256 due = burner.quoteImd(0.00069 ether);
        emit log_named_decimal_uint("a 5+ letter name in IMD now", due, 18);
        deal(IMD, payer, due);
        uint256 supply6900 = IERC20Like(TREASURY).totalSupply();
        vm.startPrank(payer);
        IERC20Like(IMD).approve(address(names), due);
        uint256 id = names.registerWithImd(_label("paid-in-imd"), payer, due);
        vm.stopPrank();
        assertEq(names.ownerOf(id), payer);
        assertEq(IERC20Like(IMD).balanceOf(payer), 0);
        assertLt(IERC20Like(TREASURY).totalSupply(), supply6900);
    }

    function test_ACrewBuysAndBurnsRealIMD() public forked {
        uint256 before = IERC20Like(IMD).balanceOf(IMD_BURN);
        vm.deal(TREASURY, 1 ether);
        vm.prank(TREASURY);
        links.foundCrew{value: 0.00069 ether}(806, _label("imd6900-frens"), true, 0);
        assertGt(IERC20Like(IMD).balanceOf(IMD_BURN), before);
        assertEq(links.crewOf(806), 1);
    }

    /// @dev A secondary sale of a name: the buyer's first link pays the toll, burned on POOL4.
    function test_ANameChangesHandsAndBurns() public forked {
        vm.deal(TREASURY, 1 ether);
        vm.prank(TREASURY);
        uint256 id = names.register{value: 0.00069 ether}(_label("imd6900"), TREASURY, 0);
        address buyer = address(0xb0B0000000000000000000000000000000000B0B);
        vm.startPrank(TREASURY);
        names.transferFrom(TREASURY, buyer, id);
        IERC721Like(IDENTITY).transferFrom(TREASURY, buyer, 806);
        vm.stopPrank();
        assertEq(names.tollOf(id), 0.00069 ether);
        uint256 before = IERC20Like(IMD).balanceOf(IMD_BURN);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        names.link{value: 0.00069 ether}(id, 806, 0);
        assertGt(IERC20Like(IMD).balanceOf(IMD_BURN), before, "the toll was burned");
        assertEq(names.nameOf(806), "imd6900.imd");
    }

    /// @dev The treasury connects an agent key, which then runs #806 without the treasury sending anything else.
    function test_AnAgentRunsTheTreasurysIdentity() public forked {
        address agent = address(0xA9e47000000000000000000000000000000000a9);
        vm.prank(TREASURY);
        larp.setAgent(806, agent);
        vm.startPrank(agent);
        larp.setFace(806, WORKER_FRENS, 3); // the treasury's fren
        links.fren(806, 1533);
        vm.stopPrank();
        (address holder,,, bool live) = larp.faceOf(806);
        assertEq(holder, TREASURY);
        assertTrue(live);
        assertTrue(links.asked(806, 1533));
    }

    /// @dev A price proposal through IMD's real Intake: the oracle is paid, then the verdict (signed here by a stand-in
    /// for IMD's oracle key, which only IMD holds) is delivered as the Intake delivers it, and anyone executes it.
    function test_APriceProposalThroughIMDsRealIntake() public forked {
        uint256 key = 0x5EC0;
        IMDNames n = new IMDNames(IDENTITY, larp, address(burner), ARTIST, INTAKE, vm.addr(key));
        address proposer = address(0x9909000000000000000000000000000000009909);
        address payTo = 0x4e0fA57Bde726079356537E2F34d671E9F41ADbc;
        deal(IMD, proposer, 1 ether);
        uint256 paid = IERC20Like(IMD).balanceOf(payTo);
        vm.startPrank(proposer);
        IERC20Like(IMD).approve(address(n), 0.5 ether);
        bytes32 id =
            n.propose(SwarmPrices.Prices(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether, 1380), 0.5 ether);
        vm.stopPrank();
        assertEq(IERC20Like(IMD).balanceOf(payTo) - paid, 0.5 ether, "IMD's oracle was paid through its Intake");

        // signed for the request the real Intake gave the proposal: a verdict is bound to its request (L-15)
        Attestation memory a = Attestation(
            id,
            1,
            keccak256("q"),
            0,
            abi.encode(true),
            0,
            1,
            2,
            bytes32(0),
            bytes32(0),
            9,
            7,
            9,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days)
        );
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
                uint256(1),
                address(n)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        vm.prank(INTAKE);
        n.onVerdict(id, a, abi.encodePacked(r, s, v));

        vm.prank(address(0xA11));
        n.execute(id);
        assertEq(n.priceOf(_label("frens")), 0.0005 ether);
        assertEq(n.crewPrice(), 0.0005 ether);
    }

    /// @dev Proves every allocation in the fixtures with its real proof against the real distributor.
    function _proveAll() internal {
        string memory json = vm.readFile("test/fixtures/allocs.json");
        for (uint256 i;; ++i) {
            string memory at = string.concat(".allocs[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, at)) break;
            links.proveAlloc(
                uint64(vm.parseJsonUint(json, string.concat(at, ".launch"))),
                vm.parseJsonUint(json, string.concat(at, ".round")),
                vm.parseJsonAddress(json, string.concat(at, ".wallet")),
                vm.parseUint(vm.parseJsonString(json, string.concat(at, ".amount"))),
                vm.parseJsonBytes32Array(json, string.concat(at, ".proof"))
            );
        }
    }

    function test_TheRealJeetBoard() public forked {
        _proveAll();

        // claimed both its airdrops (IMD #739, ZTO #737) and sold every token
        (uint256 level, uint256 points) = links.jeetOf(FULL_JEETER);
        assertEq(level, 2);
        assertEq(points, 20_000);
        assertEq(links.titleOf(links.tierOf(level, points)), "Jeet Lord");

        // sold half of its ZTO (49.9999%: basis points round down)
        (level, points) = links.jeetOf(HALF_JEETER);
        assertEq(level, 1);
        assertEq(points, 4_999);
        assertEq(links.titleOf(links.tierOf(level, points)), "Paper Hands");

        // the IMD6900 treasury holds what it claimed and never claimed VERDICT
        (address holder, uint256 lvl, uint256 pts, uint8 tier) = links.rankOf(806);
        assertEq(holder, TREASURY);
        assertEq(lvl, 4);
        assertEq(pts, 0);
        assertEq(links.titleOf(tier), "Diamond Hands");
        LARPLinks.LaunchJeet memory verdict = links.launchJeet(TREASURY, 3);
        assertEq(verdict.number, 1352);
        assertEq(verdict.claimed, 0, "VERDICT is unclaimed");
    }

    function test_RealProofsRefuseTampering() public forked {
        string memory json = vm.readFile("test/fixtures/allocs.json");
        bytes32[] memory proof = vm.parseJsonBytes32Array(json, ".allocs[1].proof");
        uint256 amount = vm.parseUint(vm.parseJsonString(json, ".allocs[1].amount"));
        vm.expectRevert(LARPLinks.BadProof.selector);
        links.proveAlloc(737, 0, FULL_JEETER, amount + 1, proof);
        vm.expectRevert(LARPLinks.BadProof.selector);
        links.proveAlloc(739, 0, FULL_JEETER, amount, proof);
        vm.expectRevert(LARPLinks.UnknownLaunch.selector);
        links.proveAlloc(1341, 0, FULL_JEETER, amount, proof); // a hook launch: not this launcher's
    }

    function test_TheTreasurysCard() public forked {
        _proveAll();
        vm.deal(TREASURY, 1 ether);
        vm.startPrank(TREASURY);
        uint256 id = names.register{value: 0.00069 ether}(_label("imd6900"), TREASURY, 0);
        names.link(id, 806, 0);
        larp.setFace(806, WORKER_FRENS, 1);
        links.foundCrew{value: 0.00069 ether}(806, _label("imd6900-frens"), true, 0);
        links.fren(806, 1533);
        links.fren(1533, 806);
        vm.stopPrank();

        LARPLinks.Card memory c = links.cardOf(806);
        assertEq(c.holder, TREASURY);
        assertEq(c.name, "imd6900.imd");
        assertEq(c.faceCollection, WORKER_FRENS);
        assertEq(c.faceTokenId, 1);
        assertTrue(c.faceLive);
        assertEq(c.crewName, _label("imd6900-frens"));
        assertTrue(c.captain);
        assertEq(c.frens, 1);
        assertEq(c.level, 4);
        assertEq(c.title, "Diamond Hands");
    }
}
