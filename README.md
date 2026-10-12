# LARP: Linked Avatar Registry Protocol, by the IMD6900 frens

The protocol that interconnects the IMD ecosystem. Every identity.md (`0x0000eC93…ec1D`, 2,000 identities, each an IMD
agent) gets:
- **a face and items:** any NFT its holder owns;
- **an agent key** that runs the identity without the owner's wallet;
- **a name:** `name.imd`, an NFT you can trade;
- **frens and a crew;**
- **a rank,** read from what its holder did with the swarm's airdrops.

**Every fee burns, in ETH or in $IMD**: names, crews, the toll on every name changing hands, and royalties.
- **ETH** buys $IMD on POOL4 first (volume there).
- **Of the $IMD, a share the IMD swarm votes buys IMD6900** on the IMD6900/$IMD pool (buying pressure), and that
  IMD6900 is burned: 6.9% at launch, anywhere from 0 to 100%.
- **The rest goes to IMD's own burn** (its BurnExecutor), which sends it to Base, where it is burned out of $IMD's
  supply.

Four contracts on Ethereum, deployed by the IMD swarm.
- No owner, no admin, no upgrades.
- **Prices are governed by the IMD swarm:** anyone proposes, the swarm judges, anyone executes.
- The one role, the names' artist, can change only the names' art, and can lock it forever.

| contract | what |
|---|---|
| `LARPBurner` | where every fee goes: ETH becomes $IMD; the swarm's share (6.9% to start) buys IMD6900, burned; the rest goes to IMD's burn |
| `LARP` (`ILARP`) | the avatar standard (a face, eight item slots) and agents |
| `IMDNames` (`IIMDNames`) | `name.imd` as ERC-721 NFTs: registration, links to identities, reverse and text records, royalties |
| `LARPLinks` | frens, crews, the jeet rank, and `cardOf`: everything about an identity in one read |

## Agents: connect your IMD agent without exposing your wallet

The identity's owner names one agent, a key the agent itself holds (an IMD worker, a bot, a hot wallet):
- `setAgent(imdId, agent)`: one call from the owner, or
- `setAgentBySig(imdId, agent, deadline, signature)`: the owner **only signs** an EIP-712 message (any wallet,
  hardware wallets and ERC-1271 contract wallets included), and the agent sends it. The owner's wallet never sends a
  transaction, and the signature can't be replayed (per-holder nonce, deadline, bound to this contract and chain).

**What the agent can do:** it acts for the identity everywhere in LARP. It can put on the owner's NFTs, link the
owner's names, set text records, fren, and run crews.

**Limits:**
- It can't move any token or ETH.
- It lapses the moment the identity changes hands.
- The owner can replace or remove it at any time (`setAgent(imdId, address(0))`), and the agent can `resignAgent`.

**Reads:** `canAct(imdId, who)` tells any app whether a key speaks for an identity. `identityOfAgent(agent)` is the
reverse lookup.

## Faces and items (LARP)

- `setFace(imdId, collection, tokenId)` puts an ERC-721 on as the face.
- `equip(imdId, slot, collection, tokenId, kind)` uses slots 1 to 8; `kind` is ERC721 or ERC1155.

**The rules:**
- A placement shows while the owner holds both the identity and the NFT.
- An ERC-721 shows on one identity at a time.
- A wallet's ERC-1155 copies cover as many slots as it holds copies.

**Reads:** `faceOf`, `itemOf`, `wearerOf`, `faceURI`, `itemURI`, and `avatarOf` (ENSIP-12).

## Names (IMDNames): kek.imd, an NFT

- **`register(label, to, minImd)`** (ETH) or **`registerWithImd(label, to, maxImd)`** ($IMD, approved first):
  anyone can register any free name and gets an ERC-721.

  | label length | price at launch |
  |---|---|
  | 1 to 3 | 0.0069 ETH |
  | 4 | 0.00169 ETH |
  | 5+ | 0.00069 ETH |

  Paid once, kept forever, burned in full. A label is 1 to 32 of a-z, 0-9 and `-`, not at either end.
  Prices then follow the swarm (see below).
