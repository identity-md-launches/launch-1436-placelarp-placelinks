# LARP audit (2026-10-12, before the swarm launch)

Scope: `src/` at this commit: `LARPBurner`, `LARP` / `ILARP`, `IMDNames` / `IIMDNames` with `SwarmPrices`,
`LARPLinks`, `SafeReads`, `Labels`. Four contracts on Ethereum.
- No owner, no admin, no upgrades.
- The one role is the names' **artist**, who can change only the art (tokenURI's renderer) and can lock it forever.

**Adaptation review:** the supplied audit's native-settlement issue (medium, L-14) and cross-proposal verdict issue
(low, L-15) reproduced and are fixed below. The independent review's reopened findings, the uncapped IMD6900 leg at a
high share (medium, L-16) and a payer's `minImd` met by the waiting ETH (low, L-17), reproduced and are fixed below.
Existing fixes L-01, L-02 and L-09–L-11 remain in place. See `ADAPTATION.md` for current command results and
`AUDIT-COVERAGE.md` for every entry-point answer. The current suite contains 296 tests: 283 pass offline and 13
require a mainnet RPC and explicitly skip without it. The 13 fork tests passed against a public Ethereum RPC on
2026-10-12 (block ~26,178,000), with the capped leg buying and burning real IMD6900.

## Trust: what LARP depends on, and what happens if it fails

| dependency | who controls it | if it fails or turns hostile |
|---|---|---|
| identity.md `0x0000eC93…` | its contract | inherent: LARP is about these tokens |
| Uniswap v4 PoolManager | nobody (immutable) | — |
| POOL4 (ETH/$IMD 1%, hook `0xc6C9…`) | IMD's treasury owns the hook (it can `closeMarket`) | the burner falls to the hookless route (route 1); a hostile hook can consume its entire 3M budget on every ETH-paid call before fallback (L-09) |
| hookless ETH/$IMD pool (1%, spacing 200) | nobody (no hook); its LPs can withdraw | the ETH waits in the burner; anyone burns it later |
| IMD6900/$IMD pool (hook `0x667f…2A44`) | the IMD6900 ETH timelock owns the hook | the swarm-voted share (initially 6.9%) goes to IMD_BURN as $IMD instead; a hostile pair hook can consume the pair leg's 3M budget on every paid call. One call sells the pool at most 2% of its $IMD depth (L-16), sized against the hook's 6.9% fee each way: if the hook's owner lowered that fee below ~1%, a leg at the cap would become worth sandwiching again, and the share should be voted down |
| IMD6900 (`0x0000198C…`, upgradeable) | the IMD6900 ETH timelock | if its `burn` refuses, or eats all the gas it is given (a hostile or buggy upgrade), the share goes to IMD_BURN as $IMD; the leg can consume its 3M budget on every paid call. With both budgeted legs hostile, allow roughly 6M plus overhead and estimate gas afresh (L-09) |
| WETH9 (`0xC02a…6Cc2`, immutable) | nobody | royalties paid in WETH are unwrapped on each `burn`; if WETH refused, they would wait there |
| $IMD (LayerZero OFT, owner `0x047F…`) | IMD's treasury (peers) | $IMD is forwarded to IMD's BurnExecutor, whose owner can rescue or redirect it; bridging/burning depends on IMD's system |
| IMD's launcher `distributorOf` | immutable contract; IMD writes the airdrop roots | jeet ranks are only as true as IMD's airdrops; nothing else depends on it |
| the names' renderer | the artist, until locked | art only; a failing renderer falls back to the built-in card |
| IMD's oracle (attester `0x5598…2982`, Intake `0xa43e…de82`, owned by IMD's treasury) | IMD | price changes only. A verdict needs its signature, for this contract, on the contract's own proposal; a bad one can move prices at most 2x a week, within 0.00001-1 ETH and short >= long. If IMD stops answering, prices stay. |

**Used since v2 (2026-10-12), at the user's choice: IMD's BurnExecutor (`0xe293…c750`, `LARPBurner.IMD_BURN`).**
Its owner (IMD, `0x047F…54B7`) can `rescueToken`, `rescueETH`, `setBaseBurnReceiver` and `setBridgeConfig`, so $IMD
sent there is burned on IMD's word, as every other $IMD burn is: anyone bridges what it holds to Base, where a contract
with no owner burns it. `0x…dEaD` was trustless but never lowered $IMD's supply.

