# Atlas case 1 — zkLend / PLANTED scorecard

> Captured from a local run on 2026-06-08 with the pinned toolchain
> (scarb 2.18.0, snforge 0.60.0). The CI workflow `atlas-all.yml`
> re-asserts this output on every push: planted leg succeeds when
> rc != 0 AND `INVARIANT VIOLATED` marker present on stdout.

## Summary

- Properties asserted: **2** (accumulator_empty_market_guard,
  round_trip_conservation)
- Properties violated: **1** (accumulator_empty_market_guard;
  fires before round_trip_conservation in both tests)
- Tests collected: **4**
- Tests passed: **2** (the constructor + legitimate-flow tests do
  not trigger the bug class)
- Tests failed: **2** — both with the
  `"INVARIANT VIOLATED accumulator_empty_market_guard"` marker
- Fuzzer runs at first violation: **1 of 64**
- snforge version: `0.60.0`
- scarb version: `2.18.0`

## Test results

```
Collected 4 test(s) from zklend_market package
Running 4 test(s) from tests/
[PASS] zklend_market_integrationtest::atlas_invariants::unit_constructor_initial_state
[FAIL] zklend_market_integrationtest::atlas_invariants::cf_attack_sequence_zklend_inflation
    "INVARIANT VIOLATED accumulator_empty_market_guard"
[PASS] zklend_market_integrationtest::atlas_invariants::unit_deposit_then_withdraw_legitimate
[FAIL] zklend_market_integrationtest::atlas_invariants::cf_invariant_zklend_share_accounting
       (runs: 1)
    "INVARIANT VIOLATED accumulator_empty_market_guard"
Tests: 2 passed, 2 failed, 0 ignored, 0 filtered out
```

## Failing sequence — deterministic attack test

```
cf_attack_sequence_zklend_inflation:
  attacker.deposit(1)            ok  → total_shares = 1, total_assets = 1
  attacker.donate(10_000)        ok  → total_shares = 1, total_assets = 10_001
  victim.deposit(5_000)          ok  → shares minted = 0 (truncation);
                                       total_assets = 15_001
  INVARIANT VIOLATED accumulator_empty_market_guard
    total_shares = 1 < MIN_INIT_SHARES (1000)
    AND total_assets = 15_001 > 0
```

## Failing sequence — fuzz

```
cf_invariant_zklend_share_accounting (runs: 1 of 64; failed on first run):
  fuzz inputs randomly hit a `deposit(small_amount)` on the empty
  market — the planted twin accepts it, post-state total_shares < 1000,
  property A fires, marker emitted.
```

## What this scorecard demonstrates

The planted twin's missing empty-market guard + permissionless
`donate` are the load-bearing zkLend bug class; both the
deterministic attack test (modelled directly on the post-mortem) and
the random fuzz test catch it within the timeout. Round-trip
conservation (Property B) would also fire on the planted attack
sequence's withdraw step; in practice the empty-market guard fires
first.

## Disclosure

The properties were AI-proposed by the Cairo Specialist agent
(model: `claude-opus-4-6`) and accepted by the case author. The
same-source twin reconstruction was authored by the same agent
against the published BlockSec / Halborn post-mortems.

See [`../../AI_DISCLOSURE.md`](../../AI_DISCLOSURE.md) for the
project-level disclosure.

cf-invariants Atlas case 1 — Apache-2.0. Operator: Michael Moffett —
michael@caliperforge.com — team@caliperforge.com.
