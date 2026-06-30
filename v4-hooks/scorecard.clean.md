# Atlas v4-hooks subdir, CLEAN scorecard

> Captured from a local run on 2026-06-28 with the pinned toolchain
> (Foundry 1.7.1; forge-std v1.9.4 installed via
> `forge install foundry-rs/forge-std@v1.9.4 --no-git`).

## Summary

- Invariants asserted: **3** (one per case)
  - `invariant_H1_rewards_match_swap_initiator`
  - `invariant_H2_fees_match_expected_accrual`
  - `invariant_H3_flash_accounting_holds_under_nested_hook_calls`
- Invariants violated: **0**
- Tests collected: **9** (3 invariants + 3 deterministic attack + 3 unit)
- Tests passed: **9**
- Tests failed: **0**
- Invariant runner: 256 runs x depth 50 per invariant (12,800 handler
  calls per invariant, default `[invariant]` block in `foundry.toml`)
- forge version: `1.7.1`
- forge-std version: `v1.9.4`

## Test results

```
Ran 3 tests for test/H1_HookDataIntegrity.t.sol:H1Test
[PASS] invariant_H1_rewards_match_swap_initiator() (runs: 256, calls: 12800, reverts: 0)
[PASS] test_attack_H1_hookdata_tampering() (gas: 273635)
[PASS] test_unit_self_swap_credits_self() (gas: 243686)
Suite result: ok. 3 passed; 0 failed; 0 skipped; finished in 1.44s

Ran 3 tests for test/H2_FeeEvasion.t.sol:H2Test
[PASS] invariant_H2_fees_match_expected_accrual() (runs: 256, calls: 12800, reverts: 0)
[PASS] test_attack_H2_fee_evasion() (gas: 246617)
[PASS] test_unit_exempt_router_pays_zero() (gas: 227098)
Suite result: ok. 3 passed; 0 failed; 0 skipped; finished in 1.35s

Ran 3 tests for test/H3_FlashAccounting.t.sol:H3Test
[PASS] invariant_H3_flash_accounting_holds_under_nested_hook_calls() (runs: 256, calls: 12800, reverts: 0)
[PASS] test_attack_H3_flash_accounting_nested_hook_call() (gas: 285491)
[PASS] test_unit_no_bonus_path_holds_on_both_legs() (gas: 225711)
Suite result: ok. 3 passed; 0 failed; 0 skipped; finished in 1.69s

Ran 3 test suites in 1.69s: 9 tests passed, 0 failed, 0 skipped (9 total tests)
```

Total wall-clock under 5 seconds across all three cases on a 2026
MacBook. The invariant runner exercises 12,800 handler calls per
invariant; the fuzzer rotates through four routers per case (one
admin-exempt + three non-exempt for H2; four equally-untrusted for H1
and H3).

## What this scorecard demonstrates

Each clean hook holds the property the planted twin violates:

- **H1**: `recipient == sender` binding inside afterSwap rejects every
  cross-router credit attempt. `hook.rewardsTo(R)` only extends when
  R initiated the swap, in lockstep with `handler.swapsByRouter(R)`.
- **H2**: hookData is not consulted for the waiver. The fee accrual
  tracks the admin-controlled exempt mapping; `hook.accruedFees()`
  stays in lockstep with `handler.expectedFees()`.
- **H3**: hook's nested `manager.take(sender, BONUS)` is paired with a
  matching `manager.settle(BONUS)`; end-of-unlock net delta nets to
  zero; every unlock succeeds; `handler.flashViolations()` stays zero.
