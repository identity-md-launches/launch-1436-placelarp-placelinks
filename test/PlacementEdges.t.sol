// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PlacementBase, ImdStyleDeployer, CreateXStandIn, Squatter} from "./Placement.t.sol";
import {LARPPlan} from "../src/place/LARPPlan.sol";
import {PlaceLARP, PlaceLinks} from "../src/place/PlaceLARP.sol";

contract PlacementEdgesTest is PlacementBase {
    function setUp() public {
        vm.etch(LARPPlan.CREATEX, address(new CreateXStandIn()).code);
    }

    function _salts() internal pure returns (bytes32[4] memory) {
        return [LARPPlan.BURNER_SALT, LARPPlan.LARP_SALT, LARPPlan.NAMES_SALT, LARPPlan.LINKS_SALT];
    }

    function _planned() internal pure returns (address[4] memory) {
        return [LARPPlan.BURNER_AT, LARPPlan.LARP_AT, LARPPlan.NAMES_AT, LARPPlan.LINKS_AT];
    }

    function _proxy(address deployer, bytes32 salt) internal pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(hex"67363d3d37363d34f03d5260086018f3"))
                    )
                )
            )
        );
    }

    function _local(address placement, bytes32 salt) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", _proxy(placement, salt), hex"01")))));
    }

    function _results(PlaceLARP p, PlaceLinks q) internal view returns (address[4] memory) {
        return [p.burner(), p.larp(), p.names(), q.links()];
    }

    function _checkOccupancy(uint8 mask, bool proxyOnly) internal {
        bytes32[4] memory salts = _salts();
        address[4] memory planned = _planned();
        bytes memory squatterCode = address(new Squatter()).code;
        for (uint256 i; i < 4; ++i) {
            if (mask & (1 << i) == 0) continue;
            address occupied = proxyOnly ? _proxy(LARPPlan.CREATEX, keccak256(abi.encode(salts[i]))) : planned[i];
            vm.etch(occupied, squatterCode);
        }
        (PlaceLARP p, PlaceLinks q) = _launch(makeAddr("placement edge deployer"));
        _wired(p, q);
        address[4] memory actual = _results(p, q);
        for (uint256 i; i < 4; ++i) {
            assertGt(actual[i].code.length, 0);
            assertLe(actual[i].code.length, 24_576);
            if (mask & (1 << i) == 0) {
                assertEq(actual[i], planned[i], "a free salt still uses CreateX");
            } else {
                assertEq(actual[i], _local(i == 3 ? address(q) : address(p), salts[i]));
                assertTrue(actual[i] != planned[i]);
                address occupied = proxyOnly ? _proxy(LARPPlan.CREATEX, keccak256(abi.encode(salts[i]))) : planned[i];
                assertEq(occupied.code, squatterCode, "existing code is never overwritten or adopted");
                assertEq(Squatter(occupied).hello(), 69);
                if (proxyOnly) assertEq(planned[i].code.length, 0, "an occupied proxy excludes an empty destination");
            }
        }
    }

    function test_AllSixteenDestinationOccupancyCombinations() public {
        for (uint8 mask; mask < 16; ++mask) {
            uint256 snapshot = vm.snapshotState();
            _checkOccupancy(mask, false);
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function test_AllSixteenProxyOnlyOccupancyCombinations() public {
        for (uint8 mask; mask < 16; ++mask) {
            uint256 snapshot = vm.snapshotState();
            _checkOccupancy(mask, true);
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_MixedSquattersNeverChangeTheWiring(uint8 destinations, uint8 proxies) public {
        bytes32[4] memory salts = _salts();
        address[4] memory planned = _planned();
        bytes memory code = address(new Squatter()).code;
        for (uint256 i; i < 4; ++i) {
            if (destinations & (1 << i) != 0) vm.etch(planned[i], code);
            if (proxies & (1 << i) != 0) vm.etch(_proxy(LARPPlan.CREATEX, keccak256(abi.encode(salts[i]))), code);
        }
        (PlaceLARP p, PlaceLinks q) = _launch(makeAddr("mixed occupancy deployer"));
        _wired(p, q);
        address[4] memory actual = _results(p, q);
        for (uint256 i; i < 4; ++i) {
            bool occupied = (destinations | proxies) & (1 << i) != 0;
            assertEq(actual[i], occupied ? _local(i == 3 ? address(q) : address(p), salts[i]) : planned[i]);
            if (destinations & (1 << i) != 0) assertEq(planned[i].code, code);
            if (proxies & (1 << i) != 0) {
                assertEq(_proxy(LARPPlan.CREATEX, keccak256(abi.encode(salts[i]))).code, code);
            }
        }
    }

    function test_SecondLaunchCreatesItsOwnFourContracts() public {
        (PlaceLARP first, PlaceLinks firstLinks) = _launch(makeAddr("first deployer"));
        address[4] memory before = _results(first, firstLinks);
        bytes32[4] memory hashes;
        for (uint256 i; i < 4; ++i) {
            hashes[i] = before[i].codehash;
        }
        (PlaceLARP second, PlaceLinks secondLinks) = _launch(makeAddr("second deployer"));
        _wired(first, firstLinks);
        _wired(second, secondLinks);
        address[4] memory after_ = _results(second, secondLinks);
        bytes32[4] memory salts = _salts();
        for (uint256 i; i < 4; ++i) {
            assertTrue(after_[i] != before[i]);
            assertEq(before[i].codehash, hashes[i]);
            assertEq(after_[i], _local(i == 3 ? address(secondLinks) : address(second), salts[i]));
        }
    }

    /// @dev Fault injection is limited to CreateX's return value. Actual CREATEs
    /// happen in one external launch() frame, so a late failure must undo earlier
    /// placements, CREATE3 proxies and the factory's own nonce and handoff.
    function test_EveryCreateXFailureRollsBackTheEntireLaunchAndCanRetry() public {
        bytes32[4] memory salts = _salts();
        address[4] memory planned = _planned();
        for (uint256 failAt; failAt < 4; ++failAt) {
            uint256 snapshot = vm.snapshotState();
            ImdStyleDeployer deployer = new ImdStyleDeployer();
            uint64 nonce = vm.getNonce(address(deployer));
            bytes memory input = abi.encodePacked(CreateXStandIn.deployCreate3.selector, salts[failAt]);
            vm.mockCall(LARPPlan.CREATEX, input, abi.encode(makeAddr("incorrect CreateX result")));
            vm.expectRevert(bytes("placement failed"));
            deployer.launch();
            assertEq(address(deployer.placeLARP()), address(0));
            assertEq(address(deployer.placeLinks()), address(0));
            assertEq(vm.getNonce(address(deployer)), nonce);
            for (uint256 i; i < 4; ++i) {
                assertEq(planned[i].code.length, 0, "no partial application deployment");
                assertEq(_proxy(LARPPlan.CREATEX, keccak256(abi.encode(salts[i]))).code.length, 0);
            }
            vm.clearMockedCalls();
            deployer.launch();
            _wired(deployer.placeLARP(), deployer.placeLinks());
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function test_CreateXReturningTheRightAddressWithoutCodeIsRefused() public {
        vm.mockCall(
            LARPPlan.CREATEX,
            abi.encodePacked(CreateXStandIn.deployCreate3.selector, LARPPlan.BURNER_SALT),
            abi.encode(LARPPlan.BURNER_AT)
        );
        ImdStyleDeployer deployer = new ImdStyleDeployer();
        vm.expectRevert(bytes("placement failed"));
        deployer.launch();
        assertEq(address(deployer.placeLARP()), address(0));
        assertEq(LARPPlan.BURNER_AT.code.length, 0);
    }

    function test_PlaceLinksRequiresTheEarlierPlacement() public {
        // Real CREATE keeps a rejected constructor from terminating the test
        // inside Foundry's linked deployCode cheatcode before the assertions.
        bytes memory code =
            abi.encodePacked(type(PlaceLinks).creationCode, abi.encode(makeAddr("no earlier placement")));
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
        assertEq(deployed, address(0));
        assertEq(LARPPlan.LINKS_AT.code.length, 0);
        assertEq(_proxy(LARPPlan.CREATEX, keccak256(abi.encode(LARPPlan.LINKS_SALT))).code.length, 0);
        (PlaceLARP p, PlaceLinks q) = _launch(makeAddr("correctly ordered deployer"));
        _wired(p, q);
    }

    function test_PlacementAndApplicationsExposeNoOwnerOrUpgradeCalls() public {
        (PlaceLARP p, PlaceLinks q) = _launch(makeAddr("the factory is not an owner"));
        address[6] memory contracts_ = [address(p), address(q), p.burner(), p.larp(), p.names(), q.links()];
        bytes[6] memory calls = [
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("transferOwnership(address)", address(this)),
            abi.encodeWithSignature("upgradeTo(address)", address(this)),
            abi.encodeWithSignature("initialize(address)", address(this)),
            abi.encodeWithSignature("setShareBps(uint256)", 10_000),
            abi.encodeWithSignature("setPrices(uint64,uint64,uint64,uint64)", 1, 1, 1, 1)
        ];
        for (uint256 i; i < contracts_.length; ++i) {
            for (uint256 j; j < calls.length; ++j) {
                (bool ok,) = contracts_[i].call(calls[j]);
                assertFalse(ok, "no post-deployment administration");
            }
        }
        _wired(p, q);
    }
}