## Fixed

### L-01 A fee could skip its route by starving the swap of gas (LARPBurner)

Each route's swap runs in a try. A swap that runs out of gas inside it keeps 1/64 of the gas, so a caller who could
make the swap eat its 63/64 could skip POOL4 for the backup, or park the fee.

**Fix, as it stands (third version, with L-09):** a leg is skipped only for a failure of its own, never for the gas
the caller sent.
- The legs that run code a third party controls (route 0 through POOL4's hook; the IMD6900 leg through the pair hook
  and IMD6900's proxy) run on a fixed budget, `LEG_GAS` = 3M, several times the heaviest leg measured (~800k). Unless
  the call can fund the whole budget (3M, plus the 1/64 EIP-150 keeps, plus 150k for what follows) it is refused with
  `TooLittleGas` before the leg runs, so the leg gets the same gas whatever the caller sent. A leg that spends all of
  it failed on its own account and is skipped like any other refusal (L-09).
- The hookless route runs only the immutable PoolManager and $IMD, so it gets all the gas, and a failure that left no
  more than 1/4 of it ran out of gas and reverts the call (an out-of-gas d frames deep hands back about d/64 of the
  gas; a genuine revert hands back nearly all).

The first version drew the line at 1/63 for every leg, which is what is left when the PoolManager itself runs out of
gas. The launch audit (2026-10-12) showed that is not where the work runs: the swap, the hook, the token transfers and
IMD6900's `burn` are two to five frames below the burner, and every frame in between keeps 1/64 of its gas and hands
it back when it reverts, so an out-of-gas that deep left the burner 3/64 to 5/64 of the gas. The 1/63 guard passed,
the leg counted as failed, and with a heavy IMD6900 leg (~800k gas) every gas limit from ~758k to ~1.97M went through
with the IMD6900 buy skipped. The second version drew the line at 1/4 for every leg; the launch review showed that a
leg which eats all the gas it is given, at any limit, then always looks starved, so one hostile upgrade of IMD6900 (or
of a hook) made every burn revert `TooLittleGas` and halted every paid entry point (L-09). The budget settles both: a
caller can't starve a leg, and a leg can't hold the burner hostage.

**Healthy-path cost:** a burn needs a gas limit of about 3.35M (measured locally: 3.31M for POOL4 plus the IMD6900 leg, 3.21M for
`burnImd`), and so do `register`, `link`, `foundCrew` and their $IMD twins; `eth_estimateGas` finds it, since above the
threshold the outcome no longer depends on the limit. The healthy path uses much less gas than its required limit. A hostile leg can spend essentially its whole 3M
budget on every payment. If POOL4's hook consumes its budget, funding the later pair leg needs about another 3.2M
plus overhead; with both hostile, about 6M gas is consumed. `test_HostileLegsCostPaidCallsTheirBudgets` exercises
registration at 6.8M (6,026,491 gas consumed locally) and rejects 3.4M atomically. This cost persists until the dependency recovers. The share can
reach zero via four approved steps from 690 bps (345, 173, 87, 0), subject to weekly cooldown; route 0 has no disable
switch. A refused call moves nothing; 3.4M is not a universal payment limit.

**Tests:**
- `test_ASwapOutOfGasReverts` (a PoolManager that burns all gas): route 0 spends its budget and is skipped, the
  hookless route runs out and the call reverts; below the budget it is refused before trying.
- `test_NoGasLimitSkipsARoute` sweeps gas limits from 100k to 4.5M: the backup pool's price never moves while POOL4
  can take the trade, and no call that goes through skips the IMD6900 buy.
- `test_AnIMD6900LegOutOfGasDeepDownReverts` (an IMD6900 whose `burn` costs ~800k gas): refused at 1M and at 3.2M
  (POOL4's leg funded, the IMD6900 leg not), with the ETH handed back; buys and burns at 5M.
  `test_NoGasLimitSkipsAHeavyIMD6900Leg` sweeps 2.5M to 5M: every call buys IMD6900 or is refused, and both occur.
- `test_AGenuineFailureIsNotMistakenForTooLittleGas`: an empty pair pool's genuine revert is skipped at 5M gas and
  the call is refused, not degraded, at 300k.

### L-02 The jeet board's reads grow without bound (LARPLinks)

`jeetOf` reads every proven launch of a wallet. **Fix:** `jeetOfRange(wallet, start, count)` pages it.
**Test:** `test_JeetsInPages`.

### L-09 A gas-eating IMD6900 or hook halted every burn (LARPBurner; launch review, rated medium)

With the 1/4 guard on every leg, an IMD6900 whose `burn` (behind its proxy, one upgrade away) or a hook that eats all
the gas it is given made the catch see at most 1/64 of the gas at any limit, so `burn` and `burnImd` always reverted
`TooLittleGas`, and with them `register`, `registerWithImd`, `link`, `linkWithImd`, `foundCrew` and `foundCrewWithImd`,
which have no other payment path and no owner to switch routes. The trust table's promise (a hostile IMD6900 only
costs its share; a hostile POOL4 falls to the hookless pool) held only for a refusal that reverted cheaply.

**Fix:** the legs that run third-party code get the fixed budget described under L-01; a leg that eats all of it is
skipped (the IMD6900 share burns as $IMD; route 0 falls to the hookless pool). **Tests:**
`test_AGasEatingIMD6900IsSkippedNotFatal` (an IMD6900 whose `burn` loops forever: `burn` at 30M gas spends the ETH and
burns all the $IMD, `burnImd` sends everything to IMD_BURN, and 1M gas is refused, not skipped) and
`test_AGasEatingPool4HookFallsToTheHooklessPool` (a v4 hook that loops forever: the fee is bought on route 1).

### L-10 Batched `burn(0)` calls sold all the waiting ETH at one price (LARPBurner; launch review, rated medium)

`MAX_BURN` capped one call, not one transaction: whoever found more than 0.1 ETH waiting (royalties through `receive`,
parked fees, the remainder of a fee above the cap) could wrap ten `burn(0)` calls between a front-run and a back-run on
POOL4 and keep a large share of the value meant for the burn (measured on the test pools: 1 ETH waiting, the searcher
+0.35 ETH, DEAD -51%).

**Fix:** of the ETH that was already waiting, at most `MAX_BURN` leaves per block, over all calls; a caller's own fee
(up to `MAX_BURN`) always goes through in its own call, so no registration is blocked by what others burned. Each call
still spends at most `MAX_BURN`. A sandwich can therefore cover at most one cap per block, which L-04 shows is below
break-even; the searcher's own ETH, if sent as `msg.value`, is burned. **Tests:** `test_BurnCallsBatchedInOneTransactionSellOneCap`
(ten calls in one transaction sell 0.1 ETH, POOL4 moves as for one trade), `test_AtMostMaxBurnPerCallAndPerBlockOfWaitingEth`,
`test_AFeeAlwaysGoesThroughWhateverTheBlockSpent` (a fee in a block whose allowance is spent is bought exactly; a fee
above the cap buys `MAX_BURN` and the rest waits).

### L-11 Royalties paid in WETH were stuck (LARPBurner; launch review)

`royaltyInfo` names the burner, and accepted offers on Seaport and Blur settle in WETH, which the burner (ETH and $IMD
only, no owner, no sweep) could never move. **Fix:** `burn` first unwraps any WETH9 the burner holds (WETH9 is a
constant: constructor arguments did not change), so WETH royalties join the waiting ETH and leave `MAX_BURN` a block.
Where WETH has no code (a test chain) or refuses, nothing happens. **Test:** `test_WethRoyaltiesAreUnwrappedAndSold`.

## Acknowledged

- **L-07 Paying in $IMD uses spot prices.**
  - **The quote:** `quoteImd` charges the higher of the two pools' spot quotes, and needs both pools live (otherwise
    pay in ETH).
  - **Why one pool can't be gamed:** moving POOL4 alone (shallow, concentrated) can never lower the price.
  - **Moving both:** this means moving the hookless pool too (~600 ETH deep). Their 1% fees each way make that cost
    about what it saves, even for a batch of names in one transaction.
