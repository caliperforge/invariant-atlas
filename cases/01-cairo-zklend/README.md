# Atlas case 1 — zkLend (Cairo / Starknet, Feb 2025)

**Exploit:** zkLend mainnet lending market drained, ~$10M, Feb 2025.
**Bug class:** empty-market init + flash-loan "donation" inflates the
lending accumulator; subsequent deposits round-truncate to zero shares
while still crediting the underlying; attacker withdraws on a single
share to drain the pool.
**Invariant class:** accumulator monotonicity / empty-market deposit
guard + per-user round-trip non-amplification.

## Post-mortem sources (primary)

- BlockSec post-mortem (Feb 2025) — root-cause walkthrough of the
  `lending_accumulator` inflation path on the empty market.
- Halborn write-up — same incident, focuses on the rounding-truncation
  half of the bug class.
- zkLend Medium incident report — protocol-side disclosure.
- Rekt entry — public timeline + on-chain attacker txns.

(URLs are carried as published; the Atlas does not republish the
attacker's calldata.)

## What this case ships

A minimal Cairo 2.x same-source twin of a share-accounted lending
market with the zkLend bug class planted, the canonical defender-side
fix applied to the clean twin, and a paired-CI run that asserts both
legs.

```
01-cairo-zklend/
  clean/         # Scarb project: pre-exploit Cairo with the canonical fix
    src/lib.cairo
    tests/atlas_invariants.cairo
    Scarb.toml
  planted/       # Scarb project: same-source twin with bug planted
    src/lib.cairo               # <-- ONLY this file differs from clean/
    tests/atlas_invariants.cairo  # byte-identical to clean/
    Scarb.toml                  # byte-identical to clean/
  scorecard.clean.md
  scorecard.planted.md
  README.md
```

A `diff -r clean/ planted/` shows the planted hunk as a single
localized change to `src/lib.cairo` — empty-market guard, dead-shares
burn, and `donate` gate removed. The property test and the scarb
manifest do not change between twins.

## The bug class, reconstructed

The vulnerable `deposit` on an empty market:

```cairo
// PLANTED (atlas_c1_zklend/planted/src/lib.cairo):
let shares_to_mint = if shares_total == 0_u256 {
    // empty market mints 1:1 with no minimum
    amount
} else {
    // TRUNCATING division; no `assert s > 0`
    (amount * shares_total) / assets
};
```

The clean fix:

```cairo
// CLEAN (atlas_c1_zklend/clean/src/lib.cairo):
let shares_to_mint = if shares_total == 0_u256 {
    assert!(amount >= MIN_INIT_DEPOSIT, "empty-market: amount < MIN_INIT_DEPOSIT");
    self.shares.write(dead_sentinel(), MIN_INIT_SHARES);
    amount - MIN_INIT_SHARES
} else {
    let s = (amount * shares_total) / assets;
    assert!(s > 0_u256, "deposit would mint zero shares");
    s
};
```

Plus: clean's `donate` requires the market to be bootstrapped
(`total_shares > 0`) and caps per-call donation at
`DONATE_RATIO_BPS` of `total_assets`. Planted's `donate` is
permissionless.

The canonical attack sequence on the planted twin:

```
attacker.deposit(1)        →  total_shares=1,    total_assets=1
attacker.donate(10_000)    →  total_shares=1,    total_assets=10_001
victim.deposit(5_000)      →  total_shares=1,    total_assets=15_001
                              (5000 * 1 / 10_001 = 0 shares minted to victim)
attacker.withdraw(1)       →  attacker receives 15_001 wei
                              (deposited=1, withdrawn=15_001 → property B fires)
```

The clean twin blocks the sequence at step 1: `deposit(1)` reverts
with `"empty-market: amount < MIN_INIT_DEPOSIT"`. The attack cannot
proceed; both properties hold trivially.

## The properties

### Property A — accumulator monotonicity / empty-market deposit guard

After every external transition, the share-count is either zero or
above the minimum-init threshold; the symmetric case (no underlying
without shares) is folded in:

```
total_shares == 0  OR  total_shares >= MIN_INIT_SHARES   (1000 raw units)
total_shares >  0  OR  total_assets == 0
```

The planted twin's `deposit(1)` produces `total_shares == 1` —
violates the lower bound; the marker
`"INVARIANT VIOLATED accumulator_empty_market_guard"` is emitted
on the post-step check.

### Property B — round-trip non-amplification (per-user conservation)

After every external transition, for every user, withdrawn never
exceeds deposited:

```
for every user u, at every step:
  withdrawn(u) <= deposited(u)
```

The clean twin holds this strictly because `donate` is gated to
bootstrapped markets with a per-step cap, and the dead-shares burn
keeps the accumulator at 1:1 under normal operation. The planted
twin's attacker withdraws ~15× their deposit; the marker
`"INVARIANT VIOLATED round_trip_conservation"` is emitted.

## How to reproduce locally

Requires `scarb 2.18.0` and `snforge 0.60.x` or `0.61.x`.

```sh
# clean leg — all properties hold
cd clean
scarb build
snforge test
# Expected: 4 passed, 0 failed.

# planted leg — properties fire
cd ../planted
scarb build
snforge test
# Expected: 2 passed, 2 failed, both failures carry the
# `INVARIANT VIOLATED` marker.
```

Scorecard captures from a verified-2026-06-08 local run are in
[`scorecard.clean.md`](scorecard.clean.md) and
[`scorecard.planted.md`](scorecard.planted.md).

## What this case does NOT claim

- This is NOT a fork of zkLend's production source. The reconstructed
  market is the minimal share-accounted lending primitive needed to
  exercise the bug class; the protocol's full feature set
  (multi-asset, interest accrual, oracle layer, governance, etc.) is
  out of scope.
- The Atlas does NOT claim CaliperForge found the zkLend exploit
  live. The property surface here is what the protocol could have
  wired into CI before mainnet; it is not a runtime guard and not a
  formal-verification proof.
- The "1000 raw units" thresholds are illustrative for the Atlas
  twin; a production market would calibrate `MIN_INIT_DEPOSIT` and
  the dead-shares burn against the asset's smallest unit, decimals,
  and expected volume profile.

## Disclosure

The invariant surface (Property A + Property B) was proposed by the
Cairo Specialist agent (model: `claude-opus-4-6`) against the
published BlockSec / Halborn post-mortems and accepted by the case
author. The same-source twin reconstruction was authored by the same
specialist agent. See [`../../AI_DISCLOSURE.md`](../../AI_DISCLOSURE.md).

Apache-2.0. Operator: Michael Moffett — michael@caliperforge.com —
team@caliperforge.com.
