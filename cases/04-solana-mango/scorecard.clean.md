# Atlas case 4 — Mango Markets / CLEAN scorecard

> Captured from a local run on 2026-06-08 with the pinned toolchain
> (rustc 1.96.0 / anchor-lang 1.0.1, host target). The CI workflow
> `atlas-all.yml` re-asserts this output on every push.

## Summary

- Properties asserted: **2** (borrow_power_validation, oracle_freshness)
- Properties violated: **0**
- Tests collected: **5** (1 lib unit + 4 integration)
- Tests passed: **5**
- Tests failed: **0**
- Fuzzer runs: **64** (deterministic seeded LCG; each run drives a
  16-step sequence over the (deposit, update_oracle, update_twap,
  tick_slot, borrow, repay) op set)
- rustc version: `1.96.0`
- anchor-lang version: `1.0.1`

## Test results

```
running 1 test
test test_id ... ok
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out

     Running tests/atlas_invariants.rs

running 4 tests
test cf_attack_sequence_mango_oracle_pump ... ok
test cf_attack_sequence_mango_stale_oracle ... ok
test cf_fuzz_mango_oracle_bound ... ok
test unit_deposit_borrow_repay_legitimate ... ok
test result: ok. 4 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
```

## What this scorecard demonstrates

The clean twin's three guards inside `compute_max_borrow` —
freshness check (`current_slot - oracle_slot ≤ FRESHNESS_BOUND_SLOTS`),
deviation-vs-TWAP check
(`|oracle - twap| ≤ twap × DEVIATION_BOUND_BPS / BPS_DENOM`), and the
`safe_price = min(oracle_price, twap_price)` clamp — reject the
canonical Mango-class attack sequence at `try_borrow` time. The
deterministic oracle-pump test (`cf_attack_sequence_mango_oracle_pump`)
fires the deviation gate; the stale-oracle test
(`cf_attack_sequence_mango_stale_oracle`) fires the freshness gate.
The 64-seed fuzz over mixed user / op / amount / oracle / TWAP /
slot inputs hits no violation: the clean `try_borrow` only succeeds
when the safe pipeline accepts, so the on-chain `borrowed` is
always ≤ the safe-pipeline ledger `max_safe_borrow_ever_authorized`.

## Disclosure

The properties were AI-proposed by the Rust/Anchor Specialist agent
(model: `claude-opus-4-6`) and accepted by the case author. See
[`../../AI_DISCLOSURE.md`](../../AI_DISCLOSURE.md) for the
project-level disclosure.

cf-invariants Atlas case 4 — Apache-2.0. Operator: Michael Moffett —
michael@caliperforge.com — team@caliperforge.com.
