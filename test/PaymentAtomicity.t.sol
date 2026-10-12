// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.sol";
import {IMDNames} from "../src/IMDNames.sol";
import {IIMDNames} from "../src/IIMDNames.sol";
import {LARPLinks} from "../src/LARPLinks.sol";
import {LARPBurner} from "../src/LARPBurner.sol";

/// @dev A receiver may exercise only its newly acquired rights inside the ERC721
/// callback. Rejection must undo the callback's nested name payment and swap too.
contract PayingNameReceiver {
    IMDNames public immutable names;
    uint256 public immutable identityId;
    address public immutable forwardTo;
    bool public immutable reject;
    bool public sawOwnership;
    bytes public receivedData;
    error CallbackRejected();

    constructor(IMDNames n, uint256 id, address forward, bool reject_) {
        names = n;
        identityId = id;
        forwardTo = forward;
        reject = reject_;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata data) external returns (bytes4) {
        require(msg.sender == address(names));
        sawOwnership = names.ownerOf(tokenId) == address(this);
        require(sawOwnership);
        receivedData = data;
        names.link{value: names.tollOf(tokenId)}(tokenId, identityId, 1);
        names.setPrimary(identityId);
        names.setText(identityId, "receiver", "accepted");
        if (forwardTo != address(0)) names.transferFrom(address(this), forwardTo, tokenId);
        if (reject) revert CallbackRejected();
        return 0x150b7a02;
    }
}

