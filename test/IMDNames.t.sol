// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.sol";
import {IMDNames} from "../src/IMDNames.sol";
import {IIMDNames, IIMDNameRenderer} from "../src/IIMDNames.sol";
import {LARPBurner} from "../src/LARPBurner.sol";

contract FancyRenderer is IIMDNameRenderer {
    function render(uint256, string calldata full, uint256 imdIdPlusOne) external pure returns (string memory) {
        return string.concat("fancy:", full, ":", imdIdPlusOne == 0 ? "unlinked" : "linked");
    }
}

contract BrokenRenderer {
    fallback() external {
        revert("broken");
    }
}

contract HungryRenderer {
    fallback() external {
        while (true) {}
    }
}

contract IMDNamesTest is Base {
    event NameLinked(uint256 indexed tokenId, uint256 indexed imdId, address indexed holder, uint256 toll);
    event NameUnlinked(uint256 indexed tokenId, uint256 indexed imdId);

    uint256 kek; // kekmaster.imd

    function setUp() public {
        _deploy();
        _fillPool4();
        identity.mint(alice, 0);
        identity.mint(alice, 1);
        identity.mint(bob, 2);
        kek = _register(alice, "kekmaster");
    }

    // --- registering ---

    function test_RegisteringMintsTheNameAndBurnsTheFee() public {
        uint256 before = imd.balanceOf(IMD_BURN);
        uint256 id = _register(carol, "frenly");
        assertEq(id, uint256(_label("frenly")), "the token id is the label");
        assertEq(names.ownerOf(id), carol);
        assertEq(names.balanceOf(carol), 1);
        assertGt(imd.balanceOf(IMD_BURN), before, "the fee bought $IMD for 0x..dEaD");
        assertEq(address(names).balance, 0);
        assertEq(address(burner).balance, 0);
        assertEq(names.nameOfToken(id), "frenly.imd");
    }

    function test_AnyoneRegistersAnyFreeName() public {
        address stranger = makeAddr("stranger"); // no identity
        _register(stranger, "outsider");
        (bool exists, address owner,, bool linked) = names.resolveName("outsider.imd");
        assertTrue(exists);
        assertEq(owner, stranger);
        assertFalse(linked);
    }

    function test_RegisterForSomeoneElse() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        uint256 id = names.register{value: 0.00069 ether}(_label("a-gift"), bob, 0);
        assertEq(names.ownerOf(id), bob);
        assertEq(names.tollOf(id), 0, "the receiver of a registration owes no toll");
    }

    function test_RegistrationRules() public {
        vm.deal(bob, 1 ether);
        vm.startPrank(bob);
        vm.expectRevert(); // solady TokenAlreadyExists
        names.register{value: 0.00069 ether}(_label("kekmaster"), bob, 0);
        vm.expectRevert(IIMDNames.WrongPrice.selector);
        names.register{value: 0.0007 ether}(_label("kekmasters"), bob, 0);
        vm.expectRevert(IIMDNames.BadName.selector);
        names.register{value: 0.00069 ether}(_label("Kek"), bob, 0);
        vm.expectRevert(); // solady TransferToZeroAddress
        names.register{value: 0.00069 ether}(_label("nobody-here"), address(0), 0);
        vm.stopPrank();
    }

    function test_Prices() public view {
        assertEq(names.priceOf(_label("a")), 0.0069 ether);
        assertEq(names.priceOf(_label("kek")), 0.0069 ether);
        assertEq(names.priceOf(_label("pepe")), 0.00169 ether);
        assertEq(names.priceOf(_label("frens")), 0.00069 ether);
        assertEq(names.priceOf(_label("0123456789abcdefghijklmnopqrstuv")), 0.00069 ether);
    }

    function test_BadNames() public {
        bytes32[7] memory bad = [
            bytes32(0),
            _label("Kek"),
            _label("-kek"),
            _label("kek-"),
            _label("ke k"),
            _label("ke.k"),
            bytes32(uint256(_label("kek")) | 1)
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(IIMDNames.BadName.selector);
            names.priceOf(bad[i]);
        }
    }

    function test_AFeeParksWhenNoPoolCanTakeIt() public {
        _deploy(); // fresh, with both pools empty
        _register(carol, "patient");
        assertEq(names.ownerOf(uint256(_label("patient"))), carol, "registered all the same");
        assertEq(address(burner).balance, 0.00069 ether, "the fee waits in the burner for the next burn");
    }

    // --- paying in $IMD ---

    function _imdPayer(address who) internal {
        _fillBackup();
        _fillPair();
        imd.mint(who, 1_000 ether);
        vm.prank(who);
        imd.approve(address(names), type(uint256).max);
    }

    function test_RegisterWithImd() public {
        _imdPayer(carol);
        uint256 due = burner.quoteImd(0.00069 ether);
        assertApproxEqRel(due, 1.38 ether, 0.02e18, "0.00069 ETH at ~2,000 IMD per ETH");
        uint256 supply6900 = imd6900.totalSupply();
        uint256 dead = imd.balanceOf(IMD_BURN);
        vm.prank(carol);
        uint256 id = names.registerWithImd(_label("paid-in-imd"), carol, due);
        assertEq(names.ownerOf(id), carol);
        assertEq(imd.balanceOf(carol), 1_000 ether - due, "exactly the quote, pulled");
        assertEq(imd.balanceOf(IMD_BURN) - dead, due - due * 690 / 10_000, "93.1% to 0x..dEaD");
        assertLt(imd6900.totalSupply(), supply6900, "6.9% bought IMD6900, burned");
        assertEq(imd.balanceOf(address(burner)), 0);
    }

    function test_RegisterWithImdRespectsMaxImd() public {
        _imdPayer(carol);
        uint256 due = burner.quoteImd(0.00069 ether);
        vm.prank(carol);
        vm.expectRevert(IIMDNames.TooMuchImd.selector);
        names.registerWithImd(_label("paid-in-imd"), carol, due - 1);
    }

    function test_NoImdPaymentWithoutBothPools() public {
        imd.mint(carol, 1_000 ether);
        vm.prank(carol);
        imd.approve(address(names), type(uint256).max);
        vm.prank(carol);
        vm.expectRevert(LARPBurner.NoPrice.selector); // only POOL4 has liquidity here: pay in ETH instead
        names.registerWithImd(_label("paid-in-imd"), carol, 1_000 ether);
    }

    function test_TheTollInImd() public {
        _imdPayer(bob);
        vm.prank(alice);
        names.transferFrom(alice, bob, kek);
        uint256 due = burner.quoteImd(names.tollOf(kek));
        vm.prank(bob);
        names.linkWithImd(kek, 2, due);
        assertEq(names.nameOf(2), "kekmaster.imd");
        assertEq(imd.balanceOf(bob), 1_000 ether - due);
        assertEq(names.tollOf(kek), 0);
        // no toll due: nothing is pulled
        vm.prank(bob);
        names.linkWithImd(kek, 2, 0);
        assertEq(imd.balanceOf(bob), 1_000 ether - due);
    }

    // --- linking ---

    function test_LinkTheNameToAnIdentity() public {
        vm.expectEmit(address(names));
        emit NameLinked(kek, 0, alice, 0);
        vm.prank(alice);
        names.link(kek, 0, 0);
        assertEq(names.nameOf(0), "kekmaster.imd");
        (uint256 imdId, bool live) = names.identityOf(kek);
        assertEq(imdId, 0);
        assertTrue(live);
        (bool exists, address owner, uint256 id, bool linked) = names.resolve(_label("kekmaster"));
        assertTrue(exists);
        assertEq(owner, alice);
        assertEq(id, 0);
        assertTrue(linked);
    }

    function test_LinkRules() public {
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        vm.expectRevert(IIMDNames.NotYourIdentity.selector);
        names.link(kek, 2, 0); // bob's identity
        vm.expectRevert(IIMDNames.NoSuchName.selector);
        names.link(uint256(_label("nothing")), 0, 0);
        vm.expectRevert(IIMDNames.WrongPrice.selector);
        names.link{value: 1}(kek, 0, 0); // no toll due
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(IIMDNames.NotYourName.selector);
        names.link(kek, 2, 0); // alice's name
    }

    function test_OneNamePerIdentityOneIdentityPerName() public {
        uint256 other = _register(alice, "second-name");
        vm.startPrank(alice);
        names.link(kek, 0, 0);
        // moving the name to another identity frees the first
        vm.expectEmit(address(names));
        emit NameUnlinked(kek, 0);
        names.link(kek, 1, 0);
        assertEq(names.nameOf(0), "");
        assertEq(names.nameOf(1), "kekmaster.imd");
        // a second name on the same identity replaces the first
        vm.expectEmit(address(names));
        emit NameUnlinked(kek, 1);
        names.link(other, 1, 0);
        vm.stopPrank();
        assertEq(names.nameOf(1), "second-name.imd");
        (, bool live) = names.identityOf(kek);
        assertFalse(live);
    }

    function test_SellingTheNameTakesItDown() public {
        vm.prank(alice);
        names.link(kek, 0, 0);
        vm.prank(alice);
        names.transferFrom(alice, bob, kek);
        assertEq(names.nameOf(0), "", "alice's identity no longer shows it");
        (, address owner,, bool linked) = names.resolve(_label("kekmaster"));
        assertEq(owner, bob);
        assertFalse(linked);
    }

    function test_SellingTheIdentityTakesItDown() public {
        vm.prank(alice);
        names.link(kek, 0, 0);
        vm.prank(alice);
        identity.transferFrom(alice, bob, 0);
        assertEq(names.nameOf(0), "");
    }

    // --- the toll: every new owner burns once ---

    function test_ANewOwnerPaysTheTollToLink() public {
        vm.prank(alice);
        names.transferFrom(alice, bob, kek); // a secondary sale, on any market
        assertEq(names.tollOf(kek), 0.00069 ether);

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(IIMDNames.WrongPrice.selector);
        names.link(kek, 2, 0);

        uint256 before = imd.balanceOf(IMD_BURN);
        vm.expectEmit(address(names));
        emit NameLinked(kek, 2, bob, 0.00069 ether);
        vm.prank(bob);
        names.link{value: 0.00069 ether}(kek, 2, 0);
        assertGt(imd.balanceOf(IMD_BURN), before, "the toll was burned");
        assertEq(names.nameOf(2), "kekmaster.imd");
        assertEq(names.tollOf(kek), 0, "paid once");

        // relinking later is free
        vm.prank(bob);
        names.unlink(2);
        vm.prank(bob);
        names.link(kek, 2, 0);
    }

    function test_TheTollFollowsEveryChangeOfHands() public {
        vm.prank(alice);
        names.transferFrom(alice, bob, kek);
        vm.prank(bob);
        names.transferFrom(bob, alice, kek);
        assertEq(names.tollOf(kek), 0, "back to the owner who paid for it");
        vm.prank(alice);
        names.transferFrom(alice, carol, kek);
        assertEq(names.tollOf(kek), 0.00069 ether);
    }

    function test_ShortNamesHaveShortNameTolls() public {
        uint256 id = _register(alice, "gm");
        vm.prank(alice);
        names.transferFrom(alice, bob, id);
        assertEq(names.tollOf(id), 0.0069 ether);
    }

    // --- unlinking ---

    function test_Unlink() public {
        vm.prank(alice);
        names.link(kek, 0, 0);
        vm.prank(bob);
        vm.expectRevert(IIMDNames.NotYours.selector);
        names.unlink(0);
        vm.prank(alice);
        names.unlink(0);
        assertEq(names.nameOf(0), "");
    }

    function test_TheNamesNewOwnerUnlinksAStaleLink() public {
        vm.prank(alice);
        names.link(kek, 0, 0);
        vm.prank(alice);
        names.transferFrom(alice, bob, kek);
        vm.prank(bob); // owns the name, not identity 0
        names.unlink(0);
        (uint256 imdId,) = names.identityOf(kek);
        assertEq(imdId, 0);
        (, bool live) = names.identityOf(kek);
        assertFalse(live);
    }

    // --- secondary royalties ---

    function test_RoyaltiesGoToTheBurner() public view {
        (address receiver, uint256 amount) = names.royaltyInfo(kek, 1 ether);
        assertEq(receiver, address(burner));
        assertEq(amount, 0.069 ether, "6.9% of a 1 ETH sale");
        assertTrue(names.supportsInterface(0x2a55205a), "ERC-2981");
        assertTrue(names.supportsInterface(0x80ac58cd), "ERC-721");
        assertTrue(names.supportsInterface(0x5b5e139f), "metadata");
        assertTrue(names.supportsInterface(type(IIMDNames).interfaceId));
    }

    function test_ARoyaltyPaymentIsBurned() public {
        // a market pays the royalty to the burner; anyone burns it
        (bool ok,) = address(burner).call{value: 0.0069 ether}("");
        assertTrue(ok);
        uint256 before = imd.balanceOf(IMD_BURN);
        burner.burn(0);
        assertGt(imd.balanceOf(IMD_BURN), before);
    }

    // --- reverse records and text ---

    function test_Primary() public {
        vm.prank(alice);
        names.link(kek, 1, 0);
        vm.prank(alice);
        names.setPrimary(1);
        (uint256 imdId, string memory full, bool live) = names.primaryOf(alice);
        assertEq(imdId, 1);
        assertEq(full, "kekmaster.imd");
        assertTrue(live);
        vm.prank(alice);
        identity.transferFrom(alice, bob, 1);
        (,, live) = names.primaryOf(alice);
        assertFalse(live);
    }

    function test_TextRecordsStartOverWithANewHolder() public {
        vm.prank(alice);
        names.setText(0, "x", "@kekmaster");
        assertEq(names.text(0, "x"), "@kekmaster");
        vm.prank(alice);
        identity.transferFrom(alice, bob, 0);
        assertEq(names.text(0, "x"), "");
        vm.prank(bob);
        names.setText(0, "x", "@bob");
        assertEq(names.text(0, "x"), "@bob");
    }

    // --- the art: the one thing that can change ---

    function test_TheBuiltInCard() public {
        vm.prank(alice);
        names.link(kek, 0, 0);
        string memory uri = names.tokenURI(kek);
        assertEq(_prefix(uri, 29), "data:application/json;base64,");
        assertTrue(_contains(_decoded(uri), '"name":"kekmaster.imd"'));
        assertTrue(_contains(_decoded(uri), '"trait_type":"Identity","value":0'));
        vm.expectRevert(); // TokenDoesNotExist
        names.tokenURI(uint256(_label("nothing")));
    }

    function test_TheArtistChangesTheArtAndOnlyTheArt() public {
        FancyRenderer fancy = new FancyRenderer();
        vm.prank(bob);
        vm.expectRevert(IIMDNames.NotArtist.selector);
        names.setRenderer(address(fancy));

        vm.prank(artist);
        names.setRenderer(address(fancy));
        assertEq(names.tokenURI(kek), "fancy:kekmaster.imd:unlinked");

        vm.prank(artist);
        names.setArtist(bob);
        vm.prank(artist);
        vm.expectRevert(IIMDNames.NotArtist.selector);
        names.setRenderer(address(0));

        vm.prank(bob);
        names.lockRenderer();
        vm.prank(bob);
        vm.expectRevert(IIMDNames.Locked.selector);
        names.setRenderer(address(0));
        assertTrue(names.rendererLocked());
    }

    function test_ABrokenRendererFallsBackToTheCard() public {
        string memory card = names.tokenURI(kek);
        vm.startPrank(artist);
        names.setRenderer(address(new BrokenRenderer()));
        assertEq(names.tokenURI(kek), card);
        names.setRenderer(address(new HungryRenderer()));
        assertEq(names.tokenURI(kek), card, "a renderer that eats its gas falls back too");
        names.setRenderer(makeAddr("no code"));
        assertEq(names.tokenURI(kek), card);
        vm.stopPrank();
    }

    // --- helpers ---

    function _prefix(string memory s, uint256 n) internal pure returns (string memory out) {
        bytes memory b = bytes(s);
        bytes memory o = new bytes(n);
        for (uint256 i; i < n; ++i) {
            o[i] = b[i];
        }
        out = string(o);
    }

    function _b64(string memory uri) internal pure returns (bytes memory) {
        bytes memory b = bytes(uri);
        bytes memory o = new bytes(b.length - 29);
        for (uint256 i; i < o.length; ++i) {
            o[i] = b[i + 29];
        }
        return o;
    }

    function _decoded(string memory uri) internal pure returns (string memory) {
        return string(_base64Decode(_b64(uri)));
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

    function _base64Decode(bytes memory data) internal pure returns (bytes memory) {
        bytes memory table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        uint8[128] memory rev;
        for (uint8 i; i < 64; ++i) {
            rev[uint8(table[i])] = i;
        }
        uint256 pad;
        if (data.length > 0 && data[data.length - 1] == "=") ++pad;
        if (data.length > 1 && data[data.length - 2] == "=") ++pad;
        bytes memory out = new bytes(data.length / 4 * 3 - pad);
        uint256 k;
        for (uint256 i; i < data.length; i += 4) {
            uint256 n = (uint256(rev[uint8(data[i])]) << 18) | (uint256(rev[uint8(data[i + 1])]) << 12)
                | (uint256(data[i + 2] == "=" ? 0 : rev[uint8(data[i + 2])]) << 6)
                | uint256(data[i + 3] == "=" ? 0 : rev[uint8(data[i + 3])]);
            for (uint256 j; j < 3 && k < out.length; ++j) {
                out[k++] = bytes1(uint8(n >> (16 - 8 * j)));
            }
        }
        return out;
    }
}
