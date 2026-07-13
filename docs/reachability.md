# Multi-seed reachability certification

## What this fixes

The base atlas-all CI runs each planted case once per commit with
whatever fuzz seed CI happens to draw. Two-step or deterministic
triggers fire reliably, but "almost always" is not "always". A lucky
CI seed on a longer or rarer trigger would leave a false green where
the docs claim a hard red.

The multi-seed reachability leg (`ci/reachability_leg.sh`) closes that
gap for every EVM planted case: it runs each case's planted project
once per seed across a fixed 16-seed set (`ci/reachability_seeds.txt`)
and requires every seed to produce at least one `INVARIANT VIOLATED`
marker and a non-zero forge exit. If any seed passes on any case, the
matrix job fails for that case and the docs' k / 16 number goes down
instead of quietly staying at 16 / 16.

## Verdict (per EVM case, 2026-07-13)

Recorded from the local certification run at each case's own
`foundry.toml [invariant]` budget (standing `runs = 256`, `depth = 50`
across every EVM planted project in this atlas).

| lane | case | k / 16 | verdict |
| --- | --- | --- | --- |
| EVM | case 06 access-control | 16 / 16 | reachability certified: yes (16/16 failed as required) |
| EVM | case 08 ethena-timelock-selector | 16 / 16 | reachability certified: yes (16/16 failed as required) |
| EVM | v4-hooks | 16 / 16 | reachability certified: yes (16/16 failed as required) |
| EVM | taiko | 16 / 16 | reachability certified: yes (16/16 failed as required) |

Every seed in `ci/reachability_seeds.txt` produced a non-zero forge
exit and at least one `INVARIANT VIOLATED` marker on every EVM planted
project at the standing budget; no bump required.

## Coverage caveat: non-EVM cases

The Cairo case (01-cairo-zklend), Move case (02-move-cetus) and the
three Solana cases (03-solana-cashio, 04-solana-mango,
05-solana-loopscale) are NOT yet covered by this leg. The canonical
runners at `scripts/reachability/` in the crypto-contributor repo
today ship a Foundry driver and a Rust / proptest driver; the Rust
driver expects a `tests/reachability.rs` companion in each planted
crate that reads `REACHABILITY_SEED` and constructs a seeded
`TestRunner`. That companion is not written yet for the Solana cases;
Cairo (snforge / proptest) and Move (Move Prover / on-chain-simulator
tests) need their own drivers.

Per-ecosystem reachability harnesses are queued in
`ops/decisions.md` in the crypto-contributor repo. Until they land,
the non-EVM cases carry the base atlas-all single-seed catch as their
standing proof; the reachability leg emits nothing for them (rather
than silently claiming coverage it does not have).

## Merge-gate rule (EVM cases)

No new EVM planted case merges to `main` unless the reachability leg
exits green (fail-on-all-N) for that case's planted project. If a new
case cannot certify at the default `(runs, depth)` budget, the case
owner:

1. Bumps `[invariant] runs` or `depth` in the case's `foundry.toml`
   until the leg certifies, OR
2. Documents an honest caveat in the case README stating the k / N
   number the case currently achieves at the standing budget.

The reachability leg is wired as a required matrix check in
`.github/workflows/atlas-all.yml`
(`evm-cases-reachability-multi-seed`) alongside the existing
`evm-cases`, `v4-hooks-cases` and `taiko-cases` matrices.

## Seed set

The seed list is a fixed, deterministic mix of small integers, common
test patterns, and pseudo-random-looking bytes. It is not regenerated
per run. See `ci/reachability_seeds.txt`.

## Reuse

The canonical runner this leg mirrors lives at
`scripts/reachability/run_foundry_reachability.sh` in the
`caliperforge/crypto-contributor` repo; same seeds file, same verdict
format used by `caliperforge/euler-earn-invariants`,
`caliperforge/soroban-invariant-atlas`,
`caliperforge/uniswap-v4-invariants`,
`caliperforge/hyperevm-safety` and `caliperforge/bsc-invariants`.
