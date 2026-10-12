// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {LARPBurner} from "../src/LARPBurner.sol";
import {LARP} from "../src/LARP.sol";
import {IMDNames} from "../src/IMDNames.sol";
import {LARPLinks} from "../src/LARPLinks.sol";
import {LARPPlan} from "../src/place/LARPPlan.sol";
import {PlaceLARP, PlaceLinks} from "../src/place/PlaceLARP.sol";

/// @dev What IMD's deployer does with the launch: the two contracts, in order, in one transaction
contract ImdStyleDeployer {
    PlaceLARP public placeLARP;
    PlaceLinks public placeLinks;

    function launch() external {
        // Use real CREATE so test linking cannot replace `new` with a zero-gas deployCode cheatcode.
        placeLARP = PlaceLARP(_create(type(PlaceLARP).creationCode));
        placeLinks = PlaceLinks(_create(abi.encodePacked(type(PlaceLinks).creationCode, abi.encode(placeLARP))));
    }

    function _create(bytes memory code) internal returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
        require(deployed != address(0), "placement failed");
    }
}

/// @dev CreateX's deployCreate3 for a salt no sender owns, as CreateX does it (checked against the real one on a fork:
///      PlacementForkTest): the guarded salt keccak256(abi.encode(salt)), the CREATE3 proxy, its first CREATE
contract CreateXStandIn {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address newContract) {
        bytes32 g = keccak256(abi.encode(salt));
        bytes memory proxyCode = hex"67363d3d37363d34f03d5260086018f3";
        address proxy;
        assembly ("memory-safe") {
            proxy := create2(0, add(proxyCode, 32), mload(proxyCode), g)
        }
        require(proxy != address(0), "proxy taken");
        (bool ok,) = proxy.call(initCode);
        require(ok, "init failed");
        newContract = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", proxy, hex"01")))));
        require(newContract.code.length != 0, "nothing created");
    }
}

/// @dev Something anyone could put at a planned address by using its salt first
contract Squatter {
    function hello() external pure returns (uint256) {
        return 69;
    }
}

abstract contract PlacementBase is Test {
    function _launch(address imdDeployer) internal returns (PlaceLARP p, PlaceLinks q) {
        vm.prank(imdDeployer);
        ImdStyleDeployer d = new ImdStyleDeployer();
        d.launch();
        (p, q) = (d.placeLARP(), d.placeLinks());
    }

    /// @dev CreateX's CREATE3 address for a salt no sender owns
    function _viaCreateX(bytes32 salt) internal pure returns (address) {
        bytes32 g = keccak256(abi.encode(salt));
        address proxy = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), LARPPlan.CREATEX, g, keccak256(hex"67363d3d37363d34f03d5260086018f3")
                        )
                    )
                )
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", proxy, hex"01")))));
    }

    /// @dev Every contract knows the others it was made with: the burner IMD Names (the share), IMD Names the
    ///      registry and the burner, the links all three
    function _wired(PlaceLARP p, PlaceLinks q) internal view {
        LARPBurner b = LARPBurner(payable(p.burner()));
        assertEq(address(b.POOL_MANAGER()), LARPPlan.POOL_MANAGER);
        assertEq(b.IMD(), LARPPlan.IMD);
        assertEq(b.POOL4_FEE(), 10_000);
        assertEq(int256(b.POOL4_SPACING()), 60);
        assertEq(b.POOL4_HOOK(), LARPPlan.POOL4_HOOK);
        assertEq(b.BACKUP_FEE(), 10_000);
        assertEq(int256(b.BACKUP_SPACING()), 200);
        assertEq(b.IMD6900(), LARPPlan.IMD6900);
        assertEq(b.PAIR_FEE(), 0);
        assertEq(int256(b.PAIR_SPACING()), 60);
        assertEq(b.PAIR_HOOK(), LARPPlan.PAIR_HOOK);
        assertEq(b.NAMES(), p.names(), "the burner reads the share from IMD Names");
        assertEq(b.IMD_BURN(), 0xe29386719C155B6847aD5a4E97C6674f10ffc750, "IMD's burn");
        assertEq(b.MAX_BURN(), 0.1 ether);
        assertEq(b.MAX_SHARE_BPS(), 10_000);
        assertEq(b.POOL_SHARE_BPS(), 690);
        assertEq(LARP(p.larp()).IDENTITY(), LARPPlan.IDENTITY);
        IMDNames n = IMDNames(p.names());
        assertEq(n.IDENTITY(), LARPPlan.IDENTITY);
        assertEq(address(n.LARP()), p.larp());
        assertEq(n.BURNER(), p.burner());
        assertEq(n.artist(), LARPPlan.ARTIST);
        assertEq(n.INTAKE(), LARPPlan.INTAKE);
        assertEq(n.ORACLE_SIGNER(), LARPPlan.ORACLE_SIGNER);
        assertEq(n.imd6900ShareBps(), 690, "6.9% to start");
        assertEq(n.MAX_SHARE(), 10_000);
        assertEq(b.shareBps(), 690);
        LARPLinks l = LARPLinks(q.links());
        assertEq(l.IDENTITY(), LARPPlan.IDENTITY);
        assertEq(l.LAUNCHER(), LARPPlan.LAUNCHER);
        assertEq(address(l.LARP()), p.larp());
        assertEq(address(l.NAMES()), p.names());
        assertEq(l.BURNER(), p.burner());
    }
}

