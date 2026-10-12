# LARP launch adaptation (2026-10-12)

The launch remains exactly two nonpayable factory deployments, in order:

1. `PlaceLARP()` — no arguments.
2. `PlaceLinks($contract:PlaceLARP)` — only the earlier placement address.

Their constructors create LARPBurner, LARP, IMDNames and LARPLinks with the existing LARPPlan values. The plan's
salts, addresses and arguments, application interfaces, constructor signatures and deployment implementation are
unchanged. No protocol address becomes a launch argument. No owner, upgrade, token, initialization call or manifest
was added. The fixed artist retains metadata authority only. IMD_BURN remains the canonical BurnExecutor constant.

The protected deployment reference, supplied security checklist, original AUDIT.md, all eleven source files,
interfaces, placement implementation and relevant vendored ERC721/PoolManager/math behavior were read before review.
Repository documentation's historical claims were checked against the actual implementation and tests.

## Changes and reproduced findings

### Native settlement and waiting-ETH allowance

Finding `ecb34203399935b5b666c405ac719f83affc5d6021fb2be8c374ae3e423c4448` (medium) reproduced: both supplied proof
tests failed on the arriving code. A helper pre-synced IMD and then called the burner or registered a name within
one external frame. Despite liquid pools, ETH stayed parked and no IMD reached the executor.

- `src/LARPBurner.sol`: native routes now call `POOL_MANAGER.sync(address(0))` immediately before `settle{value: …}`.
  PoolManager sync is permissionless and transient state survives the transaction, so each native payer must clear
  any prior ERC-20 sync. The ERC-20 pair settlement path is unchanged.
- The same file now records waiting ETH against the block allowance only after a route succeeds. A genuinely
  parked attempt leaves that allowance available for a later retry in the same block. The existing transient lock
  covers both routes; minimum-output failure still reverts the entire call and its accounting.
- `test/LARPBurnerSettlement.t.sol`: seven regressions cover pre-sync with POOL4 priority, the hookless fallback,
  registration, a resale toll, crew founding, minimum-output rollback, and same-block retry after liquidity returns.
  They verify the executor destination, pair share/burn and continued successful-sale block cap.
- `test/LARPBurner.invariant.t.sol`: the independent allowance model charges only measured successful sales. The
  first full run exposed its old assumption that parked attempts consumed allowance; the model now reflects the
  corrected rule while retaining exact-spend, per-block cap and conservation assertions.

Both supplied native-settlement proof tests pass after the fix. Existing L-01/L-09 gas guards, L-10 per-call and
per-block limits, and L-11 WETH unwrapping remain in place.

### Bind signed verdicts to their proposal

Finding `1a161ad00bddf984a2a15efc7278791e72e27d69fa210159750f793afba10e09` (low) reproduced: the supplied proof
expected the second proposal's delivery to revert, but the original code accepted the first proposal's signature.

- `src/SwarmPrices.sol`: `onVerdict` requires `a.requestId == requestId` in addition to the existing oracle signature
  check. A mismatch uses the existing `BadVerdictSignature` error, leaving status and decision time unchanged.
  No ABI, attestation layout, signature domain, price/share guardrail or execution window changes.
- `test/SwarmPrices.t.sol`: helpers sign actual proposal IDs; three new regressions cover replay to another pending
  proposal with different prices/share, fuzzed mismatches and valid retry, and tampering with the signed ID.
- `test/SwarmPricesEdges.t.sol`: each proposal now requires its own attestation instead of asserting that one
  signature may approve two proposals. Existing negative signature, content, expiry and window cases remain.
- `test/SwarmPrices.invariant.t.sol`: the handler signs the selected proposal ID, preserving meaningful successful
  approval/execution cases rather than letting every generated verdict fail the new check.
- `test/Base.sol`: the mock Intake can return a chosen next request ID solely for the existing published signature
  vector. That vector and its signature remain unchanged; its proposal now has the ID the vector actually signs.

The supplied verdict proof passes after the fix. The targeted governance run passes all 44 tests, including the
fixed-seed fuzz and invariant cases. Wrong-chain content continues to reject a correctly bound proposal, as before;
there was no need for the audit's optional change to that behavior.

### Informational findings and documentation

- `5170818efd7d19888eadc314280949b422ad4eb99b1f11794be3441ba8c99799`: the fixed budgets and hostile-leg fallback remain
  intact. `test/LARPBurner.t.sol` adds `test_HostileLegsCostPaidCallsTheirBudgets`, exercising paid registration with
  both a gas-eating POOL4 hook and gas-eating IMD6900. `README.md` and `AUDIT.md` distinguish the healthy-path limit
  from the recurring cost of hostile legs: each can consume almost 3M gas; both need roughly 6M plus overhead.
  The regression uses 6.8M, measures 6,026,491 gas consumed, and verifies atomic refusal at 3.4M. No cheaper budget or circuit breaker was introduced.
