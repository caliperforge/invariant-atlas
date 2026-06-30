# Atlas v4-hooks subdir (v0.1)

[![atlas-all](https://github.com/caliperforge/invariant-atlas/actions/workflows/atlas-all.yml/badge.svg?branch=main)](https://github.com/caliperforge/invariant-atlas/actions/workflows/atlas-all.yml?query=branch%3Amain)

Pre-deploy, Foundry-stateful invariant cases against the Uniswap v4
hook surface. Built for the Uniswap Foundation Security grant lane:
three planted-twin cases that demonstrate the property class catching
the bug class on the planted twin and holding on the clean twin.

The badge above tracks the full `atlas-all` workflow, which includes
the `v4-hooks-cases` jobs (clean + planted legs). Green means: the
clean leg's 9 tests all pass on the pinned toolchain (Foundry v1.7.1
+ forge-std v1.9.4), AND the planted leg's three invariant + three
attack-sequence tests all fail with the `INVARIANT VIOLATED` marker
exactly as `scorecard.planted.md` records, AND every other Atlas
case still holds. The badge re-verifies the published scorecard on
every push to `main` and on the weekly scheduled run.

The cases are **illustrative, not exhaustive**. v0.1 ships the three
classes the v4-hook audit canon flags as recurring. The atlas scales
post-grant: additional bug classes and same-source twins land as the
work continues.

License: parent Apache-2.0 (see `../LICENSE`). Attributions: parent
`../NOTICE`. AI disclosure: parent `../AI_DISCLOSURE.md`.

## What this subdir ships

```
v4-hooks/
  README.md
  clean/                    # Foundry project, clean twin
    foundry.toml
    remappings.txt
    lib/forge-std           # installed at runtime via `forge install` (gitignored)
    src/
      IHooks.sol
      MockPoolManager.sol
      RewardsHook.sol       # H1 clean
      FeeSwitchHook.sol     # H2 clean
      FlashHook.sol         # H3 clean
    test/
      H1_HookDataIntegrity.t.sol
      H2_FeeEvasion.t.sol
      H3_FlashAccounting.t.sol
  planted/                  # Foundry project, planted-bug twin
    foundry.toml            # byte-identical to clean/
    remappings.txt          # byte-identical to clean/
    lib/forge-std           # installed at runtime via `forge install` (gitignored)
    src/
      IHooks.sol            # byte-identical to clean/
      MockPoolManager.sol   # byte-identical to clean/
      RewardsHook.sol       # H1 planted (single-hunk diff vs clean)
      FeeSwitchHook.sol     # H2 planted (single-hunk diff vs clean)
      FlashHook.sol         # H3 planted (single-hunk diff vs clean)
    test/                   # byte-identical to clean/test/
  scorecard.clean.md
  scorecard.planted.md
```

A `diff -rq clean/ planted/` shows only the three hook files differ.
Toolchain config, interfaces, the mock pool manager, and the test
surface are byte-identical between the two twins.

The harness reuses the pattern from `experiments/hyperevm-safety` (a
hook-driven mock that forwards beforeSwap / afterSwap and runs the
flash-accounting unlock loop), retargeted at the v4 PoolManager surface.
The mock manager is the minimal subset of the v4 PoolManager API needed
to exercise the three bug classes; Uniswap v4 source is NOT vendored.
The `IHooks` interface is a minimal in-tree stand-in.

## The three cases (v0.1)

| ID | Bug class | `src/` file | `test/` file | Property |
|---|---|---|---|---|
| **H1** | hookData identity tampering | `RewardsHook.sol` | `H1_HookDataIntegrity.t.sol` | `hook.rewardsTo(R) == handler.swapsByRouter(R)` |
| **H2** | before/afterSwap fee evasion via hookData waiver | `FeeSwitchHook.sol` | `H2_FeeEvasion.t.sol` | `hook.accruedFees() == handler.expectedFees()` |
| **H3** | flash-accounting integrity under nested hook calls | `FlashHook.sol` | `H3_FlashAccounting.t.sol` | `handler.flashViolations() == 0` |

Each case ships:

- a CLEAN hook and a PLANTED hook differing by a single localized hunk,
- a Foundry stateful invariant test (256 runs x depth 50, 12,800
  handler calls per invariant on the default `[invariant]` budget),
- a deterministic attack-sequence test that scripts the canonical
  exploit shape end-to-end so the planted twin fires deterministically
  even if the fuzzer's random walk misses the path,
- a unit test that asserts the legitimate flow holds on both twins.

## Mapping to v4-hook incident class / audit-finding category

| Case | Audit-finding category (recurring shape) |
|---|---|
| **H1** | "Hook treats caller-supplied hookData as authenticated identity claim." Flagged across OpenZeppelin and Spearbit public v4-hook audit reports. Sub-pattern of the broader "trusted-input confusion" class. Recipient identity substitution: anyone can paste an arbitrary address into hookData and receive rewards another party paid for. |
| **H2** | "Hook honors caller-supplied 'fee waiver' / dynamic-fee parameter without authentication." Flagged across the v4-hook audit canon as a recurring shape for hooks that wire dynamic-fee, rebate, or whitelist logic to hookData. Action-flag tampering: anyone can paste the waiver byte and evade the protocol fee. |
| **H3** | "Hook makes nested PoolManager calls inside a callback without settling its own delta." Highest-severity recurring shape. Either (a) breaks the unlock (DoS on every swap that hits the hook path) or (b) leaks PoolManager-held funds if the manager's net-delta assertion is sidestepped. The v4 PoolManager's flash-accounting check IS the runtime guard; this case demonstrates a pre-deploy CI gate that catches the bug class before the on-chain check ever runs. |

## What this subdir does NOT claim

- **Not an audit.** Property tests catch the bug classes the invariants
  encode; the residual surface of a real hook is the hook's.
- **Not a runtime guard.** The properties are pre-deploy CI gates. The
  real v4 PoolManager's flash-accounting check is the runtime guard
  for the H3 class; H1 and H2 have no analog runtime guard, which is
  why a CI gate matters for them.
- **Not a fork of Uniswap v4 source.** `IHooks` and `MockPoolManager`
  are minimal in-tree stand-ins. Uniswap v4 source is referenced by
  shape, not vendored.
- **Not exhaustive.** v0.1 is three illustrative cases out of a
  larger v4-hook bug-class space (custom-curve invariant violations,
  permission-flag bitmap misuse, liquidity-modification reentrancy,
  return-delta routing). Additional cases land post-grant.

## How to reproduce locally

Requires Foundry stable channel and a working network connection for
the one-time `forge install` (same pattern as cases 6 and 7).

```sh
# clean leg, all properties hold
cd clean
forge install foundry-rs/forge-std@v1.9.4 --no-git
forge build
forge test
# Expected: 9 passed, 0 failed (3 invariant_H* + 3 attack-sequence + 3 unit).

# planted leg, properties fire
cd ../planted
forge install foundry-rs/forge-std@v1.9.4 --no-git
forge build
forge test
# Expected: 3 passed, 6 failed; all six failures carry the
# INVARIANT VIOLATED marker on stdout (3 invariant_H* + 3 attack-sequence).
```

Scorecard captures from a verified local run are in
[`scorecard.clean.md`](scorecard.clean.md) and
[`scorecard.planted.md`](scorecard.planted.md).

## Disclosure

The invariant surface (H1 + H2 + H3) was proposed by the Solidity
Specialist agent and accepted by the case author. The same-source twin
reconstructions were authored by the same specialist agent against the
audit-finding categories documented in the v4-hook audit canon. See
[`../AI_DISCLOSURE.md`](../AI_DISCLOSURE.md) for the project-level
disclosure.

Apache-2.0. Operator: Michael Moffett (michael@caliperforge.com,
team@caliperforge.com).
