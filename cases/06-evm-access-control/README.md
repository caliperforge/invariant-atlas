# Atlas case 6 — EVM access-control bridge (Trace2Inv canon hand-shake)

**Bug class:** missing access-control modifier on a privileged
strategy-setter function. An attacker calls the unguarded `migrate(_)`
to become the contract's "strategy," then calls the strategy-gated
outflow path to drain user deposits.

**Invariant class:** access-control / authorization — expressed as a
**pre-deploy Foundry stateful property**, not a runtime guard.

**Named real-world representative:** Punk Protocol — Aug 2021, ~$8.9M
(PeckShield + Halborn post-mortems; DeFiHackLabs Foundry PoC). The
Trace2Inv paper (Chen et al., FSE 2024, arXiv:2404.14580) catalogs
many more access-control failures in this same class; Atlas case 6
reconstructs the canonical missing-modifier shape, not the specific
Punk Protocol code.

## What this case is — and what it is NOT

This is the Atlas's **EVM bridge to Trace2Inv** — the "we are extending
this benchmark, not replacing it" gesture. The non-EVM cases (Cairo /
Move / Solana) are the spine; this case exists to connect the spine to
the EVM defender-side canon.

- The Atlas does NOT claim to find or re-derive Trace2Inv's coverage.
  Trace2Inv evaluates **runtime** invariant guards across 27 historical
  EVM exploits at the bytecode level (18/27 blocked by one invariant,
  23/27 by combination, 0.28% false-positive rate). The Atlas evaluates
  **pre-deploy property tests** — the CI gate a protocol could have
  wired in before mainnet. Different threat model, different deployment
  shape, complementary.
- The Atlas does NOT republish the attacker's calldata or fork the
  affected protocol's production source. The case ships a minimal
  same-source twin of the access-control invariant class — the smallest
  contract that exercises the bug.
- The choice of Punk Protocol as the named representative is
  illustrative, not exclusive — the same minimal twin maps to many
  Trace2Inv-cataloged access-control cases (Audius Jul 2022 ~$6M
  re-initializer; Poly Network Aug 2021 ~$611M cross-chain manager;
  many others). The case's CI assertion is class-level, not
  protocol-specific.

## Post-mortem sources (primary)