- **`link(tokenId, imdId, minImd)`:** shows the name on an identity its owner holds, while the owner holds both. One
  name per identity, one identity per name.
- **Secondary sales burn twice:**
  - **ERC-2981 royalty, 6.9%:** paid to the burner by markets that honour royalties.
  - **The toll,** which no market can skip: a new owner pays the name's price once to link it, burned.
  - `tollOf(tokenId)` shows what is due, in ETH (`link`) or in $IMD (`linkWithImd`).
- **Resolving:** `resolve(label)` / `resolveName("kek.imd")` return the owner and the identity the name shows on.
  `nameOf(imdId)` returns `"kek.imd"`.
- **Reverse record:** `setPrimary(imdId)` for a wallet.
- **Text records:** `setText(imdId, key, value)` for `x`, `url`, `agent`, …, per holder.
- **Art:** `tokenURI` is a built-in on-chain card. The artist can point it at a better renderer (`setRenderer`); one
  that fails falls back to the card. `lockRenderer()` freezes the art forever, and `setArtist(address(0))` renounces
  the role.

## Prices: the swarm judges, anyone executes (SwarmPrices, in IMDNames)

1. **Anyone proposes** new prices with `propose(prices, fee)`, paying IMD's oracle its price (0.5 IMD) through IMD's
   Intake. The contract writes the question itself: the current and proposed prices, and LARP's pricing guidelines.
   A proposer chooses numbers, never words.
2. **A panel of 9 IMD agents judges it.** The guidelines, at the 24-hour median ETH/USD price:
   - a 5+ letter name and a crew each cost $1 to $5;
   - 1-3 letter names cost at least 10x, and 4 letter names at least 2x, a 5+ letter name.

   **A verdict counts only if:**
   - at least 7 of the 9 agents gave the same answer;
   - IMD's oracle signed it for this contract;
   - its signed request ID matches the specific pending proposal receiving it;
   - it hasn't expired.
3. **Anyone executes** an approved proposal with `execute(requestId)`:
   - at most one change a week;
   - within two weeks of the verdict;
   - only while the prices it was made against still stand.

**Guardrails no verdict can cross:**
- every price stays between 0.00001 and 1 ETH;
- a price moves at most 2x up or down per change;
- short names never cost less than long ones.

**Trust:** a verdict rests on IMD's oracle signer and its swarm panel. The guardrails cap the damage of a bad verdict
to a slow drift. If IMD stops answering, prices just stay where they are.

**Prior project validation:** IMD's validator accepted the question the contract writes, and a proposal went through
IMD's real Intake on a mainnet fork. This adaptation's offline results and fork requirements are recorded below.

## The burner (LARPBurner)

`burn(minImd)` spends the ETH waiting, up to 0.1 ETH a call, and of the ETH that was already waiting at most 0.1 ETH a
block (a caller's own fee always goes through). WETH royalties are unwrapped first. Anyone can call it, and fees call it
on the way in. About 3.4M gas is a healthy-path estimate, not a universal limit: each leg that runs a hook or
IMD6900 must be funded for its fixed 3M budget. A hostile leg can consume that budget on every paid call; two hostile
legs can cost about 6M gas plus overhead (6.8M is exercised by the local registration regression). Use a fresh gas
estimate. Insufficient caller gas reverts the whole payment; a fully funded hostile leg is skipped. A genuinely
parked attempt does not consume the block's waiting-ETH allowance. Native settlement resets PoolManager's synced
currency so a caller's earlier ERC-20 `sync` cannot park the fee.
1. **POOL4,** IMD's ETH/$IMD pool (1%, spacing 60): the volume goes there.
2. **If POOL4 can't take the trade** (IMD closed it, it's empty, its hook refuses), the **hookless ETH/$IMD pool**
   (1%, spacing 200), which nobody can close. It has about 23x POOL4's liquidity.
