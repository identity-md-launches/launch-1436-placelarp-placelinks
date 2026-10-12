// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LARPBurner} from "../LARPBurner.sol";
import {LARP} from "../LARP.sol";
import {IMDNames} from "../IMDNames.sol";
import {LARPLinks} from "../LARPLinks.sol";
import {ILARP} from "../ILARP.sol";
import {IIMDNames} from "../IIMDNames.sol";
import {LARPPlan} from "./LARPPlan.sol";

/// @dev CreateX (0xba5E…ba5Ed, the same address on every chain it is on)
interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address newContract);
}

/// @dev Places a contract by CREATE3: where it lands depends only on a salt, not on its code. That is what lets the
///      burner and IMD Names each be made knowing the other's address (the burner reads the swarm's IMD6900 share from
///      IMD Names; IMD Names sends its fees to the burner), and what keeps LARPPlan's 0x6900… addresses whoever
///      compiles the launch.
///      - Through CreateX, with a salt no sender owns (its first 20 bytes are nobody's): any caller gets the same
///        address, LARPPlan's.
///      - CREATE3 doesn't bind the code to the address, so anyone could use one of these salts first. A salt already
///        used (its proxy or its address has code), or a chain without CreateX (IMD first runs a launch on a fresh
///        chain), gets this contract's own CREATE3 instead: an address nobody can know before this contract exists, the
///        same contract. Nothing at a planned address is ever taken as LARP's.
abstract contract Placer {
    error PlaceFailed();

    /// @dev The CREATE3 proxy CreateX and Solady use: it CREATEs its calldata as init code (no DELEGATECALL)
    bytes internal constant PROXY = hex"67363d3d37363d34f03d5260086018f3";
    bytes32 internal constant PROXY_HASH = keccak256(PROXY);

    function _proxy(address deployer, bytes32 s) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, s, PROXY_HASH)))));
    }

    /// @dev What the proxy CREATEs first (its nonce 1)
    function _create3(address deployer, bytes32 s) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", _proxy(deployer, s), hex"01")))));
    }

    /// @dev Where `salt` lands: LARPPlan's address through CreateX (its guarded salt for a salt no sender owns is
    ///      keccak256(abi.encode(salt))), unless that can't be used; then this contract's own CREATE3.
    function _where(bytes32 salt) internal view returns (address at, bool viaCreateX) {
        if (LARPPlan.CREATEX.code.length != 0) {
            bytes32 g = keccak256(abi.encode(salt));
            at = _create3(LARPPlan.CREATEX, g);
            if (_proxy(LARPPlan.CREATEX, g).code.length == 0 && at.code.length == 0) return (at, true);
        }
        return (_create3(address(this), salt), false);
    }

    function _place(bytes32 salt, bytes memory init, address at, bool viaCreateX) internal {
        if (viaCreateX) {
            if (ICreateX(LARPPlan.CREATEX).deployCreate3(salt, init) != at) revert PlaceFailed();
        } else {
            bytes memory proxyCode = PROXY;
            address proxy;
            assembly ("memory-safe") {
                proxy := create2(0, add(proxyCode, 32), mload(proxyCode), salt)
            }
            if (proxy == address(0)) revert PlaceFailed();
            (bool ok,) = proxy.call(init);
            if (!ok) revert PlaceFailed();
        }
        if (at.code.length == 0) revert PlaceFailed();
    }
}

/// @title PlaceLARP - the IMD swarm's launch of LARP, the Linked Avatar Registry Protocol, part one
/// @notice Its constructor creates the burner (LARPBurner), the avatar registry (LARP) and IMD Names (IMDNames) at
///         LARPPlan's addresses, each starting 0x6900…, with README's constructor arguments: the burner knowing IMD
///         Names (the swarm's IMD6900 share), IMD Names knowing the registry and the burner. It calls nothing that
///         existed before it but CreateX, and only if it is there. It holds nothing and does nothing afterwards: its
///         three getters say where the contracts are.
contract PlaceLARP is Placer {
    address public immutable burner;
    address public immutable larp;
    address public immutable names;

    constructor() {
        (address b, bool bx) = _where(LARPPlan.BURNER_SALT);
        (address l, bool lx) = _where(LARPPlan.LARP_SALT);
        (address n, bool nx) = _where(LARPPlan.NAMES_SALT);
        _place(
            LARPPlan.BURNER_SALT,
            abi.encodePacked(
                type(LARPBurner).creationCode,
                abi.encode(
                    LARPPlan.POOL_MANAGER,
                    LARPPlan.IMD,
                    LARPPlan.POOL4_FEE,
                    LARPPlan.POOL4_SPACING,
                    LARPPlan.POOL4_HOOK,
                    LARPPlan.BACKUP_FEE,
                    LARPPlan.BACKUP_SPACING,
                    LARPPlan.IMD6900,
                    LARPPlan.PAIR_FEE,
                    LARPPlan.PAIR_SPACING,
                    LARPPlan.PAIR_HOOK,
                    n
                )
            ),
            b,
            bx
        );
        _place(LARPPlan.LARP_SALT, abi.encodePacked(type(LARP).creationCode, abi.encode(LARPPlan.IDENTITY)), l, lx);
        _place(
            LARPPlan.NAMES_SALT,
            abi.encodePacked(
                type(IMDNames).creationCode,
                abi.encode(LARPPlan.IDENTITY, l, b, LARPPlan.ARTIST, LARPPlan.INTAKE, LARPPlan.ORACLE_SIGNER)
            ),
            n,
            nx
        );
        (burner, larp, names) = (b, l, n);
    }
}

/// @title PlaceLinks - the IMD swarm's launch of LARP, part two: frens, crews and the jeet board
/// @notice Its constructor creates LARPLinks at LARPPlan's address (0x6900…) over the registry, the names and the burner
///         PlaceLARP placed (the launch passes it PlaceLARP, `$contract:PlaceLARP`), reading IMD's launcher for the
///         swarm's airdrops. The four don't fit one contract's init code (EIP-3860); the two fit one transaction.
contract PlaceLinks is Placer {
    address public immutable links;

    constructor(PlaceLARP placed) {
        (address k, bool kx) = _where(LARPPlan.LINKS_SALT);
        _place(
            LARPPlan.LINKS_SALT,
            abi.encodePacked(
                type(LARPLinks).creationCode,
                abi.encode(
                    LARPPlan.IDENTITY,
                    LARPPlan.LAUNCHER,
                    ILARP(placed.larp()),
                    IIMDNames(placed.names()),
                    placed.burner()
                )
            ),
            k,
            kx
        );
        links = k;
    }
}