- **L-08 Price governance trusts IMD's oracle.**
  - **What it rests on:** a verdict rests on IMD's attester key and its 9-agent panel (7 must agree).
  - **What IMD's writer can do:** it cannot forge a verdict or apply it to another request after L-15. It can
    withhold a verdict or report an unsigned failure; the oracle signer remains trusted to judge the actual question.
  - **The question hash isn't pinned:** IMD computes it off chain (`oracleQuestionHash`), so the binding is the Intake's
    request id, as IMD documents for consumers on the asking chain.
  - **How it was validated:** the contract writes the whole question, and IMD's free quote accepted it (status
    `quoted`). Proposing costs the proposer 0.5 IMD, which IMD's Intake forwards to IMD's treasury.
- **I-11 The IMD6900 buy is small and bounded.**
  - **Size:** at most 2% of the pair pool's own $IMD depth per call (`PAIR_LEG_BPS`, L-16), whatever the swarm's
    share, against the pair pool's 6.9% fee each way, so it isn't worth sandwiching (the break-even is a leg near 10%
    of the depth). At launch that is ~2.5 $IMD against a 6.9% share of a full `MAX_BURN` burn of ~1.7 $IMD, so the
    launch share is never clipped; the rest of a larger share goes to IMD's burn. Before L-16 the bound was only the
    share itself, which v2 lets the swarm raise to 100%.
  - **Where its fee goes:** the pair hook keeps its own 6.9% fee as protocol liquidity.
  - **If it fails:** an empty pair pool, a hook that refuses, an IMD6900 that won't burn, or one that eats all the
    gas it is given, all send the share to IMD_BURN (`test_AnEmptyPairPoolMeansItAllBurnsAsIMD`,
    `test_AnIMD6900ThatWontBurnMeansItAllBurnsAsIMD`, `test_AGasEatingIMD6900IsSkippedNotFatal`).

