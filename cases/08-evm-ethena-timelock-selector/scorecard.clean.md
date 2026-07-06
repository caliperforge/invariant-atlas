# Atlas case 8 — Guardian audit M-01 (Ethena TimelockController selector-extraction integrity) — CLEAN scorecard

> Captured from a local run on 2026-07-06 with the pinned toolchain
> (Foundry 1.7.1; forge-std v1.9.4; OpenZeppelin v5.0.2).
> The CI workflow `atlas-all.yml`'s `evm-cases` job re-asserts this
> output on every push: clean leg succeeds when rc == 0 AND zero
> `INVARIANT VIOLATED` markers on stdout.

## Summary

- Properties asserted: **2**
  (`invariant_g1_selector_extract_native_transfer_admissible`,
  `invariant_g1_selector_extract_short_data_reverts_typed`)
- Properties violated: **0**
- Tests collected: **6**
- Tests passed: **6**
- Tests failed: **0**
- Invariant runner: 256 runs × depth 50 per invariant (12,800 handler
  calls per invariant; default `[invariant]` block in `foundry.toml`)
- forge version: `1.7.1`
- forge-std version: `v1.9.4`
- openzeppelin-contracts version: `v5.0.2`
- solc version: `0.8.26` (matches the vendored `EthenaTimelockController.sol` pragma)

## Test results

```
Ran 6 tests for test/AtlasInvariants.t.sol:AtlasInvariantsTest
[PASS] invariant_g1_selector_extract_native_transfer_admissible() (runs: 256, calls: 12800, reverts: 0)
[PASS] invariant_g1_selector_extract_short_data_reverts_typed() (runs: 256, calls: 12800, reverts: 0)
[PASS] test_regression_g1_whitelisted_native_transfer_admissible() (gas: 79503)
Logs:
  whitelisted_native_transfer_ok: 1
[PASS] test_unit_constructor_state() (gas: 26942)
[PASS] test_unit_non_whitelisted_selector_rejected() (gas: 24347)
[PASS] test_unit_normal_calldata_call_succeeds() (gas: 56949)
Suite result: ok. 6 passed; 0 failed; 0 skipped; finished in 763.14ms (1.47s CPU time)
```

## Handler call distribution (both invariant runs; near-identical shape since they share the campaign budget)

```
+----------+----------------------+-------+---------+----------+
| Contract | Selector             | Calls | Reverts | Discards |
+----------+----------------------+-------+---------+----------+
| Handler  | drive_emptyCalldata  | 4205  | 0       | 0        |
| Handler  | drive_normalCalldata | 4270  | 0       | 0        |
| Handler  | drive_shortCalldata  | 4325  | 0       | 0        |
+----------+----------------------+-------+---------+----------+
```

Three handler entrypoints are exercised in roughly equal weight by the
fuzzer. The handler's `try/catch` absorbs the contract-level reverts
(e.g., short-calldata calls to CLEAN's `_harnessExtractSelector` revert
with typed `InvalidSelector(data)`; the handler's counter does not
increment, so the invariant sees `shortCalldata_successes == 0`). The
empty-calldata branch never reverts on the CLEAN twin — the post-fix
`_harnessExtractSelector` returns `bytes4(0)`, the whitelist check
passes, and MockTarget's `receive()` accepts the transfer. `emptyCalldata_attempts`
and `emptyCalldata_successes` track in lock-step across all 4205
invocations — invariant A holds throughout.

## What this scorecard demonstrates

The CLEAN twin uses the vendored Guardian post-fix `_extractSelector`
semantics (mirrored in `_harnessExtractSelector`):

  - `data.length == 0` → `bytes4(0)` (admits whitelisted native-asset transfer)
  - `data.length <  4` → `revert InvalidSelector(data)` (typed short-data revert)
  - `data.length >= 4` → `bytes4(data[:SELECTOR_LENGTH])` (normal case)

The deterministic regression `test_regression_g1_whitelisted_native_transfer_admissible`
succeeds: `whitelisted_native_transfer_ok: 1` (the executor's
`harnessExecuteWhitelisted(mockTarget, 1 ether, "")` call returns
without reverting; MockTarget's `receive()` fires; the safe-side ledger
`receivedValue += 1 ether` records the transfer).

The 256-run × depth-50 stateful fuzz (12,800 calls per invariant)
exercises the full three-shape handler surface (empty / normal /
short calldata); no invariant fires. Total wall-clock under a second
per leg on a 2026 MacBook — comfortably under the 25-minute CI job
timeout.

## Disclosure

The invariant surface
(`g1_selector_extract_native_transfer_admissible`,
`g1_selector_extract_short_data_reverts_typed`) was proposed by the
Solidity Specialist agent (model: `claude-opus-4-6`) against the
Guardian audit report M-01 finding's own verbatim quotation of the
pre-fix vulnerable code path. See
[`../../AI_DISCLOSURE.md`](../../AI_DISCLOSURE.md) for the
project-level disclosure and the case's README for the credit
provenance chain (Guardian audit report + Ethena PR#4 + Guardian's
public vendored source).

cf-invariants Atlas case 8 — Apache-2.0. Operator: Michael Moffett —
michael@caliperforge.com — team@caliperforge.com.
