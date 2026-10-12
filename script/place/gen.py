#!/usr/bin/env python3
"""LARP's launch, planned: all four contracts land at 0x6900… addresses on Ethereum, decided here.

IMD deploys a launch from its own deployer, so nothing it creates directly has an address anyone knows in advance, and
its manifest gives no contract one of IMD's own protocol addresses (the launcher LARPLinks reads parked launch #1395).
The launch's two contracts (src/place/PlaceLARP.sol) take no such argument: they create the burner, the registry, IMD
Names and the links by CREATE3 through CreateX (0xba5E…ba5Ed), where an address depends only on a salt, not on the
code. So the burner and IMD Names can each be made with the other's address, and the plan holds however the launch is
compiled. This mines the salts (each address starts 0x6900…) and writes src/place/LARPPlan.sol; test/Placement.t.sol
checks the plan follows from the salts and, on an Ethereum fork, that the launch lands there.

  python3 script/place/gen.py [prefix, 6900] [--remine]

The salts already in LARPPlan stay unless --remine. Code changes don't move the addresses; the salts are the plan.

A salt here is one no sender owns, for CreateX: its first 20 bytes are random (not a caller, not zero), byte 21 is 0,
so CreateX guards it as keccak256(abi.encode(salt)) for every caller on every chain. And it holds no 0xf2, 0xf4 or 0xff
byte: IMD's admission scan reads code as instructions, and a compiler may keep a salt as raw data.
"""
import os, re, sys
from Crypto.Hash import keccak

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "../.."))
CREATEX = "0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed"
PROXY = bytes.fromhex("67363d3d37363d34f03d5260086018f3")
A = {  # the four's constructor arguments (README's launch table)
    "POOL_MANAGER": "0x000000000004444c5dc75cB358380D2e3dE08A90",  # Uniswap v4
    "IMD": "0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7",  # $IMD
    "POOL4_HOOK": "0xc6C965Bd164c483e87d0B550671798e9A3602840",  # POOL4's hook (ETH/$IMD)
    "IMD6900": "0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F",
    "PAIR_HOOK": "0x667f4621030aCfAfb1bD0B64d33610A8567f2A44",  # the IMD6900/$IMD pool's hook
    "IDENTITY": "0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D",  # identity.md
    "ARTIST": "0x35dA9C0303507ddf708E87F2568EdDf12c47a059",  # the names' artist
    "INTAKE": "0xa43e6F75ee006411F79Ac1C84120606C2330DE82",  # IMD's oracle Intake (v2)
    "ORACLE_SIGNER": "0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982",  # IMD's oracle attester
    "LAUNCHER": "0xfF03410d0Fe5fa8f7F59F743de35E333D9857120",  # IMD's launcher (distributorOf: the jeet board)
}
N = {"POOL4_FEE": 10_000, "POOL4_SPACING": 60, "BACKUP_FEE": 10_000, "BACKUP_SPACING": 200, "PAIR_FEE": 0, "PAIR_SPACING": 60}
ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
PREFIX = (ARGS[0] if ARGS else "6900").lower()


def k(b):
    h = keccak.new(digest_bits=256)
    h.update(b)
    return h.digest()


PROXY_HASH = k(PROXY)


def checksum(addr_hex):
    a = addr_hex.lower().replace("0x", "")
    h = k(a.encode()).hex()
    return "0x" + "".join(c.upper() if c.isalpha() and int(h[i], 16) >= 8 else c for i, c in enumerate(a))


def at(salt):
    """CreateX's CREATE3 for a salt no sender owns: guarded = keccak(abi.encode(salt)); proxy = CREATE2(CreateX,
    guarded, proxy code); the contract = the proxy's first CREATE"""
    g = k(salt)
    proxy = k(b"\xff" + bytes.fromhex(CREATEX[2:]) + g + PROXY_HASH)[12:]
    return k(b"\xd6\x94" + proxy + b"\x01")[12:].hex()


BAD = {0xF2, 0xF4, 0xFF}


def good(salt):
    return salt[20] == 0 and any(salt[:20]) and not (BAD & set(salt))


def kept(name):
    try:
        m = re.search(name + r"_SALT = 0x([0-9a-fA-F]{64});", open(os.path.join(ROOT, "src/place/LARPPlan.sol")).read())
    except FileNotFoundError:
        return None
    if m and "--remine" not in sys.argv:
        s = bytes.fromhex(m.group(1))
        if good(s) and at(s).startswith(PREFIX):
            return s
    return None


def mine(name):
    s = kept(name)
    while s is None:
        c = bytearray(os.urandom(32))
        c[20] = 0
        c = bytes(c)
        if good(c) and at(c).startswith(PREFIX):
            s = c
    return s


def main():
    salts = {n: mine(n) for n in ("BURNER", "LARP", "NAMES", "LINKS")}
    addrs = {n: checksum(at(s)) for n, s in salts.items()}
    plan = "\n".join(
        [f"    address internal constant {n} = {checksum(v)};" for n, v in A.items()]
        + [f"    uint24 internal constant {n} = {v};" for n, v in N.items()]
        + [f"    bytes32 internal constant {n}_SALT = 0x{s.hex()};" for n, s in salts.items()]
        + [f"    /// @notice where it lands on Ethereum (any chain with CreateX, unless its salt was used first)\n    address internal constant {n}_AT = {a};" for n, a in addrs.items()])
    open(os.path.join(ROOT, "src/place/LARPPlan.sol"), "w").write(f"""// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title LARPPlan - what LARP's four contracts are made with, and where they land
/// @notice GENERATED by script/place/gen.py: never edit by hand. The salts are mined so every address starts 0x{PREFIX}…;
///         the addresses follow from them and CreateX's CREATE3 alone, whatever the code.
library LARPPlan {{
    /// @notice CreateX, the CREATE3 factory (the same address on every chain it is on)
    address internal constant CREATEX = {CREATEX};
{plan}
}}
""")
    for n in salts:
        print(f"{n:7} {addrs[n]}  salt 0x{salts[n].hex()}")


if __name__ == "__main__":
    main()
