# Atlas case 5 — Loopscale / PLANTED scorecard

> Captured from a local run on 2026-06-08 with the pinned toolchain
> (rustc 1.96.0, anchor-lang 1.0.2, proptest 1.11.0). The CI
> workflow `atlas-all.yml` re-asserts this output on every push:
> planted leg succeeds when rc != 0 AND `INVARIANT VIOLATED` marker
> present on stdout.

## Summary

- Properties asserted: **2** (collateral_valuation_bound,
  borrow_solvency)
- Properties violated: **1** (collateral_valuation_bound; fires
  before borrow_solvency in both tests because Property A is
  checked first in the test helper sequence)
- Tests collected: **8** (1 lib unit + 7 integration in
  `tests/atlas_invariants.rs`)
- Tests passed: **6** — the lib `test_id` test, plus 5 integration
  unit tests that do not trigger the bug class (initial-state,
  deposit-only, legitimate-sub-LTV-borrow, zero-amount, error-
  enum-reachable)
- Tests failed: **2** — both with the
  `"INVARIANT VIOLATED collateral_valuation_bound"` marker
- proptest cases at first violation: **1** of 64 (the property fires
  on the first fuzzed sequence that produces an oracle spike + borrow
  combo)
- anchor-lang version: `1.0.2`
- rustc version: `1.96.0`

## Test results

```
running 1 test
test test_id ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out

     Running tests/atlas_invariants.rs

running 7 tests
test unit_clean_rejects_zero_amount ... ok
test unit_initial_state_holds_both_properties ... ok
test unit_deposit_only_holds_both_properties ... ok
test unit_legitimate_borrow_under_ltv_holds_both_properties ... ok
test unit_loop_error_reachable ... ok
test cf_attack_sequence_loopscale_pt_mispricing ... FAILED
test cf_invariant_loopscale_collateral_valuation_and_borrow ... FAILED

failures:

---- cf_attack_sequence_loopscale_pt_mispricing stdout ----
INVARIANT VIOLATED collateral_valuation_bound
  (last_used=5000000 > twap_floor=1000000)

---- cf_invariant_loopscale_collateral_valuation_and_borrow stdout ----
INVARIANT VIOLATED collateral_valuation_bound
  (last_used=3578125 > twap_floor=1000000)
proptest: minimal failing input found within 1 case.

test result: FAILED. 5 passed; 2 failed
```

## Failing sequence — deterministic attack test

```
cf_attack_sequence_loopscale_pt_mispricing:
  init_market(twap_floor=1_000_000, safety=0.90, ltv=0.75)   ok
  pt_oracle_price = 1_000_000                                ok
  attacker.deposit_collateral(100 PT)                        ok
  pt_oracle_price = 5_000_000                                ok  (the manipulation)
  attacker.borrow(370_000_000)                               ok  (planted path:
                                                                  collateral_value =
                                                                  100 * 5_000_000 = 500_000_000
                                                                  max_borrow =
                                                                  500_000_000 * 0.75 =
                                                                  375_000_000
                                                                  370_000_000 <= 375_000_000)
  market.last_borrow_effective_price = 5_000_000             (planted writes raw spot)
  INVARIANT VIOLATED collateral_valuation_bound
    last_borrow_effective_price = 5_000_000 > pt_twap_floor = 1_000_000
```

If the test were to continue past the first violation, Property B
would also fire on the same state: `borrowed_value * 10_000 =
3_700_000_000_000` vs. `pt_collateral * twap_floor * ltv_max_bps =
100 * 1_000_000 * 7_500 = 750_000_000_000`. The first-fire-wins on
property A is the case 1 zkLend pattern (round-trip conservation
would also fire on the same attack sequence; in practice the
empty-market guard fires first).

## Failing sequence — fuzz

```
cf_invariant_loopscale_collateral_valuation_and_borrow (runs: 1 of 64):
  fuzz inputs randomly hit (update_pt_oracle_price, borrow) with an
  oracle value above twap_floor; the planted twin's borrow_logic
  writes the raw spot into last_borrow_effective_price; the property
  check fires on the next iteration. Minimal-failing-input from
  proptest:
    op_word = 2475659429498185527
    who_word = 500118494279652924
    amt_word = 5896280823148412453
    oracle_word = 688895601955672446
  last_used = 3_578_125 > twap_floor = 1_000_000.
```

## What this scorecard demonstrates

The planted twin's `borrow_logic` consumes the raw spot oracle
without bounding against the conservative TWAP floor — the
load-bearing Loopscale bug class per the Apr 2025 post-mortems.
Both the deterministic attack test (modelled directly on the
RateX-PT mispricing post-mortem narrative) and the random property
test catch it within the cargo-test timeout. The
`borrow_solvency` property (B) would fire on the same state if the
test continued past the first marker; both are visible in the
program code as separate, named assertions.

## Disclosure

The properties were AI-proposed by the Rust/Anchor Specialist agent
(model: `claude-opus-4-7`) and accepted by the case author. The
same-source twin reconstruction (the planted hunk: raw-spot in
`borrow_logic`, no `min(spot, twap_floor)`, no safety-margin
scaling) was authored by the same agent against the published The
Block / Cryptopolitan / Loopscale incident notes.

See [`../../AI_DISCLOSURE.md`](../../AI_DISCLOSURE.md) for the
project-level disclosure.

cf-invariants Atlas case 5 — Apache-2.0. Operator: Michael Moffett —
michael@caliperforge.com — team@caliperforge.com.
