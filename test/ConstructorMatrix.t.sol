// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LARPBurner} from "../src/LARPBurner.sol";
import {LARP} from "../src/LARP.sol";
import {IMDNames} from "../src/IMDNames.sol";
import {LARPLinks} from "../src/LARPLinks.sol";
import {LARPPlan} from "../src/place/LARPPlan.sol";
import {PlaceLARP, PlaceLinks} from "../src/place/PlaceLARP.sol";

/// @dev Use CREATE directly, inspecting its result and returndata, so all cases
/// and postconditions execute even when Foundry links `new` to deployCode.
contract ConstructorMatrixTest is Test {
    function _create(bytes memory code, uint256 value) internal returns (address deployed, bytes memory reason) {
        assembly ("memory-safe") {
            deployed := create(value, add(code, 32), mload(code))
            let size := returndatasize()
            reason := mload(0x40)
            mstore(reason, size)
            returndatacopy(add(reason, 32), 0, size)
            mstore(0x40, and(add(add(reason, 63), size), not(31)))
        }
    }

    function _reject(bytes memory code, bytes4 expected) internal {
        (address deployed, bytes memory reason) = _create(code, 0);
        assertEq(deployed, address(0), "invalid constructor succeeded");
        assertEq(reason, abi.encodeWithSelector(expected), "the specific constructor guard must reject");
    }

    function _burnerCode(address manager, address imd, address imd6900, uint24 p4, uint24 backup, uint24 pair)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            type(LARPBurner).creationCode,
            abi.encode(
                manager,
                imd,
                LARPPlan.POOL4_FEE,
                p4,
                LARPPlan.POOL4_HOOK,
                LARPPlan.BACKUP_FEE,
                backup,
                imd6900,
                LARPPlan.PAIR_FEE,
                pair,
                LARPPlan.PAIR_HOOK,
                LARPPlan.NAMES_AT
            )
        );
    }

    function test_EachRequiredBurnerAddressRejectsZeroIndependently() public {
        _reject(_burnerCode(address(0), LARPPlan.IMD, LARPPlan.IMD6900, 60, 200, 60), LARPBurner.ZeroAddress.selector);
        _reject(
            _burnerCode(LARPPlan.POOL_MANAGER, address(0), LARPPlan.IMD6900, 60, 200, 60),
            LARPBurner.ZeroAddress.selector
        );
        _reject(
            _burnerCode(LARPPlan.POOL_MANAGER, LARPPlan.IMD, address(0), 60, 200, 60), LARPBurner.ZeroAddress.selector
        );
    }

    function test_AllThreeSpacingFieldsRejectValuesAboveV4sMaximum() public {
        uint24[3] memory invalid = [uint24(32_768), uint24(1 << 23), type(uint24).max];
        for (uint256 i; i < invalid.length; ++i) {
            _reject(
                _burnerCode(LARPPlan.POOL_MANAGER, LARPPlan.IMD, LARPPlan.IMD6900, invalid[i], 200, 60),
                LARPBurner.BadSpacing.selector
            );
            _reject(
                _burnerCode(LARPPlan.POOL_MANAGER, LARPPlan.IMD, LARPPlan.IMD6900, 60, invalid[i], 60),
                LARPBurner.BadSpacing.selector
            );
            _reject(
                _burnerCode(LARPPlan.POOL_MANAGER, LARPPlan.IMD, LARPPlan.IMD6900, 60, 200, invalid[i]),
                LARPBurner.BadSpacing.selector
            );
        }
    }

    function test_V4MinimumAndMaximumSpacingsSurviveTheUnsignedArguments() public {
        (address at,) =
            _create(_burnerCode(LARPPlan.POOL_MANAGER, LARPPlan.IMD, LARPPlan.IMD6900, 1, 32_767, 32_767), 0);
        assertGt(at.code.length, 0);
        LARPBurner b = LARPBurner(payable(at));
        assertEq(b.POOL4_SPACING(), 1);
        assertEq(b.BACKUP_SPACING(), 32_767);
        assertEq(b.PAIR_SPACING(), 32_767);
    }

    function test_RegistryRejectsZeroIdentityAndStoresThePlanIdentity() public {
        _reject(abi.encodePacked(type(LARP).creationCode, abi.encode(address(0))), LARP.ZeroIdentity.selector);
        (address at,) = _create(abi.encodePacked(type(LARP).creationCode, abi.encode(LARPPlan.IDENTITY)), 0);
        assertGt(at.code.length, 0);
        assertEq(LARP(at).IDENTITY(), LARPPlan.IDENTITY);
    }

    function test_EachRequiredNamesAddressRejectsZeroIndependently() public {
        address[3] memory required = [LARPPlan.IDENTITY, LARPPlan.LARP_AT, LARPPlan.BURNER_AT];
        for (uint256 i; i < required.length; ++i) {
            address saved = required[i];
            required[i] = address(0);
            _reject(
                abi.encodePacked(
                    type(IMDNames).creationCode,
                    abi.encode(
                        required[0], required[1], required[2], LARPPlan.ARTIST, LARPPlan.INTAKE, LARPPlan.ORACLE_SIGNER
                    )
                ),
                IMDNames.ZeroAddress.selector
            );
            required[i] = saved;
        }
    }

    function test_EachRequiredLinksAddressRejectsZeroIndependently() public {
        address[5] memory required =
            [LARPPlan.IDENTITY, LARPPlan.LAUNCHER, LARPPlan.LARP_AT, LARPPlan.NAMES_AT, LARPPlan.BURNER_AT];
        for (uint256 i; i < required.length; ++i) {
            address saved = required[i];
            required[i] = address(0);
            _reject(
                abi.encodePacked(
                    type(LARPLinks).creationCode,
                    abi.encode(required[0], required[1], required[2], required[3], required[4])
                ),
                LARPLinks.ZeroAddress.selector
            );
            required[i] = saved;
        }
    }

    function test_AllSixConstructorsAreNonpayable() public {
        vm.deal(address(this), 1 ether);
        (address placed,) = _create(type(PlaceLARP).creationCode, 0);
        assertGt(placed.code.length, 0);
        bytes[6] memory codes;
        codes[0] = type(PlaceLARP).creationCode;
        codes[1] = abi.encodePacked(type(PlaceLinks).creationCode, abi.encode(placed));
        codes[2] = _burnerCode(LARPPlan.POOL_MANAGER, LARPPlan.IMD, LARPPlan.IMD6900, 60, 200, 60);
        codes[3] = abi.encodePacked(type(LARP).creationCode, abi.encode(LARPPlan.IDENTITY));
        codes[4] = abi.encodePacked(
            type(IMDNames).creationCode,
            abi.encode(
                LARPPlan.IDENTITY,
                LARPPlan.LARP_AT,
                LARPPlan.BURNER_AT,
                LARPPlan.ARTIST,
                LARPPlan.INTAKE,
                LARPPlan.ORACLE_SIGNER
            )
        );
        codes[5] = abi.encodePacked(
            type(LARPLinks).creationCode,
            abi.encode(LARPPlan.IDENTITY, LARPPlan.LAUNCHER, LARPPlan.LARP_AT, LARPPlan.NAMES_AT, LARPPlan.BURNER_AT)
        );
        uint256 balance = address(this).balance;
        for (uint256 i; i < codes.length; ++i) {
            (address at,) = _create(codes[i], 1);
            assertEq(at, address(0), "constructors must refuse attached ETH");
            assertEq(address(this).balance, balance, "failed CREATE refunds value");
        }
    }
}