/// @title The launch places LARP's four contracts at 0x6900… by CREATE3 (src/place, script/place/gen.py)
contract PlacementTest is PlacementBase {
    uint256 constant TX_GAS_CAP = 1 << 24; // EIP-7825
    uint256 constant INITCODE_CAP = 49_152; // EIP-3860
    uint256 constant MARGIN = 1_000_000;

    function _withCreateX() internal {
        vm.etch(LARPPlan.CREATEX, address(new CreateXStandIn()).code);
    }

    /* ── the plan ───────────────────────────────────────────────── */

    function test_PlanFollowsFromTheSalts() public pure {
        assertEq(_viaCreateX(LARPPlan.BURNER_SALT), LARPPlan.BURNER_AT, "burner");
        assertEq(_viaCreateX(LARPPlan.LARP_SALT), LARPPlan.LARP_AT, "registry");
        assertEq(_viaCreateX(LARPPlan.NAMES_SALT), LARPPlan.NAMES_AT, "names");
        assertEq(_viaCreateX(LARPPlan.LINKS_SALT), LARPPlan.LINKS_AT, "links");
        address[4] memory at = [LARPPlan.BURNER_AT, LARPPlan.LARP_AT, LARPPlan.NAMES_AT, LARPPlan.LINKS_AT];
        bytes32[4] memory salts = [LARPPlan.BURNER_SALT, LARPPlan.LARP_SALT, LARPPlan.NAMES_SALT, LARPPlan.LINKS_SALT];
        for (uint256 i; i < 4; ++i) {
            assertEq(uint160(at[i]) >> 144, 0x6900, "starts 0x6900");
            assertTrue(bytes20(salts[i]) != bytes20(0), "a salt no sender owns: its first 20 bytes aren't zero");
            assertEq(uint8(salts[i][20]), 0, "byte 21 is 0");
            for (uint256 k; k < 32; ++k) {
                bytes1 c = salts[i][k];
                assertTrue(c != 0xf2 && c != 0xf4 && c != 0xff, "a salt the admission scan can't misread");
            }
        }
    }

    function test_ArgumentsAsTheReadmeSays() public pure {
        assertEq(LARPPlan.POOL4_FEE, 10_000);
        assertEq(LARPPlan.POOL4_SPACING, 60);
        assertEq(LARPPlan.BACKUP_FEE, 10_000);
        assertEq(LARPPlan.BACKUP_SPACING, 200);
        assertEq(LARPPlan.PAIR_FEE, 0);
        assertEq(LARPPlan.PAIR_SPACING, 60);
        assertEq(LARPPlan.CREATEX, 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);
    }

    /* ── the launch ─────────────────────────────────────────────── */

    function test_LandsWhereThePlanSays() public {
        _withCreateX();
        (PlaceLARP p, PlaceLinks q) = _launch(makeAddr("IMD's deployer"));
        assertEq(p.burner(), LARPPlan.BURNER_AT, "burner");
        assertEq(p.larp(), LARPPlan.LARP_AT, "registry");
        assertEq(p.names(), LARPPlan.NAMES_AT, "names");
        assertEq(q.links(), LARPPlan.LINKS_AT, "links");
        _wired(p, q);
    }

    function test_SameAddressesWhoeverRunsIt() public {
        _withCreateX();
        uint256 s = vm.snapshotState();
        (PlaceLARP p1, PlaceLinks q1) = _launch(makeAddr("one deployer"));
        address[4] memory first = [p1.burner(), p1.larp(), p1.names(), q1.links()];
        vm.revertToState(s);
        (PlaceLARP p2, PlaceLinks q2) = _launch(makeAddr("another"));
        assertEq(p2.burner(), first[0]);
        assertEq(p2.larp(), first[1]);
        assertEq(p2.names(), first[2]);
        assertEq(q2.links(), first[3]);
    }

    /// @dev CREATE3 doesn't bind code to an address: what someone put at a planned address first is never taken. That
    ///      contract goes to the placement's own CREATE3 address instead, and the others still find it.
    function test_ASaltUsedFirstIsNeverTaken() public {
        _withCreateX();
        CreateXStandIn(LARPPlan.CREATEX).deployCreate3(LARPPlan.NAMES_SALT, type(Squatter).creationCode);
        CreateXStandIn(LARPPlan.CREATEX).deployCreate3(LARPPlan.LINKS_SALT, type(Squatter).creationCode);
        assertGt(LARPPlan.NAMES_AT.code.length, 0, "squatted");
        (PlaceLARP p, PlaceLinks q) = _launch(makeAddr("IMD's deployer"));
        assertEq(p.burner(), LARPPlan.BURNER_AT, "the burner's salt was free");
        assertEq(p.larp(), LARPPlan.LARP_AT);
        assertTrue(p.names() != LARPPlan.NAMES_AT, "not the squatter");
        assertTrue(q.links() != LARPPlan.LINKS_AT, "not the squatter");
        _wired(p, q);
    }

    function test_DeploysOnAFreshChain() public {
        assertEq(LARPPlan.CREATEX.code.length, 0, "no CreateX here: the placements create the four themselves");
        (PlaceLARP p, PlaceLinks q) = _launch(makeAddr("IMD's deployer"));
        assertTrue(p.burner() != LARPPlan.BURNER_AT, "other addresses");
        assertGt(p.burner().code.length, 0);
        assertGt(q.links().code.length, 0);
        _wired(p, q);
    }

    function test_FitsOneTransaction() public {
        _withCreateX();
        _assertFitsOneTransaction();
    }

    function test_FreshChainFitsOneTransaction() public {
        assertEq(LARPPlan.CREATEX.code.length, 0);
        _assertFitsOneTransaction();
    }

    function _assertFitsOneTransaction() internal {
        bytes[] memory codes = new bytes[](2);
        codes[0] = type(PlaceLARP).creationCode;
        codes[1] = abi.encodePacked(type(PlaceLinks).creationCode, abi.encode(address(1)));
        for (uint256 i; i < codes.length; ++i) {
            assertLt(codes[i].length, INITCODE_CAP, "each placement under EIP-3860");
        }
        ImdStyleDeployer d = new ImdStyleDeployer();
        uint256 g = gasleft();
        d.launch();
        uint256 all = _launchTx(g - gasleft(), codes);
        emit log_named_uint("the launch: gas, all in", all);
        emit log_named_uint("PlaceLARP initcode bytes", codes[0].length);
        emit log_named_uint("PlaceLinks initcode bytes", codes[1].length);
        assertLt(all + MARGIN, TX_GAS_CAP, "one transaction under EIP-7825, with margin");
    }

    /// @dev A launch transaction's gas: its creations, plus 21,000, its calldata and the launcher's overhead
    function _launchTx(uint256 creations, bytes[] memory codes) internal pure returns (uint256) {
        uint256 bytes_;
        uint256 tokens;
        for (uint256 i; i < codes.length; ++i) {
            bytes_ += codes[i].length;
            for (uint256 k; k < codes[i].length; ++k) {
                tokens += codes[i][k] == 0 ? 1 : 4;
            }
        }
        uint256 standard = 21_000 + 4 * tokens + creations + 300_000 + 7 * bytes_; // the launcher: 300,000 + 7 a byte
        uint256 floor = 21_000 + 10 * tokens; // EIP-7623
        return standard > floor ? standard : floor;
    }

    function test_PassesTheAdmissionScan() public {
        _withCreateX();
        (PlaceLARP p, PlaceLinks q) = _launch(makeAddr("IMD's deployer"));
        _scan(type(PlaceLARP).creationCode, "PlaceLARP creation code");
        _scan(abi.encodePacked(type(PlaceLinks).creationCode, abi.encode(address(p))), "PlaceLinks creation code");
        _scan(address(p).code, "PlaceLARP");
        _scan(address(q).code, "PlaceLinks");
        _scan(type(LARPBurner).creationCode, "LARPBurner creation code");
        _scan(type(LARP).creationCode, "LARP creation code");
        _scan(type(IMDNames).creationCode, "IMDNames creation code");
        _scan(type(LARPLinks).creationCode, "LARPLinks creation code");
        _scan(p.burner().code, "LARPBurner");
        _scan(p.larp().code, "LARP");
        _scan(p.names().code, "IMDNames");
        _scan(q.links().code, "LARPLinks");
    }

    /// @dev IMD reads code as instructions (PUSH data skipped) and refuses CALLCODE, DELEGATECALL and SELFDESTRUCT
    function _scan(bytes memory code, string memory what) internal pure {
        uint256 hits;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0xf2 || op == 0xf4 || op == 0xff) ++hits;
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
        }
        assertEq(hits, 0, what);
    }
}