- **L-03 Name sniping.** A pending `register` can be front-run. There is no commit-reveal, and the sniper pays the full
  price (burned). The site should send registrations through a private mempool.
- **L-04 Sandwiching a burn.** At most `MAX_BURN` (0.1 ETH) is spent per call, and at most `MAX_BURN` of the ETH
  that was already waiting leaves per block however many calls (L-10), below POOL4's ~0.24 ETH sandwich break-even,
  and far below the hookless pool's (23x POOL4's liquidity). Callers can set `minImd`, which floors the payer's own
  part of the sale (L-17), so a quote for the fee is a real floor even when ETH is waiting; the site should pass one.
- **L-12 A proposal that changes nothing (or 1 wei) consumes the week.** `_checkStep` allows `to == from`, so anyone
  can propose the current prices; the swarm judges guideline compliance, which they meet, and `execute` then bumps
  the epoch and restarts the cooldown: every other approved proposal is `Stale`, and a real change waits a week. Cost
  0.5 IMD a week. Acknowledged, not changed: rejecting identical prices would leave the 1-wei proposal, and a minimum
  step would leave a weekly ping-pong, because the root is the design, in which the swarm judges whether prices are
  acceptable, not which proposal is best, so among approved proposals the first executed wins the week. Every price
  such a griefer can set is one the swarm found within the guidelines, prices never leave the guardrails, and the stall
  is one week per 0.5 IMD. The site should execute an approved proposal in the block it becomes executable.
