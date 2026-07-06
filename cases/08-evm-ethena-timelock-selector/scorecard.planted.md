# Atlas case 8 — Guardian audit M-01 (Ethena TimelockController selector-extraction integrity) — PLANTED scorecard

> Captured from a local run on 2026-07-06 with the pinned toolchain
> (Foundry 1.7.1; forge-std v1.9.4; OpenZeppelin v5.0.2).
> The CI workflow `atlas-all.yml`'s `evm-cases` job re-asserts this
> output on every push: planted leg succeeds when rc != 0 AND
> `INVARIANT VIOLATED` marker present on stdout.

## Summary

- Properties asserted: **2**
  (`invariant_g1_selector_extract_native_transfer_admissible`,
  `invariant_g1_selector_extract_short_data_reverts_typed`)
- Properties violated: **1**
  (`invariant_g1_selector_extract_native_transfer_admissible` fires on
  the empty-calldata shape; the companion short-data property still holds
  on the PLANTED twin — both twins agree that 1-3 byte calldata reverts,
  just via different revert types)
- Tests collected: **6**
- Tests passed: **4** (the three unit tests + the companion invariant
  `invariant_g1_selector_extract_short_data_reverts_typed`; none of them
  trigger the empty-calldata bug class)
- Tests failed: **2** — both carry the
  `INVARIANT VIOLATED g1_selector_extract_native_transfer_admissible`
  marker (the invariant test itself + the deterministic
  `test_regression_g1_whitelisted_native_transfer_admissible`)
