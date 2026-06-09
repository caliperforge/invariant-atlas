# Atlas case 6 — EVM access-control / CLEAN scorecard

> Captured from a local run on 2026-06-08 with the pinned toolchain
> (Foundry 1.7.1 via `foundry-rs/foundry-toolchain@v1`; forge-std v1.9.4).
> The CI workflow `atlas-all.yml`'s `evm-cases` job re-asserts this output
> on every push: clean leg succeeds when rc == 0 AND zero
> `INVARIANT VIOLATED` markers on stdout.

## Summary

- Properties asserted: **2** (`invariant_admin_only_migrate`,
  `invariant_strategy_in_approved_set`)
- Properties violated: **0**
- Tests collected: **6**
- Tests passed: **6**
- Tests failed: **0**
- Invariant runner: 256 runs × depth 50 per invariant (12,800 handler
  calls per invariant; default `[invariant]` block in `foundry.toml`)
- forge version: `1.7.1`
- forge-std version: `v1.9.4`

## Test results

```
Ran 6 tests for test/AtlasInvariants.t.sol:AtlasInvariantsTest
[PASS] invariant_admin_only_migrate() (runs: 256, calls: 12800, reverts: 0)
[PASS] invariant_strategy_in_approved_set() (runs: 256, calls: 12800, reverts: 0)
[PASS] test_attack_punk_protocol_class() (gas: 74720)
Logs:
  attacker_migrate_ok: 0
  attacker_strategy_pull_ok: 0
[PASS] test_unit_constructor_state() (gas: 16065)
[PASS] test_unit_deposit_then_withdraw_legitimate() (gas: 76536)
[PASS] test_unit_owner_can_migrate() (gas: 16721)
Suite result: ok. 6 passed; 0 failed; 0 skipped; finished in 987.22ms
```

## Handler call distribution (one of the two invariant runs; both are identical-shape since they share the same campaign budget)

```
+----------+---------------------+-------+---------+----------+
| Contract | Selector            | Calls | Reverts | Discards |
+----------+---------------------+-------+---------+----------+
| Handler  | depositETH          | 3236  | 0       | 0        |
| Handler  | migrate             | 3186  | 0       | 0        |
| Handler  | strategyPullToOwner | 3229  | 0       | 0        |
| Handler  | withdrawETH         | 3149  | 0       | 0        |
+----------+---------------------+-------+---------+----------+
```

All four handler functions are exercised in roughly equal weight by
the fuzzer. The handler's `try/catch` absorbs the contract-level
reverts from non-owner `migrate` attempts, so `Handler.migrate` shows
zero handler-level reverts — the contract-level revert that closes
the bug class is what keeps `lastMigrateSucceeded = false` and lets
property A hold.

## What this scorecard demonstrates

The clean twin's `onlyOwner`-gated `migrate(_)` rejects the canonical
Punk-Protocol-class attack at step 2 (`migrate(attacker)` reverts with
`"Forge: not owner"`). The deterministic attack test's logs confirm:
`attacker_migrate_ok = 0` (the `.call(...)` returned `false` because
the contract reverted) and `attacker_strategy_pull_ok = 0` (the
subsequent pull also reverts because `yieldStrategy` is still the
constructor-set INITIAL_STRATEGY, not the attacker). The final
property check (`yieldStrategy == INITIAL_STRATEGY`) holds.

The 256-run × depth-50 stateful fuzz (12,800 calls per invariant)
across three actors (one OWNER, two non-OWNER) exercises the full
handler surface; no invariant fires. Total wall-clock under 1 second
per leg on a 2026 MacBook — comfortably under the 25-minute CI job
timeout.

## Disclosure

The properties were AI-proposed by the Solidity Specialist agent
(model: `claude-opus-4-6`) and accepted by the case author. See
[`../../AI_DISCLOSURE.md`](../../AI_DISCLOSURE.md) for the project-level
disclosure.

cf-invariants Atlas case 6 — Apache-2.0. Operator: Michael Moffett —
michael@caliperforge.com — team@caliperforge.com.