- **L-13 A fee above `MAX_BURN` is bought in parts.** `MAX_PRICE` (1 ETH) is above `MAX_BURN` (0.1 ETH), so after
  four swarm-approved doublings of a price (outside the stated guidelines at today's ETH price, but possible) a fee is
  bought `MAX_BURN` at a time: the payer's `minImd` covers the first `MAX_BURN`, and the rest waits and leaves
  `MAX_BURN` a block through anyone's `burn(0)`, each below L-04's break-even. Acknowledged, not changed: capping
  `MAX_PRICE` at `MAX_BURN` would cap 1-3 letter names, whose guideline has no upper bound, and buying the whole fee
  in one call or in a loop would recreate L-10's exposure on the payer's own fee. The site should quote `minImd` for
  `min(price, MAX_BURN)`; `burn`'s NatSpec says so.
- **L-05 The rank reads live balances.** A flash loan inside one transaction can make a wallet look like it holds.
  `rankOf` is for display; a contract that pays on rank must snapshot it.
- **L-06 Royalties are voluntary on markets.** ERC-2981's 6.9% reaches the burner only where markets pay royalties.
  What no market can skip is the toll: a name's new owner pays its price once to link it to an identity, and that is
  burned.
- **I-01 An agent has the identity's whole social hand.** It can place the owner's NFTs, link the owner's names, set
  texts, fren, and run (or disband) the owner's crews. It can't move any token or ETH. The owner revokes it, and a
  sale ends it.
- **I-02 A returning identity brings its agent back.** If the owner who named an agent sells the identity and buys it
  back, the agent is live again. So is any unused agent signature still before its deadline (`test_AnAgentLapsesOnASale`).
- **I-03 The toll counts every change of hands,** including moves between the owner's own wallets.
- **I-04 The artist's renderer can show anything** in a name's metadata (it is still only metadata). Lock it when the
  art is final.
- **I-05 Fake collections.** LARP proves what a collection's `ownerOf` / `balanceOf` answers, as ENS avatars do.
- **I-06 Hybrid tokens** (both `ownerOf` and `balanceOf(account, id)`) can be placed once each way.
- **I-07 Views forward all gas to collections the holder chose.** On-chain consumers should cap gas.
- **I-08 Prices are in ETH.** They change only through the swarm, within the guardrails.
- **I-09 Hook launches can't be proven.** IMD's v4-hook launcher has no `distributorOf`.
- **I-10** ETH force-sent to LARP, IMDNames or LARPLinks (no `receive`) stays there; the burner has one and burns it.
  WETH sent to the burner is unwrapped and burned too (L-11); any other token sent to the burner stays there.

## Checked and holding

- **6.9% buys IMD6900, and it is burned.**
  - **Where it buys:** the IMD6900/$IMD pool, through the real hook's per-trade IMD6900 allowance.
  - **How it burns:** with IMD6900's own `burn`, so the supply drops.
  - **On the fork:** a 0.0069 ETH name fee burned 16,849 IMD6900 and sent 1.81 $IMD to the then-configured burn destination.
  - **Gas:** across gas limits, no call skips the IMD6900 buy, even when the leg is heavy: the leg runs on a fixed
    budget, and a call that can't fund it is refused (`test_NoGasLimitSkipsARoute`,
    `test_NoGasLimitSkipsAHeavyIMD6900Leg`). A leg that eats its whole budget is skipped, not fatal (L-09).
- **The burner's ETH leaves only as a swap.** The sale is exact or nothing; a partial fill reverts the route. $IMD
  goes only to IMD_BURN unless spent buying IMD6900. Only the PoolManager calls back, and only for the burner's own unlock. A transient lock
  refuses a burn inside a burn (`test_NoReentry`). Of the ETH already waiting, at most `MAX_BURN` leaves per block
  (L-10).
- **Agent signatures** use EIP-712 over (identity, agent, holder, nonce, deadline), bound to the chain and contract.
  - Malleable (high-s) signatures are refused.
  - A per-holder nonce, bumped by every agent change, voids unused signatures.
  - Contract wallets sign through ERC-1271.
  - An EOA path is tried first, so EIP-7702 accounts work.
  (`test/LARPAgents.t.sol`.)
- **Names.**
  - Two-way links: one name per identity, one identity per name.
  - Live only while the linker owns both.
  - The toll is due whenever the owner isn't the one who last paid.
  - A broken, gas-hungry or code-less renderer falls back to the card.
  (`test/IMDNames.t.sol`, including payments in $IMD.)