- **Trace2Inv** — Chen, Wu, Chen, Yu, Wang, Han, "Trace2Inv:
  Demystifying Invariant-Inducing Bytecode-Level Vulnerabilities of
  Smart Contracts," FSE 2024. arXiv:2404.14580. The peer-reviewed
  defender-side benchmark whose access-control invariant class this
  case extends. (Carry as published; the Atlas does not republish
  Trace2Inv's case-tagged calldata.)
- **PeckShield** — Punk Protocol post-mortem thread (Aug 2021),
  identifying the missing access-control modifier on `Forge.migrate`.
- **Halborn** — Punk Protocol incident analysis (Aug 2021).
- **DeFiHackLabs** — Foundry PoC reproducer for Punk Protocol at
  `src/test/2021-08/PunkProtocol_exp.sol`
  (https://github.com/SunWeb3Sec/DeFiHackLabs).

(URLs are carried as published; the Atlas does not republish the
attacker's calldata.)

## What this case ships

A minimal Foundry same-source twin of an access-controlled yield-
deposit contract with the missing-modifier bug class planted, the
canonical defender-side fix applied to the clean twin, and a paired-
CI run that asserts both legs.

```
06-evm-access-control/
  clean/                      # Foundry project: pre-exploit Solidity with the canonical fix
    foundry.toml
    remappings.txt
    src/AccessControlledForge.sol
    test/AtlasInvariants.t.sol
  planted/                    # Foundry project: same-source twin with bug planted
    foundry.toml                       # byte-identical to clean/
    remappings.txt                     # byte-identical to clean/
    src/AccessControlledForge.sol      # <-- ONLY this file differs from clean/
    test/AtlasInvariants.t.sol         # byte-identical to clean/
  scorecard.clean.md
  scorecard.planted.md
  README.md
```

A `diff -r clean/ planted/` shows the planted hunk as a single
localized change to `src/AccessControlledForge.sol` — the `onlyOwner`
modifier removed from `migrate(address)`. The test file, the foundry
config, and the remappings do not change between twins.

## The bug class, reconstructed

The vulnerable `migrate` on the planted twin:

```solidity
// PLANTED (06-evm-access-control/planted/src/AccessControlledForge.sol):
function migrate(address newStrategy) external {
    require(newStrategy != address(0), "Forge: zero strategy");
    yieldStrategy = newStrategy;
    emit StrategyMigrated(msg.sender, newStrategy);
}
```

The clean fix:

```solidity
// CLEAN (06-evm-access-control/clean/src/AccessControlledForge.sol):
function migrate(address newStrategy) external onlyOwner {
    require(newStrategy != address(0), "Forge: zero strategy");
    yieldStrategy = newStrategy;
    emit StrategyMigrated(msg.sender, newStrategy);
}
```

The single difference: the `onlyOwner` modifier on the function
declaration. The zero-address defensive check is kept on both twins —
only the access-control gate differs. This is the *minimal* bug-class
plant: removing the require would be a separate bug class (input
validation), and the Atlas case is scoped to access-control alone.

The canonical attack sequence on the planted twin:

```
victim.deposit{value: 1 ether}()           ok  → forge.balance = 1 ether, deposits[victim] = 1 ether
attacker.migrate(attacker)                 ok  → yieldStrategy = attacker (no onlyOwner gate)
attacker.strategyPull(attacker, 1 ether)   ok  → 1 ether sent to attacker
                                                 (strategy is now attacker-controlled)
INVARIANT VIOLATED strategy_in_approved_set    (forge.yieldStrategy() ∉ approvedStrategies)
```

The clean twin blocks the sequence at step 2: `migrate(attacker)`
reverts with `"Forge: not owner"`. The attack cannot proceed; both
properties hold trivially.

## The properties

### Property A — admin_only_migrate (per-call temporal)

After every external transition, if the most recent `migrate(_)` call
succeeded, the caller MUST have been the owner:

```
!lastMigrateSucceeded  OR  lastMigrateCaller == owner
```

The planted twin's non-owner migrate produces
`lastMigrateSucceeded == true` with `lastMigrateCaller != owner` —
violates the invariant; the marker
`"INVARIANT VIOLATED admin_only_migrate"` is emitted on the post-step
check by the invariant runner.

### Property B — strategy_in_approved_set (global state)

After every external transition, the current `yieldStrategy()` is in
the test-maintained `approvedStrategies` ledger:

```
forge.yieldStrategy() ∈ approvedStrategies
```

The handler seeds `approvedStrategies` with the constructor-blessed
initial strategy and extends it ONLY when a `migrate(_)` call succeeds
AND the caller was the owner. The clean twin holds B strictly because
the only way `yieldStrategy()` can change is through an owner-gated
migrate. The planted twin's attacker migrate points `yieldStrategy()`
at an attacker-controlled address that is NOT in `approvedStrategies`;
the marker `"INVARIANT VIOLATED strategy_in_approved_set"` is emitted.

The two properties are orthogonal: A is per-step temporal, B is global
state. On the planted twin, both fire when the attacker migrates;
either alone is sufficient to fail the CI gate.

## How to reproduce locally

Requires Foundry (stable channel) and a working network connection
for the one-time `forge install`.

```sh
# clean leg — all properties hold
cd clean
forge install foundry-rs/forge-std@v1.9.4 --no-git
forge build
forge test
# Expected: 6 passed, 0 failed (2 invariant_* + 1 attack-sequence + 3 unit).

# planted leg — properties fire
cd ../planted
forge install foundry-rs/forge-std@v1.9.4 --no-git
forge build
forge test
# Expected: 3 passed, 3 failed; all three failures carry the
# `INVARIANT VIOLATED` marker on stdout.
```

Scorecard captures from a verified-2026-06-08 local run are in
[`scorecard.clean.md`](scorecard.clean.md) and
[`scorecard.planted.md`](scorecard.planted.md); CI re-asserts them on
every push.

## What this case does NOT claim

- This is NOT a fork of Punk Protocol's (or any other affected
  protocol's) production source. The reconstructed contract is the
  minimal access-controlled-deposit primitive needed to exercise the
  bug class; the protocol's full feature set (yield-strategy
  delegate-call surface, oracle integration, governance, withdrawal
  queues, etc.) is out of scope.
- The Atlas does NOT claim CaliperForge found Punk Protocol's exploit
  live. The property surface here is what an EVM protocol with a
  similar privileged-function shape could have wired into CI before
  mainnet; it is not a runtime guard and not a formal-verification
  proof.
- The Atlas does NOT claim to extend or re-derive Trace2Inv's coverage.
  Trace2Inv evaluates runtime invariant enforcement across 27
  historical EVM exploits at the bytecode level. This case translates
  the access-control invariant class into a Foundry stateful property
  that runs pre-deploy in CI — a different threat model, complementary
  to Trace2Inv's. Reviewers should treat Trace2Inv as the EVM canon
  and the Atlas as the bridge to it from the non-EVM cases.

## Disclosure

The invariant surface (Property A + Property B) was proposed by the
Solidity Specialist agent (model: `claude-opus-4-6`) against the
Trace2Inv-cataloged access-control class definition and accepted by
the case author. The same-source twin reconstruction was authored by
the same specialist agent. See [`../../AI_DISCLOSURE.md`](../../AI_DISCLOSURE.md).

Apache-2.0. Operator: Michael Moffett — michael@caliperforge.com —
team@caliperforge.com.
