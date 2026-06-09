# Atlas case 2 — Cetus / CLEAN scorecard

> Captured from a local run on 2026-06-08 with the pinned toolchain
> (sui 1.73.0-homebrew, Move 2024 edition). The CI workflow
> `atlas-all.yml` re-asserts this output on every push.

## Summary

- Properties asserted: **2** (overflow_safety, liquidity_tokens_conservation)
- Properties violated: **0**
- Tests collected: **5**
- Tests passed: **5**
- Tests failed: **0**
- Property-A grid probes: **11** (0 / 1 / 1000 / 2^64 / 2^128 / 2^192-1 /
  2^192 / 2^192+1 / 2^200 / 2^248 / u256::MAX)
- sui version: `1.73.0-homebrew`
- Move edition: `2024`
- Exit code: `0`
- `INVARIANT VIOLATED` marker count on stdout: `0`

## Test results

```
Running Move unit tests
[ PASS    ] cetus_liquidity::atlas_invariants::cf_attack_sequence_cetus_overflow
[ PASS    ] cetus_liquidity::atlas_invariants::cf_invariant_overflow_safety_grid
[ PASS    ] cetus_liquidity::atlas_invariants::unit_add_then_remove_legitimate_round_trip
[ PASS    ] cetus_liquidity::atlas_invariants::unit_expected_failure_pin
[ PASS    ] cetus_liquidity::atlas_invariants::unit_new_pool_initial_state
Test result: OK. Total tests: 5; passed: 5; failed: 0
```

## What this scorecard demonstrates

The clean twin's `checked_shlw` correctly reports overflow for every
value `n >= 2^192` (the exact boundary above which `n << 64` truncates
in u256). The canonical Cetus attack call —
`add_liquidity(2^192 + 1, 1, attacker)` — therefore aborts at
`E_OVERFLOW` (= 4) inside `liquidity_to_tokens`; the `add_liquidity`
call reverts; the pool state is unchanged. The `#[expected_failure]`
gate on the attack test absorbs the E_OVERFLOW abort and the test
passes — i.e., on the clean twin the attack sequence's failure mode
is the protocol correctly rejecting the malicious add, not the
invariant firing.

The Property-A grid walks 11 hand-picked witnesses across the
ordinary-value range, the correct boundary, the bug region, and
`u256::MAX`. All hold on clean. The Property-B conservation check
runs at every step of the legitimate round-trip unit test and on the
post-attack pool inspection that the clean twin never reaches.

## Disclosure

The properties were AI-proposed by the Move Specialist agent
(model: `claude-opus-4-6`) and accepted by the case author. See
[`../../AI_DISCLOSURE.md`](../../AI_DISCLOSURE.md) for the
project-level disclosure.

cf-invariants Atlas case 2 — Apache-2.0. Operator: Michael Moffett —
michael@caliperforge.com — team@caliperforge.com.
