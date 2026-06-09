# Atlas case 6 — EVM access-control / PLANTED scorecard

> Captured from a local run on 2026-06-08 with the pinned toolchain
> (Foundry 1.7.1 via `foundry-rs/foundry-toolchain@v1`; forge-std v1.9.4).
> The CI workflow `atlas-all.yml`'s `evm-cases` job re-asserts this output
> on every push: planted leg succeeds when rc != 0 AND
> `INVARIANT VIOLATED` marker present on stdout.

## Summary

- Properties asserted: **2** (`invariant_admin_only_migrate`,
  `invariant_strategy_in_approved_set`)
- Properties violated: **2** (both fire — within the first 10 fuzzer
  calls; Foundry's shrinker reduces the failing sequence to 1 call:
  a single non-OWNER migrate)
- Tests collected: **6**
- Tests passed: **3** (the three unit tests — constructor + legitimate-
  flow + owner-can-migrate — do not trigger the bug class)
- Tests failed: **3** — all three carry the `"INVARIANT VIOLATED"`
  marker (the two `invariant_*` tests + the deterministic
  `test_attack_punk_protocol_class`)
- `INVARIANT VIOLATED` marker count on stdout: **8** (per-failure
  JSON event line + summary + per-failing-test block)
- Suite rc: non-zero
- forge version: `1.7.1`
- forge-std version: `v1.9.4`

## Test results

```
Ran 6 tests for test/AtlasInvariants.t.sol:AtlasInvariantsTest
[FAIL: INVARIANT VIOLATED admin_only_migrate]
        [Sequence] (original: 10, shrunk: 1)
                sender=0xeB5B... addr=[Handler]0x5615... calldata=migrate(uint8,address) args=[1, 0xC808...]
 invariant_admin_only_migrate() (runs: 0, calls: 0, reverts: 0)
[FAIL: INVARIANT VIOLATED strategy_in_approved_set]
        [Sequence] (original: 10, shrunk: 1)
                sender=0xeB5B... addr=[Handler]0x5615... calldata=migrate(uint8,address) args=[1, 0xC808...]
 invariant_strategy_in_approved_set() (runs: 0, calls: 0, reverts: 0)
[FAIL: INVARIANT VIOLATED strategy_in_approved_set] test_attack_punk_protocol_class() (gas: 110827)
Logs:
  attacker_migrate_ok: 1
  attacker_strategy_pull_ok: 1
[PASS] test_unit_constructor_state() (gas: 16065)
[PASS] test_unit_deposit_then_withdraw_legitimate() (gas: 76536)
[PASS] test_unit_owner_can_migrate() (gas: 16681)
Suite result: FAILED. 3 passed; 3 failed; 0 skipped; finished in 9.47ms
```

Foundry's invariant runner shrunk a 10-call original sequence down to
a single `migrate(uint8, address)` call where `actorIdx = 1` — a
non-OWNER actor. Both invariants fire on the same shrunk sequence
because they both depend on the post-migrate state.

## Failing sequence — deterministic attack test

```
test_attack_punk_protocol_class:
  victim.deposit{value: 1 ether}()           ok  -> forge.balance = 1 ether
                                                   deposits[victim] = 1 ether
  attacker.migrate(attacker)                 ok  -> yieldStrategy = attacker
                                                   (attacker_migrate_ok: 1)
  attacker.strategyPull(attacker, 1 ether)   ok  -> 1 ether sent to attacker
                                                   forge.balance = 0
                                                   (attacker_strategy_pull_ok: 1)
  require(forge.yieldStrategy() == INITIAL_STRATEGY, ...)
    INVARIANT VIOLATED strategy_in_approved_set
```

The `attacker_migrate_ok: 1` + `attacker_strategy_pull_ok: 1` lines
in the test logs are the smoking-gun on the planted twin: both calls
that reverted on the clean leg now succeed, the contract balance
drains to zero, and the final property check fails with the marker.

## Failing sequence — fuzz (both invariants)

```
invariant_admin_only_migrate / invariant_strategy_in_approved_set:
  Handler.migrate(actorIdx=1, newStrategy=0xC808...) on a non-OWNER
  actor index. Planted accepts (no onlyOwner gate):
    - lastMigrateSucceeded = true
    - lastMigrateCaller    = ACTOR_A  (non-owner)
    - yieldStrategy        = 0xC808... (NOT in approvedStrategies)
  Both invariants fire on the post-step check:
    - A: !lastMigrateSucceeded OR lastMigrateCaller == OWNER  -> false
    - B: approvedStrategies[yieldStrategy]                    -> false
```

## What this scorecard demonstrates

The planted twin's missing `onlyOwner` on `migrate(_)` is the load-
bearing access-control bug class — the same shape Trace2Inv catalogs
across multiple of its 27 cases. Both the deterministic attack test
(modeled on the Punk Protocol Aug 2021 post-mortem) and the random
stateful fuzz catch it within the runner's budget (Foundry's shrinker
narrows a 10-call sequence to the single load-bearing
`migrate(non_owner, attacker_addr)` call). The unit tests
(constructor / legitimate-deposit / owner-migrate) do not trigger the
bug class — they assert that the LEGITIMATE flows still work on the
planted twin, which is what a real protocol would have observed in
QA before mainnet (the bug only triggers on a malicious call shape).

This is exactly the §1.1 pitch made concrete: a pre-deploy CI gate
that would have caught the bug class before mainnet, without requiring
a runtime guard at execution time.

## Disclosure

The properties were AI-proposed by the Solidity Specialist agent
(model: `claude-opus-4-6`) and accepted by the case author. The
same-source twin reconstruction was authored by the same agent
against the Trace2Inv-cataloged access-control class definition.

See [`../../AI_DISCLOSURE.md`](../../AI_DISCLOSURE.md) for the
project-level disclosure.

cf-invariants Atlas case 6 — Apache-2.0. Operator: Michael Moffett —
michael@caliperforge.com — team@caliperforge.com.
