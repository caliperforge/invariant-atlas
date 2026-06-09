# Atlas case 1 — zkLend / CLEAN scorecard

> Captured from a local run on 2026-06-08 with the pinned toolchain
> (scarb 2.18.0, snforge 0.60.0). The CI workflow `atlas-all.yml`
> re-asserts this output on every push.

## Summary

- Properties asserted: **2** (accumulator_empty_market_guard,
  round_trip_conservation)
- Properties violated: **0**
- Tests collected: **4**
- Tests passed: **4**
- Tests failed: **0**
- Fuzzer runs: **64** (seed via snforge default)
- snforge version: `0.60.0`
- scarb version: `2.18.0`

## Test results

```
Collected 4 test(s) from zklend_market package
Running 0 test(s) from src/
Running 4 test(s) from tests/
[PASS] zklend_market_integrationtest::atlas_invariants::unit_constructor_initial_state
[PASS] zklend_market_integrationtest::atlas_invariants::unit_deposit_then_withdraw_legitimate
[PASS] zklend_market_integrationtest::atlas_invariants::cf_attack_sequence_zklend_inflation
[PASS] zklend_market_integrationtest::atlas_invariants::cf_invariant_zklend_share_accounting
       (runs: 64)
Tests: 4 passed, 0 failed, 0 ignored, 0 filtered out
```

## What this scorecard demonstrates

The clean twin's empty-market guard rejects the canonical zkLend
attack sequence at step 1 (`deposit(1)` reverts with
`"empty-market: amount < MIN_INIT_DEPOSIT"`). The safe-dispatcher
absorbs the revert; subsequent attacker calls (`donate`, `withdraw`)
also revert because the market is still unbootstrapped or the
attacker has no shares. The post-step property checks find both
properties holding. The 64-run fuzz over mixed user / op / amount
inputs hits no violation.

## Disclosure

The properties were AI-proposed by the Cairo Specialist agent
(model: `claude-opus-4-6`) and accepted by the case author. See
[`../../AI_DISCLOSURE.md`](../../AI_DISCLOSURE.md) for the
project-level disclosure.

cf-invariants Atlas case 1 — Apache-2.0. Operator: Michael Moffett —
michael@caliperforge.com — team@caliperforge.com.