- `441228bc9859e5f0a6694daf21e757567eeb5dcc59a05556b136e5374d5f3192`: the occupied-salt fallback already holds.
  `README.md` now labels the 0x6900 table as conditional on unused salts and directs integrations/site/manifest notes
  to the confirmed placement getters and code verification. `AUDIT.md` records the same publication requirement.
  Placement code and LARPPlan are unchanged.
- `ffc5c37db1f9217ad47317ed4c3dc5d2170ecab5f8aa9ccd29f6c605fa31e7bc`: reproduced the original count, 268 passed and
  11 skipped out of 279. Two PlacementForkTest cases previously returned successfully without an RPC.
  `test/Placement.t.sol` now explicitly skips each fork test without MAINNET_RPC_URL. Eleven substantive new tests
  bring the delivered suite to 290: 277 offline passes and 13 explicit fork skips. README/AUDIT counts now give that
  split instead of claiming all tests ran offline.
- `eb06e5c2d46f4e2a42a7a8f4572359d31873e296c12c1da3c4554f3b921de7ad`: coverage/validation limits, not a code defect.
  `AUDIT-COVERAGE.md` answers every listed entry point, including all six constructors and both safe-transfer
  overloads. The brief labels the list 148; its ABI enumeration actually contains 149 when receive is separate
  (six constructors, 142 functions, one receive). All 149 are covered, ratio 1.
- `README.md` also replaces the obsolete four-contract factory argument table with the actual two placements and
  removes stale DEAD-beneficiary instructions. `AUDIT.md` records L-14/L-15 and updates the trust table and oracle
  binding description. This document replaces the previous adaptation report's superseded launch/test claims;
  earlier fixes and acknowledged limitations remain recorded in AUDIT.md.

The placement test helper also uses assembly `CREATE` for the two placements. The available Foundry version's
test linking replaces Solidity `new` with `VM.deployCode`, which caused the original `gasleft()` measurement to
omit the constructors' gas (the trace showed ~9.35M in constructors but only ~69k charged to the helper call).
`test_FitsOneTransaction` now measures actual creation within the transaction and keeps its existing calldata,
launcher overhead and 1M margin checks. Only the test helper changed; production placement code is untouched.

No supplied code defect was dismissed as non-reproducible. The other four findings are informational: budgeted
fallback and squat avoidance already worked, the test count needed correction, and live-chain validation was not
available. Existing AUDIT.md fixes were checked against their regressions, not re-raised or redesigned.

## Revision (2026-10-12): the reopened findings

The independent review reopened the accepted work with one medium and one low finding. Both reproduced; both are
fixed with the smallest change that does it. Everything else above stands.

### L-16 The pair leg sold the whole share at any price (medium, `22bc735e0861…`)

Reproduced: the reviewer's proof failed on the starting tree exactly as reported (the attacker ended +40.6 $IMD on a
0.1 ETH burn at the 100% share). Cause: `_burnImd` sold `held * shareBps() / 10_000` into the pair pool in one swap to
the price limit with no size bound, and v2 lets a single proposer reach 100% in four weekly proposals.

- `src/LARPBurner.sol`: one call now sells the pair pool at most `PAIR_LEG_BPS` (2%, internal constant) of the pool's
  own $IMD depth, its virtual reserve from the liquidity and price the PoolManager holds (`_pairRoom`, the same
  `extsload` read `quoteImd` already makes, now shared through `_state`; the pair key is built once in `_pairKey`).
  What the share makes above that goes to IMD_BURN, as a failed leg's share already did; a pool with no liquidity has
  no room and the leg is not tried. The bound is relative to the pool, so it holds whatever the price of $IMD or the
  pool's depth, and a front-run that deepens the pool raises it only in proportion. Measured against Ethereum's real
  pool through a public RPC: ~125 $IMD of depth, 0.1 ETH buying ~25 $IMD, so the launch's 6.9% of a full burn
  (~1.7 $IMD) fits under the cap (~2.5 $IMD) and nothing about the launch design changes; the fork test still buys
  and burns real IMD6900 (2,804 IMD6900 for a 0.00069 ETH fee).
- `src/SwarmPrices.sol`: the swarm's question gains a sixth guideline for a rising share: the proposed share of what
  0.1 ETH buys must be at most 2% of the IMD6900/$IMD pool's $IMD depth, with the depth defined in the body. A rise
  now has a criterion the panel judges instead of a bound the contract already enforces; lowering the share and
  price-only proposals are unaffected. No change to bounds, step, cooldown, ABI or attestation handling.
- Tests: `test/LARPBurnerPairLeg.t.sol` (new; six tests: the sandwich loses at 100%, at 6.9% and with a small front
  on a 6.9%-fee pair; a full burn at 100% sells exactly the room; the launch share is not clipped; the room follows
  the depth and is zero for an empty pool; plus the two L-17 tests). `test/SwarmPrices.t.sol`: `test_UpToAllOfIt`
  encoded the uncapped behaviour (a 1,000 $IMD burn sold whole into a ~1,000 $IMD pool) and now asserts the room is
  sold and the rest reaches IMD's burn; the two neighbouring share tests burn 100 $IMD so their exact percentages
  stay under the room; `test_TheQuestionNamesTheShare` checks the new guideline. `test/LARPBurnerEdges.t.sol` and
  `test/LARPBurner.invariant.t.sol`: the expected leg is min(share, room), with the room computed independently from
  the PoolManager's state (`_pairRoom` in `test/Base.sol` and in the handler). The reviewer's proof passes.

