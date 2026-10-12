# Launch adaptation: entry-point review
Review of all supplied source files, inherited ERC721 entry points, and constructor wiring after the two reproduced fixes. This is an entry-point review, not a claim of line/branch test coverage or a fresh live-chain audit. The supplied security checklist was checked against the actual Solidity and vendored libraries; its redesign suggestions do not override this launch.

**Coverage ratio: 1.** The brief calls its list 148 entry points. Counting its six constructors, 142 public/external functions (including both `safeTransferFrom` overloads), and `receive` individually yields **149/149** ABI entries. Every item in the brief is answered below; none was omitted to force the count to 148. The inherited SwarmPrices constructor is also reviewed as part of IMDNames construction.

Read-only getters never grant authority or move value. Existing fixes L-01, L-02, L-09, L-10 and L-11 remain in place and are exercised by the named suites. L-14 is the native sync/allowance fix; L-15 is the signed request binding; L-16 caps the pair leg at 2% of the pool's $IMD depth per call (an internal constant, `PAIR_LEG_BPS`, so the ABI and this list are unchanged); L-17 makes `minImd` the payer's own floor. Runtime/creation admission and deployment bounds are checked by Placement and Launch.

Live Ethereum dependency state, deployed proxy implementations, Intake writer permissions and current liquidity were not verified in this offline review; fork tests require `MAINNET_RPC_URL`. The fixed deployment addresses come unchanged from the approved plan. BurnExecutor custody and oracle trust remain as documented in AUDIT.md. No Slither or Mythril result is claimed.

## PlaceLARP (4 entries)

Source: `src/place/PlaceLARP.sol`. Relevant tests in `test/`: Placement.t.sol; Launch.t.sol.

| # | Entry point | Review answer: authority, effects and dependencies |
|---|---|---|
| 1 | `constructor()` | Nonpayable, no arguments; creates burner, registry and names using fixed plan values. Predicts both sides of the burner/names dependency; occupied CreateX proxy or destination selects private placement. No persistent authority. |
| 2 | `burner` | Public immutable deployment result; no mutation or funds. Handoff must read this getter, including after a salt was occupied. |
| 3 | `larp` | Public immutable deployment result; no mutation or funds. Handoff must read this getter, including after a salt was occupied. |
| 4 | `names` | Public immutable deployment result; no mutation or funds. Handoff must read this getter, including after a salt was occupied. |

## PlaceLinks (2 entries)

Source: `src/place/PlaceLARP.sol`. Relevant tests in `test/`: Placement.t.sol; Launch.t.sol.

| # | Entry point | Review answer: authority, effects and dependencies |
|---|---|---|
| 5 | `constructor(address)` | Nonpayable, one earlier PlaceLARP address; reads that placement and creates links using the fixed plan. Fresh-chain path depends only on the earlier deployment; no IMD protocol argument or authority. |
| 6 | `links` | Public immutable result; canonical handoff address even when the planned salt was occupied. |

## LARPBurner (23 entries)

Source: `src/LARPBurner.sol`. Relevant tests in `test/`: LARPBurner.t.sol; LARPBurnerEdges.t.sol; LARPBurnerSettlement.t.sol; LARPBurner.invariant.t.sol; SwarmPrices.t.sol.

