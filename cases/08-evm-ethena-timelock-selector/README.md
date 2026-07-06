# Atlas case 8 — Guardian audit M-01 (Ethena TimelockController selector-extraction integrity)

**Case identifier (spec-side):** `C-G1` — Guardian's row-G1 entry.
**Case identifier (atlas-side):** `cases/08-evm-ethena-timelock-selector/`
(numeric slot; the atlas catalog is numbered per the convention set by
case 1 in §How each case is structured of the top-level README).

**Bug class:** logical error in selector extraction on a
whitelisted-executor timelock path. The pre-fix
`executeWhitelisted(target, value, data)` extracted the selector
unconditionally as
```solidity
bytes4 selector = bytes4(data[:SELECTOR_LENGTH]);
```
On empty calldata (native-asset transfers routed through a whitelisted
`receive()`/`fallback()` path — the whitelisted selector being
`bytes4(0)`), this slice reverts with an out-of-bounds panic BEFORE the
whitelist check runs. Consequence: a whitelisted native-asset transfer
that the admin had explicitly authorized cannot be executed. The
Ethena team resolved the finding via `_extractSelector` — a helper
that dispatches on `data.length`:

```solidity
function _extractSelector(bytes calldata data) internal pure returns (bytes4 selector) {
    if (data.length == 0) {
        selector = bytes4(0);
    } else if (data.length < SELECTOR_LENGTH) {
        revert InvalidSelector(data);
    } else {
        selector = bytes4(data[:SELECTOR_LENGTH]);
    }
}
```

**Invariant class:** logical-error / specification violation on a
governance-tier privileged path, expressed as a **pre-deploy Foundry
stateful property** — not a runtime guard.

## What this case is — and what it is NOT

This is the Atlas's first **governance-tier** case (timelock +
whitelist), plants the flag with **Guardian Audits** (row-G1 on the
firm-map), and extends the EVM leg beyond the access-control
sub-patterns of cases 6 + 7:

- Case 6: missing-modifier access-control (Punk-Protocol-class
  `migrate` without `onlyOwner`).
- Case 7: confused-deputy / unbound-identity access-control (NMT
  `SquidRouterModule` without `msg.sender == delegate`).