- `INVARIANT VIOLATED` marker count on stdout: **4** (per-failure JSON
  event line + per-failing-test block + failing-tests summary + the
  regression's own failure header)
- Suite rc: non-zero (`forge` exits 1)
- forge version: `1.7.1`
- forge-std version: `v1.9.4`
- openzeppelin-contracts version: `v5.0.2`
- solc version: `0.8.26` (matches the vendored `EthenaTimelockController.sol` pragma)

## Test results

```
Ran 6 tests for test/AtlasInvariants.t.sol:AtlasInvariantsTest
[FAIL: INVARIANT VIOLATED g1_selector_extract_native_transfer_admissible]
        [Sequence] (original: 3, shrunk: 1)
                sender=0x...0333  addr=[Handler]0xF628...  calldata=drive_emptyCalldata(uint96) args=[235055710]
 invariant_g1_selector_extract_native_transfer_admissible() (runs: 0, calls: 0, reverts: 0)
[PASS] invariant_g1_selector_extract_short_data_reverts_typed() (runs: 256, calls: 12800, reverts: 0)
[FAIL: INVARIANT VIOLATED g1_selector_extract_native_transfer_admissible]
    test_regression_g1_whitelisted_native_transfer_admissible() (gas: 22886)
Logs:
  whitelisted_native_transfer_ok: 0
[PASS] test_unit_constructor_state() (gas: 26942)
[PASS] test_unit_non_whitelisted_selector_rejected() (gas: 24299)
[PASS] test_unit_normal_calldata_call_succeeds() (gas: 56901)
Suite result: FAILED. 4 passed; 2 failed; 0 skipped; finished in 662.51ms
```

Foundry's invariant runner shrunk the failing sequence to a single call:
one `drive_emptyCalldata`. The invariant fires on the shrunk shape
because the pre-fix unconditional `bytes4(data[:SELECTOR_LENGTH])` slice
on empty calldata reverts out-of-bounds — the handler's `try/catch`
absorbs the revert, `emptyCalldata_attempts` increments to 1 but
`emptyCalldata_successes` stays at 0, and the invariant check
`attempts == successes` fails on the next runner tick.

## Failing sequence — deterministic regression

```
test_regression_g1_whitelisted_native_transfer_admissible:
  vm.deal(EXECUTOR, 1 ether)
  vm.prank(EXECUTOR)
  address(harness).call{value: 1 ether}(
    harnessExecuteWhitelisted(mockTarget, 1 ether, ""))
    -> reverts on PLANTED (pre-fix slice hits OOB before whitelist check)
    -> execOk = false
    -> whitelisted_native_transfer_ok: 0
  require(execOk, "INVARIANT VIOLATED ...") -> fires marker.
```

The `whitelisted_native_transfer_ok: 0` log line is the smoking-gun on
the planted twin: the empty-calldata whitelisted transfer that
succeeds on the CLEAN leg now reverts, `execOk` is false, and the
final property check fails with the marker.

## Failing sequence — fuzz (invariant A only)

```
invariant_g1_selector_extract_native_transfer_admissible:
  Handler.drive_emptyCalldata(valueSeed=235055710)
    - PLANTED harness.harnessExecuteWhitelisted{value: 235055711}
        (mockTarget, 235055711, "")
      - _harnessExtractSelector("")
          - bytes4(data[:SELECTOR_LENGTH]) on data.length == 0
          - reverts OOB (panic 0x32)
    - try/catch absorbs the revert
    - emptyCalldata_attempts = 1
    - emptyCalldata_successes = 0
  Invariant check: attempts (1) != successes (0)
    -> INVARIANT VIOLATED g1_selector_extract_native_transfer_admissible
```

## Failing sequence — companion invariant B still holds

```
invariant_g1_selector_extract_short_data_reverts_typed (PASS on PLANTED):
  Handler.drive_shortCalldata(lenSeed, valueSeed) x 4163 times
    - PLANTED harness.harnessExecuteWhitelisted{value: v}
        (mockTarget, v, data) with data.length ∈ {1, 2, 3}
      - _harnessExtractSelector(data)
          - bytes4(data[:SELECTOR_LENGTH]) reverts OOB (panic 0x32)
    - try/catch absorbs; shortCalldata_successes stays 0
  Invariant check: shortCalldata_successes == 0 -> holds.
```

Companion B keeps the campaign honest about the short-data case
(CLEAN reverts with typed `InvalidSelector(data)`; PLANTED reverts
with an OOB panic — different revert *shapes* but both revert, so
B holds on both). The specification violation the atlas encodes is
strictly the empty-calldata admissibility (A), not the short-data
handling (B). Separating the two properties makes the class-fidelity
gate precise.

## What this scorecard demonstrates

The PLANTED twin's `_harnessExtractSelector` is a single-line
re-implementation of the pre-fix Ethena TimelockController behavior
the Guardian audit report M-01 quotes verbatim:
`selector = bytes4(data[:SELECTOR_LENGTH]);`. On empty calldata (the
native-asset transfer path the audit's M-01 "Native Asset Transfers
Always Revert" is named after), the slice reverts out-of-bounds
BEFORE the whitelist check runs — a whitelisted `bytes4(0)` selector
is unreachable. Both the deterministic regression test (modeled on the
audit's own PoC shape) and the random stateful fuzz catch it within
the runner's budget; Foundry's shrinker narrows the failing sequence
to a single `drive_emptyCalldata` call.

The unit tests (constructor, non-whitelisted-selector-rejected,
normal-calldata-succeeds) do not trigger the bug class — they assert
the LEGITIMATE flows still work on the planted twin, which is what a
protocol's own QA would have observed before the audit surfaced M-01
(the pathology only triggers on the empty-calldata path, which is not
in the "normal call" test set).

This is the §1.1 pitch made concrete a third time: a pre-deploy CI
gate that would have caught the bug class before Ethena PR#4. Case 6
is the missing-modifier flavor of access-control; case 7 is the
unbound-identity / confused-deputy flavor; case 8 extends the EVM
catalog with a governance-tier selector-extraction bug on a
whitelisted-executor timelock path — a distinct code path from
case 6 + case 7 that plants the flag with Guardian.

## Disclosure

The invariant surface
(`g1_selector_extract_native_transfer_admissible`,
`g1_selector_extract_short_data_reverts_typed`) was proposed by the
Solidity Specialist agent (model: `claude-opus-4-6`) against the
Guardian audit report M-01 finding's own verbatim quotation of the
pre-fix vulnerable code path. The same-source twin reconstruction
was authored by the same agent — the planted twin's
`_harnessExtractSelector` body reproduces the exact
`bytes4(data[:SELECTOR_LENGTH])` slice the audit cites.

See [`../../AI_DISCLOSURE.md`](../../AI_DISCLOSURE.md) for the
project-level disclosure and the case's README for the credit
provenance chain (Guardian audit report + Ethena PR#4 + Guardian's
public vendored source).

cf-invariants Atlas case 8 — Apache-2.0. Operator: Michael Moffett —
michael@caliperforge.com — team@caliperforge.com.