### L-17 `minImd` was met by the waiting ETH (low, `83d29e62a34f…`)

Reproduced with the reviewer's scenario (0.0993 ETH waiting; `register` at 0.00069 ETH with `minImd` five times its
quote went through). `src/LARPBurner.sol`: `burn` checks `minImd` against the sender's pro-rata part of the one sale,
`imd * own / eth`; a call that sends nothing still floors the whole sale, so a keeper's `burn(min)` keeps its meaning.
NatSpec updated. Tests: `test_MinImdIsCheckedAgainstThePayersOwnFee` and
`test_BurnFloorsTheSendersPartOrTheWholeSaleWhenItSendsNothing`, both run against the old check first (both failed).

### Also in this revision

- `test/MainnetFork.t.sol`: `test_APriceProposalThroughIMDsRealIntake` signed its attestation for a fixed request id,
  which L-15's binding (previous round) refuses against the id the real Intake returns; it now signs the proposal's
  own id. Found by running the fork suite against a public RPC, which the previous round could not.
- `AUDIT.md` (L-16, L-17, I-11, L-04, the trust row for the pair pool, the v2 notes, counts), `README.md`,
  `AUDIT-COVERAGE.md` (rows for `burn`, `burnImd`, `propose`; the ABI is unchanged, `PAIR_LEG_BPS` is internal).
- The audit's other findings were answered in the previous round and are unchanged.

## Verification

- Revision: `env -i PATH="$PATH" HOME="$HOME" forge test --offline` — 283 passed, 0 failed, 13 skipped, 296 total.
  With `MAINNET_RPC_URL` set to a public Ethereum RPC (block ~26,178,000): all 13 fork tests pass, including the
  capped IMD6900 leg on the real pair pool and the real Intake proposal. The reviewer's proof
  `Proof_22bc735e0861` fails on the starting tree and passes on the result; the two earlier proofs still pass.
- Original tree: `forge test --offline` — 268 passed, 0 failed, 11 skipped, 279 total.
- Supplied proofs, copied to temporary `test/scratch/`: 3 failed before the fixes; 3 passed afterward.
- Settlement regressions: 7 passed. Governance suites: 44 passed.
- Supplied protected factory test: passed on an empty chain with chain ID 1, deploying the final bytecode through
  its CREATE2 probe in the required order, with zero ETH and exactly zero/one constructor arguments. Runtime bounds
  and forbidden-opcode checks passed. This uses named test-only factory/salts, not proposed mainnet launch values.
- Placement suite: 8 passed and 2 fork skips. Real CREATE measurement: 10,989,653 gas including the test's calldata
  and launcher overhead estimate; adding its 1M margin remains below 16,777,216. PlaceLARP initcode is 39,120 bytes;
  PlaceLinks with its argument is 12,010 bytes, both below 49,152.
- Final `forge build` — passed with Solidity 0.8.26 and the unchanged project configuration.
- Previous round's final `env -i PATH="$PATH" HOME="$HOME" forge test --offline` — 277 passed, 0 failed, 13 skipped,
  290 total across 21 suites (superseded by the revision's 296 above). The fixed-seed fuzz and all invariant suites
  passed, including the corrected allowance model.
- Constructor ABI/link-reference checks passed: all six constructors are nonpayable, use supported static argument
  types within the 16-argument limit, and have fully linked creation bytecode. The coverage matrix matches all 149
  ABI entries. `git diff --check` passed; protected configuration/dependencies and production placement/interfaces
  have no diff. Scratch proofs and the protected harness were removed after checking and are not delivered tests.

| Runtime | Bytes (limit 24,576) |
|---|---:|
| PlaceLARP | 279 |
| PlaceLinks | 115 |
| LARPBurner | 7,465 (revision: 7,067 before L-16/L-17) |
| LARP | 6,833 |
| IMDNames | 21,095 (revision: 20,296 before the sixth guideline) |
| LARPLinks | 9,856 |

The revision re-ran the supplied protected probe on the new bytecode (empty chain, chain id 1, test-only factory and
salts, both placements in order with zero/one argument): passed, runtime bounds and forbidden opcodes included.

Build configuration, lockfiles, remappings and vendored dependencies are unchanged. No dependency was installed;
all checks use the existing offline-capable project. The fixed fuzz seed remains `0x6900`.

No mainnet deployment, signing or broadcast was attempted. No live Ethereum fork, current liquidity, proxy
implementation or Intake delivery permissions were verified; the 13 fork cases explicitly report that limitation.
No Slither or Mythril run is claimed. The deployment service remains responsible for live simulation and the
confirmed address handoff.
