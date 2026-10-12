// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "solady/tokens/ERC721.sol";
import {Base64} from "solady/utils/Base64.sol";
import {ILARP} from "./ILARP.sol";
import {IIMDNames, IIMDNameRenderer} from "./IIMDNames.sol";
import {LARPBurner} from "./LARPBurner.sol";
import {SwarmPrices} from "./SwarmPrices.sol";
import {Labels} from "./Labels.sol";
import {SafeReads} from "./SafeReads.sol";

/// @title IMD Names: name.imd, from the Linked Avatar Registry Protocol, by the IMD6900 frens
/// @notice ENS-style names for the IMD ecosystem, as ERC-721 NFTs. Paid once, kept forever, traded anywhere. A name
/// shows on an identity.md its owner holds once linked, while the owner holds both. Every fee buys $IMD and burns it,
/// through the LARP burner: the registration, the 6.9% royalty on secondary sales, and the toll a new owner pays once
/// to link the name (so every change of hands burns, whatever the market).
/// Prices change only by the IMD swarm's verdict on a proposal anyone can make, and anyone can execute (SwarmPrices).
/// @dev No owner and no upgrades. The one role, the artist, can only point tokenURI at a new renderer, until it locks
/// it; a renderer that fails falls back to the built-in one.
contract IMDNames is ERC721, IIMDNames, SwarmPrices {
    using SafeReads for address;

    struct Link {
        address holder;
        uint256 imdIdPlusOne;
    }

    /// @inheritdoc IIMDNames
    string public constant TLD = ".imd";
    /// @inheritdoc IIMDNames
    uint256 public constant ROYALTY_BPS = 690;
    /// @dev Gas a renderer may use for one tokenURI.
    uint256 internal constant RENDER_GAS = 10_000_000;

    /// @inheritdoc IIMDNames
    address public immutable IDENTITY;
    /// @notice LARP: who controls an identity (its owner or agent).
    ILARP public immutable LARP;
    /// @inheritdoc IIMDNames
    address public immutable BURNER;

    /// @inheritdoc IIMDNames
    address public artist;
    /// @inheritdoc IIMDNames
    address public renderer;
    /// @inheritdoc IIMDNames
    bool public rendererLocked;

    /// @dev name => the identity it is linked to and the owner who linked it
    mapping(uint256 tokenId => Link) internal _links;
    /// @dev identity => its linked name (two-way with `_links`)
    mapping(uint256 imdId => uint256 tokenId) internal _linkedName;
    /// @dev name => the owner who last paid for it (registered it, or paid its toll)
    mapping(uint256 tokenId => address) internal _paidBy;
    mapping(address wallet => uint256 imdIdPlusOne) internal _primary;
    mapping(uint256 imdId => mapping(address holder => mapping(bytes32 keyHash => string))) internal _texts;

    error ZeroAddress();

    /// @param identity identity.md
    /// @param larp the LARP registry
    /// @param burner the LARP burner
    /// @param artist_ who may change the renderer (until it is locked)
    /// @param intake IMD's oracle Intake
    /// @param oracleSigner IMD's oracle signer
    constructor(address identity, ILARP larp, address burner, address artist_, address intake, address oracleSigner)
        SwarmPrices(intake, oracleSigner, Prices(0.0069 ether, 0.00169 ether, 0.00069 ether, 0.00069 ether, 690))
    {
        if (identity == address(0) || address(larp) == address(0) || burner == address(0)) revert ZeroAddress();
        IDENTITY = identity;
        LARP = larp;
        BURNER = burner;
        artist = artist_;
    }

    // ------------------------------------------------------------------ names

    /// @inheritdoc IIMDNames
    function priceOf(bytes32 label) public view returns (uint256) {
        uint256 n = Labels.length(label);
        if (n == 0) revert BadName();
        if (n <= 3) return prices.short;
        if (n == 4) return prices.four;
        return prices.long;
    }

    /// @inheritdoc IIMDNames
    function crewPrice() external view returns (uint256) {
        return prices.crew;
    }

    function _imd() internal view override returns (address) {
        return LARPBurner(payable(BURNER)).IMD();
    }

    /// @inheritdoc IIMDNames
    function tollOf(uint256 tokenId) public view returns (uint256) {
        address owner = _ownerOf(tokenId);
        if (owner == address(0)) revert NoSuchName();
        return _paidBy[tokenId] == owner ? 0 : priceOf(bytes32(tokenId));
    }

    /// @inheritdoc IIMDNames
    function register(bytes32 label, address to, uint256 minImd) external payable returns (uint256 tokenId) {
        uint256 price;
        (tokenId, price) = _register(label, to);
        if (msg.value != price) revert WrongPrice();
        LARPBurner(payable(BURNER)).burn{value: price}(minImd);
    }

    /// @inheritdoc IIMDNames
    function registerWithImd(bytes32 label, address to, uint256 maxImd) external returns (uint256 tokenId) {
        uint256 price;
        (tokenId, price) = _register(label, to);
        _payImd(price, maxImd);
    }

    /// @inheritdoc IIMDNames
    function link(uint256 tokenId, uint256 imdId, uint256 minImd) external payable {
        uint256 toll = _link(tokenId, imdId);
        if (msg.value != toll) revert WrongPrice();
        if (toll != 0) LARPBurner(payable(BURNER)).burn{value: toll}(minImd);
    }

    /// @inheritdoc IIMDNames
    function linkWithImd(uint256 tokenId, uint256 imdId, uint256 maxImd) external {
        uint256 toll = _link(tokenId, imdId);
        if (toll != 0) _payImd(toll, maxImd);
    }

    function _register(bytes32 label, address to) internal returns (uint256 tokenId, uint256 price) {
        price = priceOf(label);
        tokenId = uint256(label);
        _mint(to, tokenId); // reverts for a taken name or address(0)
        _paidBy[tokenId] = to;
        emit NameRegistered(tokenId, label, to, price);
    }

    /// @dev Links, and returns the toll due (in ETH): the name's price if its owner isn't the one who last paid.
    function _link(uint256 tokenId, uint256 imdId) internal returns (uint256 toll) {
        address owner = _ownerOf(tokenId);
        if (owner == address(0)) revert NoSuchName();
        (bool ok, address holder) = LARP.canAct(imdId, msg.sender);
        if (!ok) revert NotYourIdentity();
        if (owner != holder) revert NotYourName();
        toll = _paidBy[tokenId] == holder ? 0 : priceOf(bytes32(tokenId));

        // the identity's old name and the name's old identity come apart
        uint256 old = _linkedName[imdId];
        if (old != 0 && old != tokenId) {
            delete _links[old];
            emit NameUnlinked(old, imdId);
        }
        uint256 was = _links[tokenId].imdIdPlusOne;
        if (was != 0 && was - 1 != imdId) {
            delete _linkedName[was - 1];
            emit NameUnlinked(tokenId, was - 1);
        }
        _links[tokenId] = Link(holder, imdId + 1);
        _linkedName[imdId] = tokenId;
        emit NameLinked(tokenId, imdId, holder, toll);
        if (toll != 0) _paidBy[tokenId] = holder;
    }

    /// @dev Pulls `eth`'s worth of $IMD (the burner's quote, at most `maxImd`) from the caller to the burner, which
    /// burns it.
    function _payImd(uint256 eth, uint256 maxImd) internal {
        LARPBurner burner = LARPBurner(payable(BURNER));
        uint256 due = burner.quoteImd(eth);
        if (due > maxImd) revert TooMuchImd();
        (bool ok, bytes memory r) = burner.IMD().call(abi.encodeWithSelector(0x23b872dd, msg.sender, BURNER, due)); // transferFrom
        if (!ok || (r.length != 0 && !abi.decode(r, (bool)))) revert WrongPrice();
        burner.burnImd();
    }

    /// @inheritdoc IIMDNames
    function unlink(uint256 imdId) external {
        uint256 tokenId = _linkedName[imdId];
        if (tokenId == 0) return;
        (bool ok,) = LARP.canAct(imdId, msg.sender);
        if (!ok && _ownerOf(tokenId) != msg.sender) revert NotYours();
        delete _linkedName[imdId];
        delete _links[tokenId];
        emit NameUnlinked(tokenId, imdId);
    }

    /// @inheritdoc IIMDNames
    function setPrimary(uint256 imdId) external {
        if (IDENTITY.ownerOf(imdId, gasleft()) != msg.sender) revert NotYourIdentity();
        _primary[msg.sender] = imdId + 1;
        emit PrimarySet(msg.sender, imdId);
    }

    /// @inheritdoc IIMDNames
    function setText(uint256 imdId, string calldata key, string calldata value) external {
        (bool ok, address holder) = LARP.canAct(imdId, msg.sender);
        if (!ok) revert NotYourIdentity();
        _texts[imdId][holder][keccak256(bytes(key))] = value;
        emit TextSet(imdId, holder, key, value);
    }

    // ------------------------------------------------------------------ reading

    /// @inheritdoc IIMDNames
    function nameOfToken(uint256 tokenId) public pure returns (string memory) {
        return string.concat(Labels.toString(bytes32(tokenId)), TLD);
    }

    /// @inheritdoc IIMDNames
    function nameOf(uint256 imdId) public view returns (string memory) {
        uint256 tokenId = _linkedName[imdId];
        if (tokenId == 0 || !_live(tokenId, imdId)) return "";
        return nameOfToken(tokenId);
    }

    /// @inheritdoc IIMDNames
    function identityOf(uint256 tokenId) public view returns (uint256 imdId, bool live) {
        uint256 at = _links[tokenId].imdIdPlusOne;
        if (at == 0) return (0, false);
        imdId = at - 1;
        live = _live(tokenId, imdId);
    }

    /// @inheritdoc IIMDNames
    function resolve(bytes32 label) public view returns (bool exists, address owner, uint256 imdId, bool linked) {
        owner = _ownerOf(uint256(label));
        if (owner == address(0)) return (false, address(0), 0, false);
        exists = true;
        (imdId, linked) = identityOf(uint256(label));
    }

    /// @inheritdoc IIMDNames
    function resolveName(string calldata full)
        external
        view
        returns (bool exists, address owner, uint256 imdId, bool linked)
    {
        bytes32 label = Labels.fromName(full, TLD);
        if (label == 0) return (false, address(0), 0, false);
        return resolve(label);
    }

    /// @inheritdoc IIMDNames
    function primaryOf(address wallet) external view returns (uint256 imdId, string memory full, bool live) {
        uint256 at = _primary[wallet];
        if (at == 0) return (0, "", false);
        imdId = at - 1;
        live = IDENTITY.ownerOf(imdId, gasleft()) == wallet;
        if (live) full = nameOf(imdId);
    }

    /// @inheritdoc IIMDNames
    function text(uint256 imdId, string calldata key) external view returns (string memory) {
        return _texts[imdId][IDENTITY.ownerOf(imdId, gasleft())][keccak256(bytes(key))];
    }

    /// @dev Live: the owner who linked it still owns the name and the identity.
    function _live(uint256 tokenId, uint256 imdId) internal view returns (bool) {
        Link storage l = _links[tokenId];
        return
            l.imdIdPlusOne == imdId + 1 && _ownerOf(tokenId) == l.holder
                && IDENTITY.ownerOf(imdId, gasleft()) == l.holder;
    }

    // ------------------------------------------------------------------ ERC-721, ERC-2981

    function name() public pure override returns (string memory) {
        return "IMD Names";
    }

    function symbol() public pure override returns (string memory) {
        return "IMDNAME";
    }

    /// @notice The name's art: the renderer's, or the built-in card when there is none or it gives nothing.
    function tokenURI(uint256 tokenId) public view override returns (string memory uri) {
        if (!_exists(tokenId)) revert TokenDoesNotExist();
        string memory full = nameOfToken(tokenId);
        (uint256 imdId, bool live) = identityOf(tokenId);
        uint256 linked = live ? imdId + 1 : 0;
        if (renderer != address(0)) {
            uri = renderer.textCall(
                abi.encodeCall(IIMDNameRenderer.render, (tokenId, full, linked)),
                RENDER_GAS < gasleft() ? RENDER_GAS : gasleft()
            );
            if (bytes(uri).length != 0) return uri;
        }
        return _card(full, linked);
    }

    /// @notice ERC-2981: 6.9% of a sale, to the burner.
    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        return (BURNER, salePrice * ROYALTY_BPS / 10_000);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return
            interfaceId == 0x2a55205a || interfaceId == type(IIMDNames).interfaceId
                || super.supportsInterface(interfaceId);
    }

    // ------------------------------------------------------------------ the art (the one changeable thing)

    /// @inheritdoc IIMDNames
    function setRenderer(address renderer_) external {
        if (msg.sender != artist) revert NotArtist();
        if (rendererLocked) revert Locked();
        renderer = renderer_;
        emit RendererSet(renderer_);
    }

    /// @inheritdoc IIMDNames
    function setArtist(address artist_) external {
        if (msg.sender != artist) revert NotArtist();
        artist = artist_;
        emit ArtistSet(artist_);
    }

    /// @inheritdoc IIMDNames
    function lockRenderer() external {
        if (msg.sender != artist) revert NotArtist();
        rendererLocked = true;
        emit RendererLocked();
    }

    /// @dev The built-in card: the name in green on black, and the identity it shows on. Labels are a-z, 0-9 and '-',
    /// so nothing needs escaping in the SVG or the JSON.
    function _card(string memory full, uint256 linked) internal pure returns (string memory) {
        uint256 length = bytes(full).length;
        uint256 size = 860 / (length + 2);
        if (size > 96) size = 96;
        string memory footer = linked == 0 ? "IMD name" : string.concat("identity.md #", _decimal(linked - 1));
        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 600"><rect width="600" height="600" fill="#0b0f0c"/>',
            '<rect x="24" y="24" width="552" height="552" rx="28" fill="none" stroke="#3ddc84" stroke-width="4"/>',
            '<text x="300" y="300" font-family="monospace" font-size="',
            _decimal(size),
            '" fill="#3ddc84" text-anchor="middle" dominant-baseline="middle">',
            full,
            '</text><text x="300" y="536" font-family="monospace" font-size="20" fill="#6b8f71" text-anchor="middle">',
            footer,
            "</text></svg>"
        );
        string memory json = string.concat(
            '{"name":"',
            full,
            '","description":"An IMD name, from the Linked Avatar Registry Protocol, by the IMD6900 frens.","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)),
            '","attributes":[{"trait_type":"Length","value":',
            _decimal(length - 4),
            "}",
            linked == 0 ? "" : string.concat(',{"trait_type":"Identity","value":', _decimal(linked - 1), "}"),
            "]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }
}
