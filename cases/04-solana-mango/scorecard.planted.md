# Atlas case 4 — Mango Markets / PLANTED scorecard

> Captured from a local run on 2026-06-08 with the pinned toolchain
> (rustc 1.96.0 / anchor-lang 1.0.1, host target). The CI workflow
> `atlas-all.yml` re-asserts this output on every push: planted leg
> succeeds when rc != 0 AND `INVARIANT VIOLATED` marker present on
> stdout.

## Summary

- Properties asserted: **2** (borrow_power_validation, oracle_freshness)
- Properties violated: **1** (borrow_power_validation; fires before
  oracle_freshness in every test that triggers both)
- Tests collected: **5** (1 lib unit + 4 integration)
- Tests passed: **2** (the lib unit test + the legitimate-flow
  integration test do not trigger the bug class)
- Tests failed: **3** — all three with the
  `"INVARIANT VIOLATED borrow_power_validation"` marker on stdout
- Fuzzer runs at first violation: **1 of 64** (the LCG seed schedule
  hits an oracle-pump → borrow sequence in the first run)
- rustc version: `1.96.0`
- anchor-lang version: `1.0.1`

## Test results

```
running 1 test
test test_id ... ok
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out

     Running tests/atlas_invariants.rs

running 4 tests
test unit_deposit_borrow_repay_legitimate ... ok
test cf_attack_sequence_mango_stale_oracle ... FAILED
test cf_attack_sequence_mango_oracle_pump ... FAILED
test cf_fuzz_mango_oracle_bound ... FAILED

INVARIANT VIOLATED borrow_power_validation: borrowed=10000 > max_safe_borrow_ever_authorized=0
  (oracle_price=100, twap_price=100, deposited_collateral=1000000000,
   current_slot=26, oracle_slot=0, safe_max_borrow_now=None)
INVARIANT VIOLATED borrow_power_validation: borrowed=700000 > max_safe_borrow_ever_authorized=0
  (oracle_price=2000, twap_price=100, deposited_collateral=1000000000,
   current_slot=0, oracle_slot=0, safe_max_borrow_now=None)
INVARIANT VIOLATED borrow_power_validation: borrowed=925 > max_safe_borrow_ever_authorized=0
  (oracle_price=2703, twap_price=3433, deposited_collateral=857808600,
   current_slot=17, oracle_slot=0, safe_max_borrow_now=None)

test result: FAILED. 1 passed; 3 failed; 0 ignored; 0 measured; 0 filtered out
```

## Failing sequence — deterministic oracle-pump test

```
cf_attack_sequence_mango_oracle_pump:
  attacker.deposit_collateral(1_000_000_000)         deposited=1e9
                                                     baseline safe max_borrow = 50_000
  attacker.update_oracle(price=2_000, slot=0)        oracle=2_000 (20× spike vs TWAP=100)
                                                     canonical safe pipeline REJECTS
                                                     (deviation 1_900 > allowed 5)
  attacker.try_borrow(700_000)
                                                     planted compute_max_borrow:
                                                       1e9 * 2_000 / 1e6 * 50% = 1_000_000
                                                       700_000 < 1_000_000  → ACCEPTED
                                                     ledger update via safe_max_borrow:
                                                       safe_max_borrow returns None →
                                                       ledger stays 0
  INVARIANT VIOLATED borrow_power_validation
    borrowed = 700_000 > max_safe_borrow_ever_authorized = 0
    (canonical safe pipeline returned None at borrow time;
     attacker borrowed 700_000 USDC against collateral worth
     50_000 at the safe price.)
```

## Failing sequence — deterministic stale-oracle test

```
cf_attack_sequence_mango_stale_oracle:
  attacker.deposit_collateral(1_000_000_000)         deposited=1e9
  attacker.tick_slot(FRESHNESS_BOUND_SLOTS + 1)      current_slot=26, oracle_slot=0
                                                     canonical pipeline REJECTS on freshness
  attacker.try_borrow(10_000)
                                                     planted compute_max_borrow:
                                                       no freshness gate → succeeds
                                                       returns 1e9 * 100 / 1e6 * 50% = 50_000
                                                       10_000 < 50_000 → ACCEPTED
                                                     ledger update via safe_max_borrow:
                                                       returns None (oracle aged 26 > 25)
                                                       ledger stays 0
  INVARIANT VIOLATED borrow_power_validation
    borrowed = 10_000 > max_safe_borrow_ever_authorized = 0
```

## Failing sequence — fuzz

```
cf_fuzz_mango_oracle_bound (runs: 1 of 64; failed on first run):
  LCG-decoded ops in seed 11's 16-step sequence include an
  update_oracle to (oracle_price=2703) against twap_price=3433 (a
  21% deviation > the 5% bound), followed by a try_borrow(925)
  against deposited_collateral=857808600. Planted's missing
  deviation gate admits the borrow; canonical pipeline rejects;
  borrow_power_validation marker emitted.
```

## What this scorecard demonstrates

The planted twin's missing freshness + deviation + safe-price-floor
guards are the load-bearing Mango-class bug class; both the
deterministic attack tests (modeled directly on the post-mortem
narrative — oracle pump + stale oracle) and the random fuzz test
catch it within the timeout. Property B (oracle_freshness) would
also fire on the stale-oracle sequence's post-step check; in
practice Property A (borrow_power_validation) fires first because
its assertion runs before B in every test.

## Disclosure

The properties were AI-proposed by the Rust/Anchor Specialist agent
(model: `claude-opus-4-6`) and accepted by the case author. The
same-source twin reconstruction was authored by the same agent
against the published Helius / Mango DAO post-mortems.

See [`../../AI_DISCLOSURE.md`](../../AI_DISCLOSURE.md) for the
project-level disclosure.

cf-invariants Atlas case 4 — Apache-2.0. Operator: Michael Moffett —
michael@caliperforge.com — team@caliperforge.com.
