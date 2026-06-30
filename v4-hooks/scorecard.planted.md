# Atlas v4-hooks subdir, PLANTED scorecard

> Captured from a local run on 2026-06-28 with the pinned toolchain
> (Foundry 1.7.1; forge-std v1.9.4 installed via
> `forge install foundry-rs/forge-std@v1.9.4 --no-git`).

## Summary

- Invariants asserted: **3** (one per case)
- Invariants violated: **3** (all three fire on the planted twins)
- Tests collected: **9** (3 invariants + 3 deterministic attack + 3 unit)
- Tests passed: **3** (the three unit tests, which do not trigger the
  bug-class path on either twin)
- Tests failed: **6** (3 invariants + 3 deterministic attacks; all six
  carry the `INVARIANT VIOLATED` marker)
- Suite rc: non-zero (`forge` exits 1)
- forge version: `1.7.1`
- forge-std version: `v1.9.4`

## Test results

```
Ran 3 tests for test/H1_HookDataIntegrity.t.sol:H1Test
[FAIL: INVARIANT VIOLATED H1_hookdata_identity_binding]
        [Sequence] (original: 1, shrunk: 1)
                sender=0x83E96De6...    addr=[Handler]0x1d14...
                calldata=swap(uint8,uint8,uint96) args=[96, 54, 472683602204]
 invariant_H1_rewards_match_swap_initiator() (runs: 1, calls: 1, reverts: 1)
[FAIL: INVARIANT VIOLATED H1_hookdata_identity_binding] test_attack_H1_hookdata_tampering() (gas: 310819)
[PASS] test_unit_self_swap_credits_self() (gas: 243644)
Suite result: FAILED. 1 passed; 2 failed; 0 skipped; finished in 97.01ms

Ran 3 tests for test/H2_FeeEvasion.t.sol:H2Test
[FAIL: INVARIANT VIOLATED H2_fee_evasion_via_hookdata_waiver]
        [Sequence] (original: 1, shrunk: 1)
                sender=0x00...7f5A7c7B  addr=[Handler]0x1d14...
                calldata=swap(uint8,uint8,uint96) args=[19, 3, 10139470285222113]
 invariant_H2_fees_match_expected_accrual() (runs: 1, calls: 1, reverts: 1)
[FAIL: INVARIANT VIOLATED H2_fee_evasion_via_hookdata_waiver] test_attack_H2_fee_evasion() (gas: 291736)
[PASS] test_unit_exempt_router_pays_zero() (gas: 227225)
Suite result: FAILED. 1 passed; 2 failed; 0 skipped; finished in 24.00ms

Ran 3 tests for test/H3_FlashAccounting.t.sol:H3Test
[FAIL: INVARIANT VIOLATED H3_flash_accounting_nested_hook_call]
        [Sequence] (original: 1, shrunk: 1)
                sender=0x00...0066  addr=[Handler]0x5991...
                calldata=swap(uint8,uint96) args=[4, 590]
 invariant_H3_flash_accounting_holds_under_nested_hook_calls() (runs: 1, calls: 1, reverts: 1)
[FAIL: INVARIANT VIOLATED H3_flash_accounting_nested_hook_call] test_attack_H3_flash_accounting_nested_hook_call() (gas: 378634)
[PASS] test_unit_no_bonus_path_holds_on_both_legs() (gas: 225711)
Suite result: FAILED. 1 passed; 2 failed; 0 skipped; finished in 19.20ms

Ran 3 test suites in 97.37ms: 3 tests passed, 6 failed, 0 skipped (9 total tests)
```

Foundry's invariant runner shrunk each failing sequence to a single
handler call, which is the minimum to trigger each bug class:

- **H1**: one fuzzed `swap(swapperIdx, recipientIdx, amount)` where
  `swapperIdx % 4 != recipientIdx % 4`. The planted hook credits
  `rewardsTo[recipientRouter]` while the handler's
  `swapsByRouter[swapperRouter]` extends. They diverge on a single
  call. Marker fires on the post-step invariant read.
- **H2**: one fuzzed `swap(routerIdx, waiveFlag, amount)` where
  `waiveFlag % 2 == 1` and the chosen router is not in the admin's
  exempt set. The planted hook short-circuits accrual on
  `hookData[0] == 0x01`; the handler still extends `expectedFees`.
  Marker fires on the post-step invariant read.
- **H3**: one fuzzed `swap(senderIdx, amount)` with hookData fixed at
  `0xBB`. The planted hook calls `manager.take` without `settle`;
  MockPoolManager reverts with `DeltaNotZero(-7)`; the handler catches
  the revert and increments `flashViolations`. Marker fires on the
  post-step invariant read.

The three unit tests pass on the planted twin because they do not
trigger the bug-class path:

- `test_unit_self_swap_credits_self` (H1) calls swap with
  `swapperIdx == recipientIdx`, so the planted hook still credits the
  correct router; ledgers agree.
- `test_unit_exempt_router_pays_zero` (H2) calls swap from the
  admin-exempt router with `hookData = 0x00`, so the fee is waived by
  the legitimate exempt path on either twin.
- `test_unit_no_bonus_path_holds_on_both_legs` (H3) calls swap with
  `hookData = 0x00`, so the planted hook's `beforeSwap` short-circuits
  on the missing 0xBB flag; no nested take; net delta zero on both
  legs.

## What this scorecard demonstrates

Each planted twin removes exactly one load-bearing check, and each
property catches the bug class the audit canon flags for that shape:

- **H1**: the `recipient == sender` binding is the load-bearing line.
  Without it, anyone with control of a router contract can paste an
  arbitrary recipient address into hookData and divert protocol
  rewards. Property fires on the first non-self-credit attempt.
- **H2**: the `hookData[0] == 0x01` short-circuit is the load-bearing
  bypass. With it added on top of the admin-exempt check, any caller
  can paste the waiver byte and evade the fee. Property fires on the
  first non-exempt waiver attempt.
- **H3**: the missing `manager.settle(BONUS)` is the load-bearing
  hunk. Without the matching settle, the hook's nested take leaves a
  -BONUS delta on the manager's books; the unlock-end check reverts.
  Property fires on the first bonus-path swap.

This is the Atlas's pre-deploy CI gate pitch applied to the v4-hook
surface a third time: properties that would have caught the bug class
before mainnet without requiring a runtime guard at execution time.