contract PaymentAtomicityTest is Base {
    uint256 internal resold;
    uint256 internal incumbent;

    struct Balances {
        uint256 aliceEth;
        uint256 bobEth;
        uint256 bobImd;
        uint256 burnerEth;
        uint256 burnerImd;
        uint256 poolEth;
        uint256 poolImd;
        uint256 pool6900;
        uint256 canonical;
        uint256 supply6900;
    }

    function setUp() public {
        _deploy();
        _fillPool4();
        _fillBackup();
        _fillPair();
        identity.mint(alice, 0);
        identity.mint(bob, 1);
        resold = _register(alice, "resold");
        incumbent = _register(bob, "incumbent");
        vm.prank(alice);
        names.link(resold, 0, 0);
        vm.prank(bob);
        names.link(incumbent, 1, 0);
        vm.prank(alice);
        names.transferFrom(alice, bob, resold);
        vm.deal(bob, 10 ether);
        imd.mint(bob, 10_000 ether);
        vm.startPrank(bob);
        imd.approve(address(names), 10_000 ether);
        imd.approve(address(links), 10_000 ether);
        vm.stopPrank();
    }

    function _balances() internal view returns (Balances memory b) {
        b = Balances(
            alice.balance,
            bob.balance,
            imd.balanceOf(bob),
            address(burner).balance,
            imd.balanceOf(address(burner)),
            address(pm).balance,
            imd.balanceOf(address(pm)),
            imd6900.balanceOf(address(pm)),
            imd.balanceOf(IMD_BURN),
            imd6900.totalSupply()
        );
    }

    function _assertBalances(Balances memory b) internal view {
        assertEq(abi.encode(_balances()), abi.encode(b), "all external payment and pool effects must roll back");
        assertEq(address(names).balance, 0);
        assertEq(address(links).balance, 0);
    }

    /// @dev All six paid entry points perform state writes before the burner.
    /// Reverting the late burn must restore NFTs, the replaced link, crew ids,
    /// balances, allowances and pool reserves; then the identical action can retry.
    function _refuseAndRetry(uint8 operation, bool transferFailure) internal {
        bytes32 label = bytes32("atomic");
        uint256 fee = operation < 2 ? names.priceOf(label) : operation < 4 ? names.tollOf(resold) : names.crewPrice();
        bool inImd = operation % 2 == 1;
        uint256 quote = burner.quoteImd(fee);
        address target = operation < 4 ? address(names) : address(links);
        bytes memory data;
        if (operation == 0) data = abi.encodeCall(names.register, (label, bob, 0));
        else if (operation == 1) data = abi.encodeCall(names.registerWithImd, (label, bob, quote));
        else if (operation == 2) data = abi.encodeCall(names.link, (resold, 1, 0));
        else if (operation == 3) data = abi.encodeCall(names.linkWithImd, (resold, 1, quote));
        else if (operation == 4) data = abi.encodeCall(links.foundCrew, (1, label, true, 0));
        else data = abi.encodeCall(links.foundCrewWithImd, (1, label, true, quote));

        Balances memory before = _balances();
        uint256 namesAllowance = imd.allowance(bob, address(names));
        uint256 linksAllowance = imd.allowance(bob, address(links));
        uint256 nftBalance = names.balanceOf(bob);
        if (transferFailure) {
            // The IMD transfer to BurnExecutor happens after swaps. Returning
            // false here must revert everything, including a successful pair leg.
            // Match selector + recipient, with any amount (partial calldata match).
            vm.mockCall(address(imd), abi.encodePacked(bytes4(0xa9059cbb), abi.encode(IMD_BURN)), abi.encode(false));
        }
        vm.prank(bob);
        (bool ok, bytes memory errorData) =
            target.call{value: inImd ? 0 : fee, gas: transferFailure ? 5_000_000 : 500_000}(data);
        assertFalse(ok);
        assertEq(
            bytes4(errorData), transferFailure ? LARPBurner.TransferFailed.selector : LARPBurner.TooLittleGas.selector
        );
        vm.clearMockedCalls();
        _assertBalances(before);
        assertEq(imd.allowance(bob, address(names)), namesAllowance);
        assertEq(imd.allowance(bob, address(links)), linksAllowance);
        assertEq(names.balanceOf(bob), nftBalance);
        assertEq(names.nameOf(1), "incumbent.imd", "the old name survives a failed replacement");
        (uint256 oldIdentity, bool live) = names.identityOf(incumbent);
        assertEq(oldIdentity, 1);
        assertTrue(live);
        assertEq(names.tollOf(resold), names.priceOf(bytes32(resold)));
        assertEq(links.crewCount(), 0);
        assertEq(links.crewOf(1), 0);
        assertEq(links.crewByName(label), 0);
        (bool exists,,,) = names.resolve(label);
        assertFalse(exists);

        vm.prank(bob);
        (ok,) = target.call{value: inImd ? 0 : fee, gas: 5_000_000}(data);
        assertTrue(ok, "failure must not consume a label, crew id, link or allowance");
        assertGt(imd.balanceOf(IMD_BURN), before.canonical);
        assertLt(imd6900.totalSupply(), before.supply6900);
        if (operation < 2) {
            assertEq(names.ownerOf(uint256(label)), bob);
        } else if (operation < 4) {
            assertEq(names.nameOf(1), "resold.imd");
            assertEq(names.tollOf(resold), 0);
            (, live) = names.identityOf(incumbent);
            assertFalse(live);
        } else {
            assertEq(links.crewOf(1), 1);
            assertEq(links.crewCount(), 1);
        }
    }

    function test_AllSixPaymentsRejectCallerGasStarvationAtomically() public {
        for (uint8 operation; operation < 6; ++operation) {
            uint256 snapshot = vm.snapshotState();
            _refuseAndRetry(operation, false);
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function test_AllSixPaymentsRollBackWhenCanonicalTransferFails() public {
        for (uint8 operation; operation < 6; ++operation) {
            uint256 snapshot = vm.snapshotState();
            _refuseAndRetry(operation, true);
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function test_ImdTransferFailureDoesNotMintOrFoundOrPayAToll() public {
        bytes32 label = bytes32("transfer-failure");
        uint256 quote = burner.quoteImd(names.priceOf(label));
        Balances memory before = _balances();
        vm.mockCall(address(imd), abi.encodeWithSelector(bytes4(0x23b872dd)), abi.encode(false));
        vm.prank(bob);
        vm.expectRevert(IIMDNames.WrongPrice.selector);
        names.registerWithImd(label, bob, quote);
        vm.prank(bob);
        vm.expectRevert(IIMDNames.WrongPrice.selector);
        names.linkWithImd(resold, 1, quote);
        vm.prank(bob);
        vm.expectRevert(LARPLinks.WrongPrice.selector);
        links.foundCrewWithImd(1, label, true, quote);
        vm.clearMockedCalls();
        _assertBalances(before);
        (bool exists,,,) = names.resolve(label);
        assertFalse(exists);
        assertEq(names.nameOf(1), "incumbent.imd");
        assertEq(names.tollOf(resold), names.priceOf(bytes32(resold)));
        assertEq(links.crewCount(), 0);
    }

    function test_ReceiverCanPayItsTollInsideEitherSafeTransferCallback() public {
        for (uint256 mode; mode < 2; ++mode) {
            uint256 snapshot = vm.snapshotState();
            PayingNameReceiver receiver = new PayingNameReceiver(names, 2, address(0), false);
            identity.mint(address(receiver), 2);
            uint256 toll = names.priceOf(bytes32(resold));
            vm.deal(address(receiver), toll);
            uint256 supply = imd6900.totalSupply();
            vm.prank(bob);
            if (mode == 0) names.safeTransferFrom(bob, address(receiver), resold);
            else names.safeTransferFrom(bob, address(receiver), resold, "receiver data");
            assertTrue(receiver.sawOwnership());
            assertEq(receiver.receivedData(), mode == 0 ? bytes("") : bytes("receiver data"));
            assertEq(names.ownerOf(resold), address(receiver));
            assertEq(names.nameOf(2), "resold.imd");
            assertEq(names.tollOf(resold), 0);
            assertEq(address(receiver).balance, 0);
            assertLt(imd6900.totalSupply(), supply);
            (uint256 primary,, bool live) = names.primaryOf(address(receiver));
            assertEq(primary, 2);
            assertTrue(live);
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function test_ForwardingInTheCallbackLeavesTheNextHolderOwingItsOwnToll() public {
        PayingNameReceiver receiver = new PayingNameReceiver(names, 2, carol, false);
        identity.mint(address(receiver), 2);
        identity.mint(carol, 3);
        uint256 toll = names.priceOf(bytes32(resold));
        vm.deal(address(receiver), toll);
        vm.prank(bob);
        names.safeTransferFrom(bob, address(receiver), resold, "forward");
        assertTrue(receiver.sawOwnership());
        assertEq(names.ownerOf(resold), carol);
        assertEq(names.nameOf(2), "");
        assertEq(names.tollOf(resold), toll);
        vm.deal(carol, toll);
        vm.prank(carol);
        names.link{value: toll}(resold, 3, 1);
        assertEq(names.nameOf(3), "resold.imd");
        assertEq(names.tollOf(resold), 0);
    }

    function test_RejectingReceiverRollsBackItsNestedPaymentRecordsAndSwap() public {
        PayingNameReceiver receiver = new PayingNameReceiver(names, 2, address(0), true);
        identity.mint(address(receiver), 2);
        uint256 toll = names.priceOf(bytes32(resold));
        vm.deal(address(receiver), toll);
        Balances memory before = _balances();
        vm.prank(bob);
        vm.expectRevert(PayingNameReceiver.CallbackRejected.selector);
        names.safeTransferFrom(bob, address(receiver), resold, "reject");
        _assertBalances(before);
        assertEq(names.ownerOf(resold), bob);
        assertEq(names.balanceOf(address(receiver)), 0);
        assertEq(address(receiver).balance, toll);
        assertFalse(receiver.sawOwnership());
        assertEq(names.nameOf(2), "");
        assertEq(names.text(2, "receiver"), "");
        (,, bool live) = names.primaryOf(address(receiver));
        assertFalse(live);
        assertEq(names.tollOf(resold), toll);
    }
}