| # | Entry point | Review answer: authority, effects and dependencies |
|---|---|---|
| 7 | `constructor(address,address,uint24,uint24,address,uint24,uint24,address,uint24,uint24,address,address)` | Nonpayable; validates required addresses and unsigned tick spacings, stores the fixed plan arguments, calls no dependency, assigns no owner. |
| 8 | `receive` | Anyone may send ETH; accepts royalties without starting an external call. Waiting value leaves only through a capped swap. |
| 9 | `BACKUP_FEE` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 10 | `BACKUP_SPACING` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 11 | `IMD` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 12 | `IMD6900` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 13 | `IMD_BURN` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 14 | `MAX_BURN` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 15 | `MAX_SHARE_BPS` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 16 | `NAMES` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 17 | `PAIR_FEE` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 18 | `PAIR_HOOK` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 19 | `PAIR_SPACING` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 20 | `POOL4_FEE` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 21 | `POOL4_HOOK` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 22 | `POOL4_SPACING` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 23 | `POOL_MANAGER` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 24 | `POOL_SHARE_BPS` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 25 | `burn` | Permissionless, payable and transiently locked. Own fee takes priority; waiting ETH is capped per block and charged only after sale. Routes settle native ETH after sync reset; minimum output and caller gas failures revert atomically. `minImd` floors the sender's pro-rata part of the sale (the whole sale when it sends nothing). L-14 and L-17 fixed. |
| 26 | `burnImd` | Permissionless and locked. Splits all held IMD by the bounded names share, and sells the pair pool at most 2% of its own $IMD depth per call (`PAIR_LEG_BPS`, from the PoolManager's liquidity and price; L-16); exact pair spend burns IMD6900, and remainder, excess over the room or failed share goes only to IMD_BURN. |
| 27 | `quoteImd` | Public read; both pools need liquidity. Uses the higher spot quote with FullMath. Two-pool spot manipulation remains the acknowledged L-07 assumption; no state or value moves. |
| 28 | `shareBps` | Public read of names with 30,000 gas. Missing code, failure, malformed size or value above 10,000 returns 690; valid zero and 10,000 remain allowed. |
| 29 | `unlockCallback` | Only immutable PoolManager. Checks exact input and positive output; native routes reset sync, pair route syncs IMD and burns purchased IMD6900. Relies on immutable manager unlock accounting; all failed legs revert their own effects. |

## LARP (22 entries)

Source: `src/LARP.sol`. Relevant tests in `test/`: LARP.t.sol; LARPAgents.t.sol; LARPItems.t.sol; LARPEdges.t.sol; LARP.invariant.t.sol.

| # | Entry point | Review answer: authority, effects and dependencies |
|---|---|---|
| 30 | `constructor(address)` | Nonpayable; rejects zero identity, stores it, calls nothing and creates no owner or custody. |
| 31 | `DOMAIN_SEPARATOR` | Public read; EIP-712 LARP v1 domain includes current chain and this registry, preventing cross-chain and cross-contract replay. |
| 32 | `IDENTITY` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 33 | `SLOTS` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 34 | `agentOf` | Public read; agent authority requires the recorded holder to remain identity owner. Reverse lookup checks the current agent. Returning ownership can restore authority, acknowledged I-02. |
| 35 | `avatarOf` | Public metadata reads; require live placements. Face falls back to identity URI, empty item/ENS avatar returns empty; collections can consume read gas (I-07). |
| 36 | `canAct` | Public read; agent authority requires the recorded holder to remain identity owner. Reverse lookup checks the current agent. Returning ownership can restore authority, acknowledged I-02. |
| 37 | `clearFace` | Recorded placer or current identity controller may remove a placement; item slot bounds and copy/reverse bookkeeping hold. Empty spot is a no-op. |
| 38 | `equip` | Current owner or live agent places holder-owned NFTs; excludes identity collection, enforces item slots and ERC-1155 copy count, updates both placement directions. External collection checks are static; no NFT transfers. |
| 39 | `faceOf` | Public reads verify current ownership of both identity and placed asset; item slot bounds apply. Collection responses are the acknowledged I-05/I-07 trust boundary. |
| 40 | `faceURI` | Public metadata reads; require live placements. Face falls back to identity URI, empty item/ENS avatar returns empty; collections can consume read gas (I-07). |
| 41 | `identityOfAgent` | Public read; agent authority requires the recorded holder to remain identity owner. Reverse lookup checks the current agent. Returning ownership can restore authority, acknowledged I-02. |
| 42 | `itemOf` | Public reads verify current ownership of both identity and placed asset; item slot bounds apply. Collection responses are the acknowledged I-05/I-07 trust boundary. |
| 43 | `itemURI` | Public metadata reads; require live placements. Face falls back to identity URI, empty item/ENS avatar returns empty; collections can consume read gas (I-07). |
| 44 | `nonces` | Public per-holder replay counter; changes only through owner-authorized agent updates or valid signed updates. |
| 45 | `resignAgent` | Only the recorded agent can delete its role; old reverse records are filtered by live reads. No funds move. |
| 46 | `setAgent` | Only the current identity owner; increments that holder nonce and sets or revokes the agent. No token approval or custody is granted. |
| 47 | `setAgentBySig` | Anyone relays current holder signature bound to identity, agent, holder, nonce, deadline, chain and registry. Low-s EOA or ERC-1271 validation; revert rolls nonce back. |
| 48 | `setFace` | Current owner or live agent places holder-owned NFTs; excludes identity collection, enforces item slots and ERC-1155 copy count, updates both placement directions. External collection checks are static; no NFT transfers. |
| 49 | `supportsInterface` | Pure ERC-165 and ILARP interface claims; no state changes. |
| 50 | `unequip` | Recorded placer or current identity controller may remove a placement; item slot bounds and copy/reverse bookkeeping hold. Empty spot is a no-op. |
| 51 | `wearerOf` | Public reads verify current ownership of both identity and placed asset; item slot bounds apply. Collection responses are the acknowledged I-05/I-07 trust boundary. |

## IMDNames (63 entries)

Source: `src/IMDNames.sol`. Relevant tests in `test/`: IMDNames.t.sol; IMDNamesEdges.t.sol; SwarmPrices.t.sol; SwarmPricesEdges.t.sol; SwarmPrices.invariant.t.sol; LARPBurnerSettlement.t.sol.

| # | Entry point | Review answer: authority, effects and dependencies |
|---|---|---|
| 52 | `constructor(address,address,address,address,address,address)` | Nonpayable; stores identity, registry, burner, named artist, Intake and signer. SwarmPrices base validates fixed initial terms without calls. No factory ownership; artist controls metadata only. |
| 53 | `ACTION` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 54 | `BURNER` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 55 | `COOLDOWN` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 56 | `EXECUTE_WINDOW` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 57 | `IDENTITY` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 58 | `INTAKE` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 59 | `LARP` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 60 | `MAX_PRICE` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 61 | `MAX_SHARE` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 62 | `MIN_PANEL` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 63 | `MIN_PRICE` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 64 | `MIN_QUORUM` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 65 | `ORACLE_SIGNER` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 66 | `ROYALTY_BPS` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 67 | `TLD` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 68 | `approve` | Existing token owner or operator sets token approval through vendored ERC721. Cannot alter fees, links or governance. Payable inherited method does not forward accidental ETH (I-10). |
| 69 | `artist` | Public art-role/configuration reads. Artist can change metadata or renounce, never prices, share, balances or burner destination. |
| 70 | `balanceOf` | Public ERC721 reads; ownership/existence/zero-owner checks follow vendored Solady. Approvals convey NFT transfer rights, not identity or governance rights. |
| 71 | `crewPrice` | Public reads of swarm terms; valid labels select price bands, toll is zero only for last-paying owner. IMD6900 share starts at 690 and stays within 0–10,000. |
| 72 | `epoch` | Public governance state reads; epoch invalidates competing proposals after execution, decision time limits execution, count numbers proposals. |
| 73 | `execute` | Anyone executes only an approved, unexpired, current-epoch proposal outside cooldown. Changes terms, increments epoch, records time; cannot exceed proposal guardrails. No-change proposals retain acknowledged L-12 behavior. |
| 74 | `getApproved` | Public ERC721 reads; ownership/existence/zero-owner checks follow vendored Solady. Approvals convey NFT transfer rights, not identity or governance rights. |
| 75 | `identityOf` | Public live resolution/reverse/text reads, checking current holder where relevant. Malformed names resolve absent; a sale invalidates live links and selects the new holder text namespace. |
| 76 | `imd6900ShareBps` | Public reads of swarm terms; valid labels select price bands, toll is zero only for last-paying owner. IMD6900 share starts at 690 and stays within 0–10,000. |
| 77 | `isApprovedForAll` | Public ERC721 reads; ownership/existence/zero-owner checks follow vendored Solady. Approvals convey NFT transfer rights, not identity or governance rights. |
| 78 | `lastChange` | Public governance state reads; epoch invalidates competing proposals after execution, decision time limits execution, count numbers proposals. |
| 79 | `link` | Identity owner or live agent, with same holder owning name; updates both directions and pays exact resale toll. Burner failure rolls back linkage/payment. L-14 regression covers pre-sync. |
| 80 | `linkWithImd` | Same controller/holder/link checks; nonzero toll pulls caller IMD subject to maxImd and burns it. No toll means no payment call. |
| 81 | `lockRenderer` | Only artist irreversibly locks renderer changes; no NFT transfer or payment freeze. |
| 82 | `name` | Public collection metadata/interface identifiers; ERC721/ERC165/ERC2981 and IIMDNames claims only. |
| 83 | `nameOf` | Public live resolution/reverse/text reads, checking current holder where relevant. Malformed names resolve absent; a sale invalidates live links and selects the new holder text namespace. |
| 84 | `nameOfToken` | Pure label-to-name formatting; token existence is checked by consumers that require it. No mutation. |
| 85 | `onNoVerdict` | Only Intake can mark its pending request Failed; unsigned failure cannot approve or execute a change. Oracle can withhold progress (L-08). |
| 86 | `onVerdict` | Only Intake, only pending proposal; signed request ID must match callback ID, with oracle/domain signature verification. Panel, answer, chain and expiry determine approval; mismatches revert without closing proposal. L-15 fixed. |
| 87 | `ownerOf` | Public ERC721 reads; ownership/existence/zero-owner checks follow vendored Solady. Approvals convey NFT transfer rights, not identity or governance rights. |
| 88 | `priceOf` | Public reads of swarm terms; valid labels select price bands, toll is zero only for last-paying owner. IMD6900 share starts at 690 and stays within 0–10,000. |
| 89 | `prices` | Public reads of swarm terms; valid labels select price bands, toll is zero only for last-paying owner. IMD6900 share starts at 690 and stays within 0–10,000. |
| 90 | `primaryOf` | Public live resolution/reverse/text reads, checking current holder where relevant. Malformed names resolve absent; a sale invalidates live links and selects the new holder text namespace. |
| 91 | `proposal` | Public governance state reads; epoch invalidates competing proposals after execution, decision time limits execution, count numbers proposals. |
| 92 | `proposalCount` | Public governance state reads; epoch invalidates competing proposals after execution, decision time limits execution, count numbers proposals. |
| 93 | `propose` | Permissionless, caller pays IMD fee to Intake with exact approval. Contract writes question and checks bounds/step before requesting. The question's six guidelines include a criterion for a rising IMD6900 share (the pair pool's depth; L-16), so a share rise is judged, not only bounded. Trusts fixed IMD token and Intake for fee collection and unique request IDs. |
| 94 | `register` | Permissionless valid unclaimed label, nonzero recipient and exact ETH fee. Mints name before locked burner call; failure rolls back mint and payment. Minimum IMD enforced by burner; L-14 regression covers pre-sync. |
| 95 | `registerWithImd` | Same valid-name mint; caller-approved IMD pays bounded maxImd quote directly to burner, then burnImd. Failure rolls back mint and payment; trusted IMD token and spot quote assumptions apply. |
| 96 | `renderer` | Public art-role/configuration reads. Artist can change metadata or renounce, never prices, share, balances or burner destination. |
| 97 | `rendererLocked` | Public art-role/configuration reads. Artist can change metadata or renounce, never prices, share, balances or burner destination. |
| 98 | `resolve` | Public live resolution/reverse/text reads, checking current holder where relevant. Malformed names resolve absent; a sale invalidates live links and selects the new holder text namespace. |
| 99 | `resolveName` | Public live resolution/reverse/text reads, checking current holder where relevant. Malformed names resolve absent; a sale invalidates live links and selects the new holder text namespace. |
| 100 | `royaltyInfo` | Public quote of 690 bps to immutable burner. Payment is voluntary at marketplaces (L-06); excessive uint256 sale values revert on checked multiplication. |
| 101 | `safeTransferFrom(address,address,uint256)` | Same authorized transfer with state updated before ERC721 receiver callback, reverting if rejected. Both overloads reviewed; callback can exercise only receiver-owned rights. |
| 102 | `safeTransferFrom(address,address,uint256,bytes)` | Same authorized transfer with state updated before ERC721 receiver callback, reverting if rejected. Both overloads reviewed; callback can exercise only receiver-owned rights. |
| 103 | `setApprovalForAll` | Caller changes only its own NFT operator approvals; no protocol admin right. |
| 104 | `setArtist` | Only current artist hands over or renounces the art role. Does not unlock a locked renderer or grant economic authority. |
| 105 | `setPrimary` | Only identity owner sets its wallet reverse record; agent cannot select the owner wallet primary. |
| 106 | `setRenderer` | Only artist and only before lock; external renderer is used by static metadata calls, with fallback on failure. |
| 107 | `setText` | Current owner or live agent changes text under the current holder namespace; previous holders cannot change a new holder record. |
| 108 | `supportsInterface` | Public collection metadata/interface identifiers; ERC721/ERC165/ERC2981 and IIMDNames claims only. |
| 109 | `symbol` | Public collection metadata/interface identifiers; ERC721/ERC165/ERC2981 and IIMDNames claims only. |
| 110 | `text` | Public live resolution/reverse/text reads, checking current holder where relevant. Malformed names resolve absent; a sale invalidates live links and selects the new holder text namespace. |
| 111 | `tokenURI` | Existing NFT only; artist renderer is a gas-capped static call and malformed/empty results fall back to built-in card. No state or funds; renderer trust remains art-only. |
| 112 | `tollOf` | Public reads of swarm terms; valid labels select price bands, toll is zero only for last-paying owner. IMD6900 share starts at 690 and stays within 0–10,000. |
| 113 | `transferFrom` | Owner or approved spender, correct from and nonzero recipient required. Updates ownership/balances and clears token approval. Live links/toll depend on current holder; no fee is bypassed by approval. |
| 114 | `unlink` | Current identity controller or name owner can clear both directions; absent link is a no-op. No value moves. |

