// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.sol";
import {LARPBurner} from "../src/LARPBurner.sol";

contract RawShareSource {
    bytes internal answer;

    function set(bytes memory raw) external {
        answer = raw;
    }

    fallback() external {
        bytes memory raw = answer;
        assembly ("memory-safe") {
            return(add(raw, 32), mload(raw))
        }
    }
}

contract LARPBurnerShareEdgesTest is Base {
    RawShareSource internal source;
    LARPBurner internal subject;

    function setUp() public {
        _deploy();
        _fillPair();
        source = new RawShareSource();
        subject = _newBurner(address(pm), address(source));
    }

    function test_OnlyOneAbiWordIsAnAcceptableShareAnswer() public {
        uint256[5] memory lengths = [uint256(0), 1, 31, 33, 64];
        for (uint256 i; i < lengths.length; ++i) {
            source.set(new bytes(lengths[i]));
            assertEq(subject.shareBps(), 690, "malformed zero is not a vote for a zero share");
        }
        source.set(abi.encode(uint256(0)));
        assertEq(subject.shareBps(), 0);
        source.set(abi.encode(uint256(10_000)));
        assertEq(subject.shareBps(), 10_000);
        source.set(abi.encode(uint256(10_001)));
        assertEq(subject.shareBps(), 690);
        source.set(abi.encode(type(uint256).max));
        assertEq(subject.shareBps(), 690);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_ValidShareSplitsEveryWeiAndBurnsActualSupply(uint16 share, uint256 amount) public {
        share = uint16(bound(share, 0, 10_000));
        amount = bound(amount, 0, 1_000 ether);
        source.set(abi.encode(uint256(share)));
        _split(amount, share);
    }

    function test_DustOnBothSidesOfTheFirstNonzeroShare() public {
        source.set(abi.encode(uint256(690)));
        _split(0, 690);
        _split(1, 690);
        _split(14, 690);
        _split(15, 690);
        _split(10_000, 690);
    }

    /// @dev The leg at a 100% share, a 1,000 $IMD burn and a pool of ~1,000 $IMD depth is the room itself (L-16),
    /// and the clipped part reaches IMD's burn as $IMD, never a searcher or 0xdEaD.
    function test_TheClippedShareGoesToTheCanonicalBurn() public {
        source.set(abi.encode(uint256(10_000)));
        uint256 room = _pairRoom();
        assertGt(room, 0);
        uint256 pmBefore = imd.balanceOf(address(pm));
        imd.mint(address(subject), 1_000 ether);
        subject.burnImd{gas: 5_000_000}();
        assertEq(imd.balanceOf(address(pm)) - pmBefore, room, "the leg is exactly the pool's room");
        assertEq(imd.balanceOf(IMD_BURN), 1_000 ether - room, "the clipped share went to IMD's burn");
        assertEq(imd.balanceOf(0x000000000000000000000000000000000000dEaD), 0);
    }

    function _split(uint256 amount, uint256 share) internal {
        uint256 pmBefore = imd.balanceOf(address(pm));
        uint256 canonicalBefore = imd.balanceOf(IMD_BURN);
        uint256 supplyBefore = imd6900.totalSupply();
        uint256 pool6900Before = imd6900.balanceOf(address(pm));
        // the pool's room before the leg: the cap the burner must honour (L-16), read independently
        uint256 room = _pairRoom();
        imd.mint(address(subject), amount);
        subject.burnImd{gas: 5_000_000}();
        uint256 spent = imd.balanceOf(address(pm)) - pmBefore;
        uint256 canonical = imd.balanceOf(IMD_BURN) - canonicalBefore;
        assertEq(spent + canonical, amount, "rounding loses no IMD");
        assertLe(spent, room, "one call never sells the pair pool more than its room");
        // A cross-multiplied bound checks floor rounding without duplicating
        // the production multiply/divide expression as an expected value.
        assertLe(spent * 10_000, amount * share);
        if (spent < room) {
            assertLt(amount * share - spent * 10_000, 10_000, "less than one IMD wei may round to the remainder");
        } else {
            assertGe(amount * share, room * 10_000, "clipped only when the share is above the room");
        }
        assertEq(supplyBefore - imd6900.totalSupply(), pool6900Before - imd6900.balanceOf(address(pm)));
        if (spent != 0) assertLt(imd6900.totalSupply(), supplyBefore);
        assertEq(imd.balanceOf(address(subject)), 0);
        assertEq(imd6900.balanceOf(address(subject)), 0);
        assertEq(imd.balanceOf(0x000000000000000000000000000000000000dEaD), 0);
    }
}
