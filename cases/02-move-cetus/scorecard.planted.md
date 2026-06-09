# Atlas case 2 — Cetus / PLANTED scorecard

> Captured from a local run on 2026-06-08 with the pinned toolchain
> (sui 1.73.0-homebrew, Move 2024 edition). The CI workflow
> `atlas-all.yml` re-asserts this output on every push: planted leg
> succeeds when rc != 0 AND `INVARIANT VIOLATED` marker present on
> stdout.

## Summary

- Properties asserted: **2** (overflow_safety, liquidity_tokens_conservation)
- Properties violated: **2** (both fire on the same run)
- Tests collected: **5**
- Tests passed: **3** (constructor + legitimate round-trip + the
  expected_failure constant pin do not exercise the bug class)
- Tests failed: **2** — both with an `INVARIANT VIOLATED` marker on
  stdout
- Property-A grid: first violation at probe `n = 2^192` (the correct
  boundary; the planted mask is three binary orders above, so this
  probe slips past)
- sui version: `1.73.0-homebrew`
- Move edition: `2024`
- Exit code: `1`
- `INVARIANT VIOLATED` marker count on stdout: `2`

## Test results

```
Running Move unit tests
[debug] "INVARIANT VIOLATED overflow_safety"
[ FAIL    ] cetus_liquidity::atlas_invariants::cf_invariant_overflow_safety_grid
[debug] "INVARIANT VIOLATED liquidity_tokens_conservation"
[ FAIL    ] cetus_liquidity::atlas_invariants::cf_attack_sequence_cetus_overflow
[ PASS    ] cetus_liquidity::atlas_invariants::unit_add_then_remove_legitimate_round_trip
[ PASS    ] cetus_liquidity::atlas_invariants::unit_expected_failure_pin
[ PASS    ] cetus_liquidity::atlas_invariants::unit_new_pool_initial_state
Test result: FAILED. Total tests: 5; passed: 3; failed: 2
```

(Marker print and FAIL lines are interleaved by the runner;
reordered above for readability — each marker is the line
immediately preceding its matching FAIL.)

## Failing sequence — Property A grid

```
cf_invariant_overflow_safety_grid:
  probe n = 2^192
    checked_shlw(2^192) returns (0, false)        # planted: mask is
                                                  # 0xff...ff << 192, so
                                                  # 2^192 <= mask → no overflow
    expected = (2^192 >= 2^192) = true
    ov != expected
    [debug] "INVARIANT VIOLATED overflow_safety"
    abort E_INVARIANT_OVERFLOW_SAFETY (= 0xA01 / 2561)
```

The grid probe at `n = 2^192` is the first witness in the wide bug
region. Subsequent probes (`2^192 + 1`, `2^200`, `2^248`) are not
reached because the test aborts on the first violation.

## Failing sequence — deterministic attack test

```
cf_attack_sequence_cetus_overflow:
  victim.add_liquidity(1000, 1000, A_VICTIM)
    ok → pool.total_liquidity = 1000, pool.total_tokens = 1000

  attacker.add_liquidity(2^192 + 1, 1, A_ATTACKER)
    checked_shlw(2^192 + 1)
      planted: mask = 0xffffffffffffffff << 192
               (2^192 + 1) > mask  →  false
               returned (((2^192 + 1) << 64) mod 2^256, false)
                       = (1 << 64, false)        # n << 64 silently truncates
    tokens_required = (1 << 64) / (1 << 64) = 1
    tokens_offered (1) >= tokens_required (1) → accepted
    ok → pool.total_liquidity = 2^192 + 1001,
         pool.total_tokens   = 1001

  assert_B_conservation(&pool)
    total_tokens (1001) < total_liquidity (~ 2^192) → FAIL
    [debug] "INVARIANT VIOLATED liquidity_tokens_conservation"
    abort E_INVARIANT_LIQUIDITY_TOKENS_CONSERVATION (= 0xB01 / 2817)

  # The test's #[expected_failure(abort_code = 4, location = cetus_liquidity)]
  # gate expects E_OVERFLOW (= 4) from cetus_liquidity::cetus_liquidity.
  # The observed abort code (0xB01 from atlas_invariants) does not match
  # → "Test did not error as expected" → test fails → rc != 0.
```

## What this scorecard demonstrates

The planted twin's wrong mask (`0xFFFFFFFFFFFFFFFF << 192` instead
of `1 << 192`) + the strict-`>` inequality (instead of `>=`) are
the load-bearing Cetus root cause. Property A catches the bug at
function-grain (the boundary witness `n = 2^192`); Property B
catches it at pool-grain (the post-attack pool's tokens fail to
back its liquidity by ~2^192). The deterministic attack test is
modeled verbatim on the published post-mortems; the property grid
walks a hand-picked input table chosen to exercise the witness
values the bug class predicts.

## Disclosure

The properties were AI-proposed by the Move Specialist agent
(model: `claude-opus-4-6`) and accepted by the case author. The
same-source twin reconstruction was authored by the same agent
against the published Dedaub / Halborn / Cyfrin / MerkleScience
post-mortems.

See [`../../AI_DISCLOSURE.md`](../../AI_DISCLOSURE.md) for the
project-level disclosure.

cf-invariants Atlas case 2 — Apache-2.0. Operator: Michael Moffett —
michael@caliperforge.com — team@caliperforge.com.