## LARPLinks (35 entries)

Source: `src/LARPLinks.sol`. Relevant tests in `test/`: LARPLinks.t.sol; LARPLinksEdges.t.sol; LARPBurnerSettlement.t.sol.

| # | Entry point | Review answer: authority, effects and dependencies |
|---|---|---|
| 115 | `constructor(address,address,address,address,address)` | Nonpayable; rejects missing required addresses and stores fixed identity/launcher plus deployed registry/names/burner. Calls nothing, assigns no owner. |
| 116 | `BURNER` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 117 | `IDENTITY` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 118 | `LARP` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 119 | `LAUNCHER` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 120 | `NAMES` | Public immutable/constant read; fixed at construction or in bytecode. No setter, external call, privilege or value movement; plan/default bounds reviewed. |
| 121 | `allocOf` | Public count/allocation records; cannot forge new roots or move airdrop funds. |
| 122 | `asked` | Public bookkeeping reads; writes occur only through authorized social operations or verified allocation proofs. No value movement. |
| 123 | `cardOf` | Public aggregate of rank, live name/face, crew and frens. Depends on fixed registry/names plus live rank reads; unpaged launch history can increase gas. |
| 124 | `crew` | Public crew data; crewOf returns zero for disbanded crews. No authority or value. |
| 125 | `crewByName` | Public bookkeeping reads; writes occur only through authorized social operations or verified allocation proofs. No value movement. |
| 126 | `crewCount` | Public bookkeeping reads; writes occur only through authorized social operations or verified allocation proofs. No value movement. |
| 127 | `crewOf` | Public crew data; crewOf returns zero for disbanded crews. No authority or value. |
| 128 | `disband` | Only captain controller ends crew, frees its name, zeroes members. Liveness filters stale per-member indices without an unbounded loop. |
| 129 | `foundCrew` | Current controller of crewless identity, unique valid name and exact ETH crew price. State set before burner payment; failure rolls back. L-14 regression covers pre-sync. |
| 130 | `foundCrewWithImd` | Same crew checks; caller-approved IMD pays burner quote subject to maxImd. Failure rolls back crew creation and transfer. |
| 131 | `fren` | Current identity owner or live agent only. Mutual consent creates symmetric friendship/counters; either identity may remove requests or friendship. Social state follows identity transfers. |
| 132 | `frenCount` | Public bookkeeping reads; writes occur only through authorized social operations or verified allocation proofs. No value movement. |
| 133 | `invite` | Only live crew captain controller; invitation target must exist. Changes admission, never token rights or fees. |
| 134 | `invited` | Public bookkeeping reads; writes occur only through authorized social operations or verified allocation proofs. No value movement. |
| 135 | `isFren` | Public bookkeeping reads; writes occur only through authorized social operations or verified allocation proofs. No value movement. |
| 136 | `jeetOf` | Public aggregate over all proven launches; cost grows with history, use jeetOfRange for pages (L-02). Display data, not an economic oracle. |
| 137 | `jeetOfRange` | Public paged aggregation with overflow-safe range clipping, including start past end. Each launch still iterates its proven rounds; L-02 fix retained. |
| 138 | `join` | Identity controller joins a live open/invited crew, only when crewless. Consumes invitation and increments members. |
| 139 | `kick` | Only captain controller removes a member of that crew, excluding the captain. Membership count and identity index remain paired. |
| 140 | `launchCount` | Public count/allocation records; cannot forge new roots or move airdrop funds. |
| 141 | `launchJeet` | Public bounded external reads of recorded distributor claims/token/balance; unreadable balance counts as held. Iterates proven rounds, no token transfers. Trusts launcher/distributor records. |
| 142 | `leave` | Identity controller leaves live crew, except captain; decrements membership and clears identity crew. |
| 143 | `passCaptain` | Only current captain controller chooses an existing crew member. Control follows the captain identity, not a protocol admin. |
| 144 | `proveAlloc` | Permissionless proof for nonzero wallet/amount within uint128; accepts only launcher distributor and valid round root, double-hashed sorted Merkle leaf, once per wallet/distributor/round. Reads are gas capped. |
| 145 | `rankOf` | Public rank for current identity holder; live token balances are flash-loan sensitive display data (L-05). Missing identity yields zero rank. |
| 146 | `setOpen` | Only live crew captain controller; invitation target must exist. Changes admission, never token rights or fees. |
| 147 | `tierOf` | Pure display classification of average jeet points and title; zero level gives Lurker. No rights or transfers. |
| 148 | `titleOf` | Pure display classification of average jeet points and title; zero level gives Lurker. No rights or transfers. |
| 149 | `unfren` | Current identity owner or live agent only. Mutual consent creates symmetric friendship/counters; either identity may remove requests or friendship. Social state follows identity transfers. |