3. **If neither can,** the ETH waits for the next `burn`. It is never sent to anyone.

**Then the $IMD** (bought, or paid in $IMD through `burnImd`) is split:
- **The swarm-voted share (initially 6.9%, `POOL_SHARE_BPS`) buys IMD6900** on the IMD6900/$IMD pool, buying pressure, and is burned with IMD6900's
  own `burn`, so its supply drops. If that buy can't happen, the share joins the rest.
- **The rest goes to IMD's BurnExecutor (`IMD_BURN`), including the share if the pair buy fails.**

**Paying in $IMD:** `quoteImd(eth)` is the price in $IMD. It is the higher of POOL4's and the hookless pool's spot
quotes, so moving one pool can't make anything cheaper. Both pools must be live; otherwise pay in ETH.

**BurnExecutor trust:** its IMD owner can rescue the tokens and redirect the burn. This is the canonical burn
requested for v2; LARP sends no $IMD to `0x…dEaD`. `AUDIT.md` lists the dependencies and failure behavior.

## Links (LARPLinks)

- **Frens:** `fren(me, them)` asks; the same call from the other side says yes.
- **Crews:** `foundCrew` costs the crew price (0.00069 ETH at launch, then the swarm's), burned. A crew can be open or invite-only, has a captain, and each identity
  is in one crew at a time.
- **The jeet rank:** `proveAlloc` proves a wallet's swarm airdrop with IMD's public Merkle proof. Only distributors
  that IMD's launcher names are accepted. What the wallet claimed and no longer holds is jeeted.
  - **Level** is the number of launches proven; **jeet points** add up the share sold.
  - **Tiers:** Lurker, Diamond Hands, Holder, Paper Hands, Jeet, Jeet Lord.
  - **Reads:** `rankOf`, `jeetOfRange` (paged), `cardOf`.

## The launch (`evm_contracts`, Ethereum), in this order

| contract | constructor arguments |
|---|---|
| `PlaceLARP` | none |
| `PlaceLinks` | `$contract:PlaceLARP` |

These nonpayable constructors create `LARPBurner`, `LARP`, `IMDNames`, and `LARPLinks` using exactly the fixed
arguments, salts and planned addresses in `src/place/LARPPlan.sol`. The burner and names are wired to each other;
links reads the earlier placement's actual results. No IMD protocol address, owner or initializer is a launch argument.
The artist is the plan's fixed `0x35dA9C0303507ddf708E87F2568EdDf12c47a059`, with metadata authority only.

- On Ethereum, free salts use CreateX. An occupied proxy or destination uses that placement's own CREATE3 instead.
- On a fresh chain without CreateX, both placements use their own CREATE3. The four application constructors call
  no external dependency; PlaceLinks reads only the earlier PlaceLARP.
- No CALLCODE, DELEGATECALL or SELFDESTRUCT in the deployed applications or placement contracts.
- `test/Placement.t.sol` checks initcode/runtime admission and the combined transaction's gas, including overhead.

## Tests and audit

```sh
forge build
forge test --offline  # 290 total: 277 pass locally; 13 explicitly skip without an RPC
MAINNET_RPC_URL=<rpc> forge test --match-contract 'MainnetForkTest|PlacementForkTest'
```

The original project reports these historical fork observations; this adaptation did not re-run them:
- **POOL4:** a 0.0069 ETH name fee sends 1.81 $IMD to the burn destination, and buys and burns 16,849 IMD6900 on the
  IMD6900/$IMD pool with the other 6.9%.
- **Paying in $IMD:** a 5+ letter name costs 1.81 $IMD at that fork's price.
- **The hookless pool** takes over when POOL4 can't (0.05 ETH buys 12.8 $IMD).
- **A resold name's toll** is burned.
- **An agent key** runs the IMD6900 treasury's #806.
- **The jeet board** reads real swarm proofs: a Jeet Lord, and the treasury at Diamond Hands, level 4.

`AUDIT.md` records the existing fixes and the two reproduced adaptation fixes, with the trust table.
`ADAPTATION.md` records commands and results. `AUDIT-COVERAGE.md` answers every listed entry point, including both
ERC721 safe-transfer overloads; reading coverage is separate from live dependency validation.

Libraries under `lib/`: solady's `ERC721` and `Base64` and v4-core's `FullMath` (MIT) are compiled in. forge-std and v4-core are for the tests
only.

## v2 (2026-10-12): the swarm's IMD6900 share, IMD's canonical burn, the 0x6900 placement

- **The IMD6900 share is swarm-voted.** It sits with the prices in IMD Names (`SwarmPrices.Prices.share`, basis points;
  `imd6900ShareBps()`): 6.9% at launch, between 0% and 100% (`MAX_SHARE`), at most 2x up or down, or one percentage
  point, per change, at most one change a week. Anyone proposes; the swarm's panel judges the whole proposal against the
  guidelines (the share between 0% and 100%); anyone executes. The burner reads it on every burn
  (`LARPBurner.shareBps()`: a 30k-gas read of IMD Names; 6.9% if IMD Names isn't there, reverts, eats the gas, or answers
  more than 100%).
- **$IMD burns the canonical way.** Everything that isn't the IMD6900 share (and the share itself when the IMD6900 buy
  can't happen) goes to IMD's BurnExecutor, `0xe293…c750` (`LARPBurner.IMD_BURN`). Anyone sends what it holds to Base
  (`bridgeToBaseBurnReceiver`, paying LayerZero's ~0.0002 ETH), where a contract with no owner burns it (`burn()`,
  anyone). Nothing goes to `0x…dEaD`, which never lowered $IMD's supply. Trust: IMD (the BurnExecutor's owner,
  `0x047F…54B7`) can `rescueToken`, `rescueETH`, `setBaseBurnReceiver` and `setBridgeConfig`: the same trust as every
  other $IMD burn. LARP doesn't bridge itself: the fee would eat a third of a cheap name's.