/// @title The launch on an Ethereum fork: the real CreateX, the real pools, IMD's real burn; runs when MAINNET_RPC_URL
/// is set
contract PlacementForkTest is PlacementBase {
    address constant IMD_BURN = 0xe29386719C155B6847aD5a4E97C6674f10ffc750;
    PlaceLARP p;
    PlaceLinks q;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        (p, q) = _launch(makeAddr("IMD's deployer"));
    }

    function test_fork_LandsAt6900ThroughTheRealCreateX() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        assertGt(LARPPlan.CREATEX.code.length, 0, "Ethereum has CreateX");
        assertEq(p.burner(), LARPPlan.BURNER_AT);
        assertEq(p.larp(), LARPPlan.LARP_AT);
        assertEq(p.names(), LARPPlan.NAMES_AT);
        assertEq(q.links(), LARPPlan.LINKS_AT);
        _wired(p, q);
    }

    /// @dev A name's fee buys $IMD on POOL4: 6.9% of it buys IMD6900 on its $IMD pool and burns it, the rest reaches
    ///      IMD's burn (its BurnExecutor), and nothing goes to 0x..dEaD
    function test_fork_ANameBurnsTheCanonicalWay() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        IMDNames n = IMDNames(p.names());
        bytes32 label = bytes32("larp-launch");
        uint256 price = n.priceOf(label);
        address who = makeAddr("a fren");
        vm.deal(who, 1 ether);
        uint256 atBurn = _bal(LARPPlan.IMD, IMD_BURN);
        uint256 atDead = _bal(LARPPlan.IMD, 0x000000000000000000000000000000000000dEaD);
        uint256 supply6900 = _supply(LARPPlan.IMD6900);
        vm.recordLogs();
        vm.prank(who);
        uint256 id = n.register{value: price, gas: 5_000_000}(label, who, 1);
        assertEq(n.ownerOf(id), who);
        uint256 toBurn = _bal(LARPPlan.IMD, IMD_BURN) - atBurn;
        assertGt(toBurn, 0, "$IMD reached IMD's burn");
        assertEq(_bal(LARPPlan.IMD, 0x000000000000000000000000000000000000dEaD), atDead, "nothing to 0x..dEaD");
        assertLt(_supply(LARPPlan.IMD6900), supply6900, "the share bought IMD6900 and burned it");
        // the Burned event: imdBurned (to IMD's burn) and imdSpent (on IMD6900) split the $IMD 93.1 / 6.9
        (uint256 imdBurned, uint256 imdSpent) = _burned(LARPPlan.BURNER_AT);
        assertEq(imdBurned, toBurn);
        assertApproxEqAbs(imdSpent, (imdBurned + imdSpent) * 690 / 10_000, 1);
    }

    function _burned(address burner) internal returns (uint256 burned, uint256 spent) {
        bytes32 sig = keccak256("Burned(uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == burner && logs[i].topics[0] == sig) {
                (burned, spent,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
    }

    function _bal(address token, address who) internal view returns (uint256) {
        (bool ok, bytes memory r) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        require(ok);
        return abi.decode(r, (uint256));
    }

    function _supply(address token) internal view returns (uint256) {
        (bool ok, bytes memory r) = token.staticcall(abi.encodeWithSignature("totalSupply()"));
        require(ok);
        return abi.decode(r, (uint256));
    }
}