- **Swarm prices.** All checked in `test/SwarmPrices.t.sol`:
  - **Signatures:** IMD's EIP-712 `OracleAttestation`, domain "IdentityMD Oracle" v2, for this contract. The callback's
    parameters are IMD's; its name is this contract's: `onVerdict`, selector `0x8bf09c1b`, which `propose` registers
    with the Intake (IMD's example name `onOracleResult` with the same parameters would be `0x510379c7`).
  - **Refused:** another key, another contract, a tampered signature, a weak panel (under 9, quorum under 7, fewer
    agreed than the quorum, under 7 in 9), and an expired verdict.
  - **Callbacks:** only from the Intake, and only for the contract's own proposals.
  - **Execution:** one change a week, stale after another change, within two weeks of the verdict, once.
  - **On the fork:** the real Intake path (`test_APriceProposalThroughIMDsRealIntake`).
- **Merkle proofs** and **placement bookkeeping** as before (`test_AnInnerNodeIsNotALeaf`, three invariants).
- **Launch constraints.** The four application constructors call nothing; the placements call CreateX when present
  and PlaceLinks reads the earlier PlaceLARP. No CALLCODE / DELEGATECALL / SELFDESTRUCT appears in their scanned code.
  The four underlying contracts are checked in `test/Launch.t.sol`; `test/Placement.t.sol` checks the actual two
  placements, their embedded creations, fresh-chain fallback, occupied salts and full transaction bounds. Its test
  helper uses real CREATE so Foundry test linking cannot omit constructor gas from the measurement.

## v2 (2026-10-12)

- **The IMD6900 share is swarm-voted** (IMD Names' `SwarmPrices`, with the prices: 6.9% to start, 0-100%, at most 2x or
  one point per change, one change a week). The burner reads it with a 30k-gas staticcall and falls back to 6.9% if IMD
  Names is missing, reverts, eats the gas or answers more than 100% (`test_TheBurnerFallsBackTo6Point9`). At 100% all
  of a burn is the share, but one call sells the pair pool at most 2% of its $IMD depth and the rest reaches IMD's burn
  (L-16); at 0% nothing buys IMD6900 (`test_UpToAllOfIt`, `test_AndDownToNothing`).
- **$IMD goes to IMD's BurnExecutor**, not `0x…dEaD` (above). The trust table uses the v2 beneficiary.
- **Placement by CREATE3** (README, v2): no IMD protocol address is a launch constructor argument; a salt used first is
  never taken (`test_ASaltUsedFirstIsNeverTaken`); a chain without CreateX gets the placements' own CREATE3
  (`test_DeploysOnAFreshChain`).
- **Tests:** 296 total, with the current offline/fork split recorded above. Fork checks cover the real CreateX and
  a name burning the canonical way when an RPC is supplied. The fuzz seed remains fixed at `0x6900` in foundry.toml.


## Adaptation fixes (this review)

### L-14 Permissionless ERC-20 sync could park native fees (medium)

Reproduced the supplied `ecb342033999…` proof against the arriving code: pre-syncing IMD and then calling `burn`
or `register` in one external helper frame parked ETH despite liquid pools. Separate top-level Forge calls are
insufficient to reproduce transaction-scoped transient state. Both proof tests failed before the fix and pass after.

`LARPBurner.unlockCallback` now calls `POOL_MANAGER.sync(address(0))` immediately before native settlement on both
ETH routes. `burn` charges the waiting-ETH block allowance only after a successful route, so a genuinely parked
attempt cannot prevent a later successful retry in the same block. The existing transient lock covers the change.
`test/LARPBurnerSettlement.t.sol` covers both routes, POOL4 priority, all three ETH fee paths, the pair split,
minimum-output rollback, and retry after liquidity returns. Per-call/per-block caps and caller gas rejection remain.

### L-15 An oracle verdict could approve an unrelated proposal (low)

Reproduced the supplied `1a161ad00bdd…` proof: the same valid signature approved proposals A and B. `onVerdict` now
requires the signed `a.requestId` to equal its callback `requestId`, otherwise reverting with the existing
`BadVerdictSignature` error before any status or timestamp changes. Signature format and callback ABI are unchanged.

Governance tests now sign their actual proposal IDs. The published signature vector is preserved byte-for-byte;
the test Intake returns that vector's fixed request ID. Regressions cover replay across pending proposals with
different prices/share, arbitrary mismatched IDs, tampering, valid retry, and one-time settlement. Weak/expired/wrong-chain
verdict behavior and the weekly guardrails remain unchanged.

### L-16 The IMD6900 leg sold the whole share into the pair pool at any price (medium; reopened review)

Reproduced the reviewer's proof (`Proof_22bc735e0861`): a hookless 6.9%-fee pair at 10,000 IMD6900 per $IMD with
~1,000 $IMD of virtual reserve, the share at 10,000 bps (what four approved proposals reach: 690 → 1380 → 2760 →
5520 → 10,000, `test_UpToAllOfIt`), 0.1 ETH waiting in the burner. An attacker that buys IMD6900 with 500 $IMD, calls
`burn(0)` (0.1 ETH → ~198 $IMD, all of it sold into the pair) and sells back ended +40.6 $IMD. `_burnImd` sold
`held * shareBps() / 10_000` in one exact-input swap to the price limit with no size bound; `MAX_BURN` never applied
on the $IMD path, and the swarm's question only asked whether the share is between 0% and 100%, which `_checkBounds`
already enforces, so one proposer could set it.

**Fix:** `_burnImd` sells the pair pool at most `PAIR_LEG_BPS` (2%) of the pool's own $IMD depth per call: its
virtual $IMD reserve from the liquidity and price the PoolManager holds (`_pairRoom`, read with the same `extsload`
as `quoteImd`), so the leg moves the price by about 2%, far under the ~10% at which a sandwich through the pair's
6.9% fee each way breaks even. What the share makes above the room goes to IMD_BURN, as a failed leg's share does.
The cap scales with the pool: a front-run that deepens the $IMD side raises it only in proportion; a pool with no
liquidity has no room and the leg is not tried. On Ethereum today (block ~26,178,000) the pool holds ~125 $IMD and
0.1 ETH buys ~25, so 6.9% of a full burn (~1.7 $IMD) fits under the cap (~2.5 $IMD): the launch design is unchanged,
and the fork test still buys and burns real IMD6900. A constant in $IMD was rejected: the pool's depth and $IMD's
price move, and a constant would either clip the launch share or stop binding. The swarm's question gains a sixth
guideline for a rising share: the proposed share of what 0.1 ETH buys must be at most 2% of the pair pool's $IMD
depth (defined in the body), so raising the share has a criterion the panel judges, and a rise the pool can't take
is refused rather than pointlessly approved; lowering the share and price-only proposals are unaffected. The step
rule, bounds and cooldown are unchanged. **Tests:** `test/LARPBurnerPairLeg.t.sol` (the sandwich loses at 100%,
at 6.9% and with a small front-run on a 6.9%-fee pair; a full burn at 100% sells exactly the room and the rest
reaches IMD_BURN; the launch share of a full burn is not clipped; the room follows the depth, none for an empty
pool), `test_UpToAllOfIt` (changed: at 100% a 1,000 $IMD burn sells the room and the rest reaches IMD's burn),
`testFuzz_SixPointNinePercentBuysIMD6900AndTheRestBurns` and the burner invariant (the leg takes exactly
min(share, room) or nothing), `test_TheQuestionNamesTheShare` (the new guideline and definition). The reviewer's
proof passes.

### L-17 A payer's `minImd` was met by the ETH already waiting (low; reopened review)

Reproduced: with 0.0993 ETH of royalties waiting, `register{value: 0.00069 ether}(…, minImd = 5 × quote)` went
through, because `burn` sold the fee and the waiting ETH together (0.1 ETH → ~198 $IMD) and compared `minImd` with
the whole. **Fix:** `burn` checks `minImd` against the sender's pro-rata part of the sale, `imd * own / eth`; a call
that sends nothing (a keeper's `burn(min)`) still floors the whole sale. `register`, `link` and `foundCrew` floors are
now the payer's own, as `IIMDNames` promises. **Tests:** `test_MinImdIsCheckedAgainstThePayersOwnFee`,
`test_BurnFloorsTheSendersPartOrTheWholeSaleWhenItSendsNothing`; both failed on the old check.

## Placement publication and coverage

`LARPPlan.*_AT` and README's table are conditional predictions, not authenticated deployments. Existing occupied-salt
fallback remains unchanged and tested. Consumers must use the confirmed placement getters and verify their code.

`AUDIT-COVERAGE.md` records every entry point in the supplied list. Its ABI count is 149 when `receive` and both
safe-transfer overloads are separate (six constructors plus 142 functions plus receive); the brief labels this list
148. All listed entries are covered, ratio 1. Live dependencies and fork results are explicitly separate from this
local source review.