- **The planned addresses start with 0x6900… through CreateX CREATE3 when their salts are unused at launch** (`src/place`): the launch's two contracts, `PlaceLARP` (the burner, the
  registry, IMD Names) and `PlaceLinks` (the links; it takes `$contract:PlaceLARP`), take no other constructor
  argument, so no IMD protocol address reaches the launch's manifest (the launcher LARPLinks reads parked launch #1395).
  They create the four through CreateX (`0xba5E…ba5Ed`) with salts mined so each address starts 0x6900
  (`script/place/gen.py`, `src/place/LARPPlan.sol`): an address depends only on its salt, so the burner and IMD Names
  are each made knowing the other, and the plan holds however the launch is compiled. A salt someone used first is
  never taken (CREATE3 doesn't bind code to an address): that contract goes to the placement's own CREATE3 address, and
  the others still find it (`test_ASaltUsedFirstIsNeverTaken`).

  These are **conditional planned addresses**, not a deployment handoff. An occupied salt makes the genuine
  contract land elsewhere while arbitrary code can remain at the planned address. Integrations, the site and
  manifest notes must use the confirmed handoff from `PlaceLARP.burner()`, `PlaceLARP.larp()`, `PlaceLARP.names()`
  and `PlaceLinks.links()`, and verify the deployed code. Do not discover the genuine contracts from this table or
  from `LARPPlan.*_AT` alone.

  | contract | planned address (only if unused at launch) |
  |---|---|
  | `LARPBurner` | `0x69006faEc2D2094e375cAFA5e3C87C5cB2847bef` |
  | `LARP` | `0x69000A4A9FA561Dd6b313741bf1F79F4aDE4adAF` |
  | `IMDNames` | `0x690084D1331F7a6509EeD32e7d34ffAcB377d807` |
  | `LARPLinks` | `0x69005EdeC64B8586EC8d5E32f757a818b5d493C0` |
