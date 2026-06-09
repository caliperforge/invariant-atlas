# Atlas case 5 — Loopscale / CLEAN scorecard

> Captured from a local run on 2026-06-08 with the pinned toolchain
> (rustc 1.96.0, anchor-lang 1.0.2, proptest 1.11.0). The CI
> workflow `atlas-all.yml` re-asserts this output on every push.

## Summary

- Properties asserted: **2** (collateral_valuation_bound,
  borrow_solvency)
- Properties violated: **0**
- Tests collected: **8** (1 lib unit + 7 integration in
  `tests/atlas_invariants.rs`)
- Tests passed: **8**
- Tests failed: **0**
- proptest cases: **64** (deterministic; configured in
  `ProptestConfig.cases`)
- anchor-lang version: `1.0.2`
- rustc version: `1.96.0`

## Test results

```
running 1 test
test test_id ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out

     Running tests/atlas_invariants.rs

running 7 tests
test cf_attack_sequence_loopscale_pt_mispricing ... ok
test unit_clean_rejects_zero_amount ... ok
test unit_deposit_only_holds_both_properties ... ok
test unit_initial_state_holds_both_properties ... ok
test unit_legitimate_borrow_under_ltv_holds_both_properties ... ok
test unit_loop_error_reachable ... ok
test cf_invariant_loopscale_collateral_valuation_and_borrow ... ok

test result: ok. 7 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
```

## What this scorecard demonstrates

The clean twin's `min(spot, twap_floor)` price-floor on the borrow
path neutralizes the canonical Loopscale PT-mispricing attack
sequence at the borrow step. With `pt_oracle_price = 5_000_000` and
`pt_twap_floor = 1_000_000`, the borrow path computes
`effective_price = min(5_000_000, 1_000_000) = 1_000_000`, gates the
borrow at `100 * 1_000_000 * 0.90 * 0.75 = 67_500_000` micro-value-
units, and rejects the attacker's `370_000_000` ask with
`LoopError::Undercollateralized`. The deterministic attack test
catches the rejection and asserts both properties hold trivially
(zero-debt state). The 64-run proptest over mixed user / op /
amount / oracle inputs hits no violation — the clean path bounds the
valuation by construction.

## Disclosure

The properties were AI-proposed by the Rust/Anchor Specialist agent
(model: `claude-opus-4-7`) and accepted by the case author. See
[`../../AI_DISCLOSURE.md`](../../AI_DISCLOSURE.md) for the
project-level disclosure.

cf-invariants Atlas case 5 — Apache-2.0. Operator: Michael Moffett —
michael@caliperforge.com — team@caliperforge.com.