- **Case 8 (this one):** selector-extraction logical error on a
  whitelisted-executor timelock path (Ethena `EthenaTimelockController`
  M-01 pre-Ethena-PR#4).

Same broad "pre-deploy CI property" pitch, three distinct sub-patterns
across three different auditor lanes (Trace2Inv-bridge + rekt.news +
Guardian).

Rails observed on this case:

- **Not a fork of Ethena's production timelock.** Both twins subclass
  **Guardian's byte-identical vendored `EthenaTimelockController`**
  (post-fix, MIT SPDX) at
  `lib/ethena-timelock-defender/src/EthenaTimelockController.sol`.
  The vendored file is copied byte-for-byte from Guardian Audits' public
  [`EthenaTimelockDefender`](https://github.com/GuardianAudits/EthenaTimelockDefender)
  repository (`src/EthenaTimelockController.sol`, `main` branch, fetched
  2026-07-06). The vendored file is **never mutated** by either twin.
  Attribution + license text ride alongside the vendored source in
  `lib/ethena-timelock-defender/LICENSE` and
  `lib/ethena-timelock-defender/NOTICE`.
- **Not a fork of Ethena's upstream.** Ethena's own
  `ethena-labs/timelock-contract` repository is not publicly reachable
  as of 2026-07-06 (returns 404). The fix's provenance rides on
  (a) Guardian's public audit report's explicit PR#4 attribution and
  pre-fix code quotation, and (b) Guardian's public post-fix vendored
  source. This is the same structural shape as the Atlas's C-P1 case
  (subclass the auditor's public post-fix). The soft-rail note was
  reviewed and accepted at CEO decision D-1 (2026-07-06).
- **The Atlas does NOT claim CaliperForge found the M-01 finding
  live.** The property surface here is what an EVM protocol with a
  similar whitelisted-executor timelock shape could have wired into
  CI before mainnet — a pre-deploy stateful-invariant test, not a
  runtime guard, not a formal-verification proof.
- **Spec-violation framing throughout.** M-01 is a spec-violation
  finding: the intended user (the whitelisted-executor path admitting
  native-asset transfers) is the one blocked by the bug — no privilege
  is escalated, no funds are misdirected. The audit report is the
  load-bearing provenance anchor; there is nothing else to republish.

## Provenance (credit block)

**Provenance.** The finding this case encodes was reported by Guardian
in the [Ethena TimelockController audit,
2025-05-26](https://github.com/GuardianAudits/Audits/blob/main/Ethena/2025-05-26_Ethena_TimelockController.pdf)
as M-01 "Native Asset Transfers Always Revert" (Medium severity,
Logical Error, Resolved). The fix was implemented by the Ethena team
in PR#4 to the (private) `ethena-labs/timelock-contract` repository,
adding an `_extractSelector` helper that admits empty calldata (native
ETH transfers via whitelisted receive/fallback). Guardian publicly
vendored the post-fix source at
[`GuardianAudits/EthenaTimelockDefender/src/EthenaTimelockController.sol`](https://github.com/GuardianAudits/EthenaTimelockDefender/blob/main/src/EthenaTimelockController.sol)
(MIT SPDX on the file). This case is a defender-side regression
fixture: our teaching-scale harness subclasses Guardian's vendored
contract and reproduces the pre-fix selector-extraction defect in the
planted twin. It does not reproduce the finding against any deployed
Ethena timelock.

Credit-chain summary:

- **Finding + audit:** Guardian (Owen Thurm, Roberto Reigada,
  0xCiphky, Zdravko Hristov, Michael Lett) —
  [Ethena TimelockController audit report, 2025-05-26](https://github.com/GuardianAudits/Audits/blob/main/Ethena/2025-05-26_Ethena_TimelockController.pdf).
- **Fix:** Ethena team, PR#4 (upstream repo `ethena-labs/timelock-contract`
  private; PR referenced in the audit report at page 12).
- **Public post-fix source:** Guardian's
  [`EthenaTimelockDefender`](https://github.com/GuardianAudits/EthenaTimelockDefender)
  repository. MIT SPDX header on the file. Vendored byte-identical into
  `lib/ethena-timelock-defender/src/EthenaTimelockController.sol` under
  both twins.
- **Taxonomy source:** none. M-01 is a first-instance finding, not part
  of a named public taxonomy article the way the Zealynx Pattern-4
  entries under `experiments/uniswap-v4-invariants` sit.

**Soft-rail note (CEO D-1, 2026-07-06):** Ethena's upstream repository
is private; the fix chain rides on Guardian's public audit report
(names PR#4, quotes pre-/post-fix code) plus Guardian's public
post-fix vendored source. This is the C-P1 structural shape — the audit
report is the load-bearing provenance anchor. Both primary URLs are
strong (audit report on Guardian's public catalog; vendored source
MIT SPDX header on the file).

## Subclass-real note (deviation from the Director spec §1d verbatim `override`)

The Director's build spec (`agents/engineering_lead/outbox/T-next-targets-prework-2026-07-06_result.md`
§1d) proposed overriding `_extractSelector` in the harness subclass
with an `override` keyword. That shape does not compile against the
vendored source: the vendor's `_extractSelector` is declared
`internal pure` **without** `virtual` (see
`lib/ethena-timelock-defender/src/EthenaTimelockController.sol` L209),
so a subclass `override` fails at compile-time. Mutating the vendored
source to add `virtual` was rejected on the rail *"planted bugs live
only in our harness; never mutate vendored source."*

The subclass-real interpretation adopted here (equivalent in every
material respect to the property-under-test, with the three explicit
deviations named below):

- Both twins subclass Guardian's vendored `EthenaTimelockController`
  (byte-identical between clean/ and planted/).
- Both twins add a new harness entrypoint
  `harnessExecuteWhitelisted(target, value, data)` that mirrors the
  vendored `executeWhitelisted` body with three deviations, no fewer,
  no more:
  1. the selector-extraction step is factored into
     `_harnessExtractSelector(data)` (the twin-diff hunk);
  2. the base's `nonReentrant` guard is intentionally NOT applied on
     the harness path (documented in-file: the fuzz campaign runs
     multiple invariant sequences per block, and the reentrancy latch
     would false-positive them);
  3. the base's `emit WhitelistedFunctionExecuted(target, selector,
     value, data)` on-chain observability event is omitted; the
     invariant surface's ledger lives in the handler counters, not
     on-chain event logs, so re-emitting it would add noise without
     moving the property.
- The vendored base's `isWhitelisted(...)` public view, the
  `NotWhitelisted(target, selector)` typed error, the
  `WHITELISTED_EXECUTOR_ROLE` gate, and the low-level
  `Address.functionCallWithValue(target, data, value)` are reused
  unchanged.
- The **ONLY** line the two twins differ on (clean/ vs planted/) is
  the selector-extraction body, which reduces to the exact vulnerable
  `bytes4(data[:SELECTOR_LENGTH])` slice the audit's M-01 quotes.
  The three deviations above are common to both twins by construction.

Class-fidelity gate hard-check: the planted twin's
`_harnessExtractSelector` body reproduces the exact
`bytes4(data[:SELECTOR_LENGTH])` slice the audit report cites at
page 12. PASS.

Provenance-fidelity hard-check: the vendored source at
`lib/ethena-timelock-defender/src/EthenaTimelockController.sol` is
byte-identical to Guardian's public post-fix source (SHA verified at
build time; `diff -q` reports no differences). PASS.

## Sources (primary)

- **Guardian audit report (2025-05-26):**
  https://github.com/GuardianAudits/Audits/blob/main/Ethena/2025-05-26_Ethena_TimelockController.pdf
  M-01 at page 12. Names PR#4. Quotes pre-fix and post-fix code.
- **Guardian post-fix vendored source:**
  https://github.com/GuardianAudits/EthenaTimelockDefender/blob/main/src/EthenaTimelockController.sol
  MIT SPDX. Byte-identical vendor at
  `lib/ethena-timelock-defender/src/EthenaTimelockController.sol`.
- **Ethena upstream PR#4:** not publicly reachable
  (`ethena-labs/timelock-contract` returns 404 as of 2026-07-06). Named
  in the audit report; not directly citable.

## What this case ships

```
08-evm-ethena-timelock-selector/
  README.md                                # this file
  scorecard.clean.md                       # expected CLEAN-leg run
  scorecard.planted.md                     # expected PLANTED-leg run
  clean/                                   # Foundry project: post-fix subclass
    foundry.toml
    remappings.txt
    src/G1EthenaTimelockHarness.sol           # CLEAN — post-fix _harnessExtractSelector
    test/AtlasInvariants.t.sol
    lib/ethena-timelock-defender/          # Vendored Guardian source (byte-identical)
      LICENSE
      NOTICE
      src/EthenaTimelockController.sol
  planted/                                 # Foundry project: pre-fix subclass
    foundry.toml                              # byte-identical to clean/
    remappings.txt                            # byte-identical to clean/
    src/G1EthenaTimelockHarness.sol           # PLANTED — pre-fix _harnessExtractSelector
    test/AtlasInvariants.t.sol                # byte-identical to clean/test
    lib/ethena-timelock-defender/          # byte-identical to clean/lib
      LICENSE
      NOTICE
      src/EthenaTimelockController.sol        # byte-identical to clean vendor
```

A `diff -r clean/ planted/` after CI install shows the plant as
**exactly one localized change**: `_harnessExtractSelector`'s body in
`src/G1EthenaTimelockHarness.sol` (three-case dispatch collapses to an
unconditional slice). Every other file — the vendored controller, the
foundry config, the remappings, the test surface — is byte-identical
across the two twins.

## The bug class, reconstructed

The vulnerable `harnessExecuteWhitelisted` on the planted twin (via
its `_harnessExtractSelector`):

```solidity
// PLANTED (planted/src/G1EthenaTimelockHarness.sol):
function _harnessExtractSelector(bytes calldata data) internal pure returns (bytes4 selector) {
    // Pre-fix behavior — matches the audit's M-01 quotation verbatim.
    selector = bytes4(data[:SELECTOR_LENGTH]);
}
```

On `data.length == 0` (native-asset transfer path), the slice
`data[:SELECTOR_LENGTH]` reads past the calldata bound and Solidity's
calldata-slice bounds check reverts with an OOB panic (0x32) BEFORE
the whitelist check runs.

The clean fix — three cases matching the audit's post-fix helper:

```solidity
// CLEAN (clean/src/G1EthenaTimelockHarness.sol):
function _harnessExtractSelector(bytes calldata data) internal pure returns (bytes4 selector) {
    // Byte-for-byte match with lib/.../EthenaTimelockController.sol L209-217.
    if (data.length == 0) {
        selector = bytes4(0);
    } else if (data.length < SELECTOR_LENGTH) {
        revert InvalidSelector(data);
    } else {
        selector = bytes4(data[:SELECTOR_LENGTH]);
    }
}
```

The canonical specification-violation sequence on the planted twin:

```
admin sets up (mockTarget, bytes4(0)) whitelist entry           ok  → executor path enabled
executor.harnessExecuteWhitelisted{value: 1 ether}(             fails on planted:
    mockTarget, 1 ether, "")                                        pre-fix slice reverts OOB
                                                                    on data.length == 0
                                                                    (BEFORE whitelist check runs).
                                                                    Whitelisted native transfer
                                                                    is unreachable.
INVARIANT VIOLATED g1_selector_extract_native_transfer_admissible
    (emptyCalldata_attempts > emptyCalldata_successes on planted;
     equal on clean.)
```

The clean twin accepts the sequence: `_harnessExtractSelector("")`
returns `bytes4(0)`, `isWhitelisted(mockTarget, bytes4(0))` returns
true, `Address.functionCallWithValue(mockTarget, "", 1 ether)`
triggers MockTarget's `receive()`, transfer succeeds. Both properties
hold trivially on the clean twin.

## The properties

### Property A — `g1_selector_extract_native_transfer_admissible` (per-call temporal)

```
handler.emptyCalldata_attempts == handler.emptyCalldata_successes
```

The handler records an attempt on every entry into
`drive_emptyCalldata(uint96 valueSeed)` and a success only when the
outbound `harnessExecuteWhitelisted{value: v}(mockTarget, v, "")` call
returns without reverting. On the CLEAN twin, every attempt succeeds
(the post-fix `_harnessExtractSelector` admits `bytes4(0)`, the
whitelist entry matches, MockTarget's `receive()` fires). On the
PLANTED twin, every attempt reverts at the selector-extraction step
BEFORE the whitelist check runs; the counter diverges after the first
call and stays diverged for the remainder of the campaign.

The marker `INVARIANT VIOLATED g1_selector_extract_native_transfer_admissible`
is emitted on the post-step check by the invariant runner.

### Property B — `g1_selector_extract_short_data_reverts_typed` (companion)

```
handler.shortCalldata_successes == 0
```

The handler generates 1-, 2-, or 3-byte data with arbitrary content
(0x42, 0x43, 0x44) and drives `harnessExecuteWhitelisted{value: v}
(mockTarget, v, data)`. Both twins revert on this path:

- CLEAN reverts with `InvalidSelector(data)` (the middle branch of the
  three-case dispatch).
- PLANTED reverts with an OOB panic on the slice.

Companion B keeps the campaign honest about the short-data case and
separates the specific specification violation (empty-calldata
admissibility, A) from the general "short data reverts somehow"
claim (B). Both twins hold B; only PLANTED violates A.

The two properties are orthogonal: A is the specification violation
the audit's M-01 names, B is defensive telemetry on the adjacent
case.

## How to reproduce locally

Requires Foundry (stable channel) and a working network connection for
the one-time `forge install`.

```sh
# clean leg — properties hold
cd clean
forge install foundry-rs/forge-std@v1.9.4 --no-git
forge install OpenZeppelin/openzeppelin-contracts@v5.0.2 --no-git
forge build
forge test
# Expected: 6 passed, 0 failed (2 invariant_* + 1 regression + 3 unit).

# planted leg — properties fire
cd ../planted
forge install foundry-rs/forge-std@v1.9.4 --no-git
forge install OpenZeppelin/openzeppelin-contracts@v5.0.2 --no-git
forge build
forge test
# Expected: 4 passed, 2 failed. Both failures carry the
# `INVARIANT VIOLATED g1_selector_extract_native_transfer_admissible`
# marker on stdout.
```

Scorecard captures from a verified-2026-07-06 local run are in
[`scorecard.clean.md`](scorecard.clean.md) and
[`scorecard.planted.md`](scorecard.planted.md); CI re-asserts them on
every push (`atlas-all.yml` → `evm-cases` job, matrix cell
`08-evm-ethena-timelock-selector / {clean,planted}`).

## What this case does NOT claim

- This is NOT a fork of Ethena's production `EthenaTimelockController`.
  Both twins subclass Guardian's vendored copy (byte-identical between
  twins) and reproduce the pre-fix defect ONLY in the harness
  contract's `_harnessExtractSelector` — the vendored file is never
  mutated.
- The Atlas does NOT claim CaliperForge found the M-01 finding live.
  Guardian did, in the 2025-05-26 audit engagement; Ethena patched via
  PR#4. This case is a defender-side regression fixture, not a
  finding-discovery claim.
- The Atlas does NOT extend or re-derive Trace2Inv's coverage.
  Trace2Inv evaluates runtime invariant enforcement across 27 historical
  EVM exploits at the bytecode level. This case translates a
  logical-error / spec-violation sub-class into a Foundry stateful
  property that runs pre-deploy in CI — a different threat model,
  complementary to Trace2Inv's. Cases 6 + 7 handle access-control
  sub-patterns; case 8 extends the EVM catalog into governance-tier
  selector-extraction bugs.

## Disclosure

The invariant surface (Property A + Property B) was proposed by the
Solidity Specialist agent (model: `claude-opus-4-6`) against the
Guardian audit report M-01's own verbatim quotation of the pre-fix
vulnerable code path (`bytes4 selector = bytes4(data[:SELECTOR_LENGTH]);`
at page 12). The same-source twin reconstruction was authored by the
same agent. See [`../../AI_DISCLOSURE.md`](../../AI_DISCLOSURE.md) for
the project-level disclosure.

Apache-2.0 (Atlas project license; the vendored Guardian source at
`lib/ethena-timelock-defender/src/EthenaTimelockController.sol` is MIT).
Operator: Michael Moffett — michael@caliperforge.com —
team@caliperforge.com.
