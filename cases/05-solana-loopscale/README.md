# Atlas case 5 — Loopscale (Solana / Anchor, Apr 2025)

**Exploit:** Loopscale mainnet lending market drained, ~$5.8M (~5.7M
USDC + ~1,200 SOL), Apr 2025.
**Bug class:** the attacker manipulated the pricing of RateX
Principal Token (PT) collateral against a single-source on-chain
oracle, inflated PT's perceived value, then took a series of
undercollateralized loans against the inflated collateral.
**Invariant class:** collateral-valuation / oracle bound — PT (or
any) collateral must be priced within a validated bound, and no
borrow may settle that exceeds the conservatively-priced collateral
value × LTV_max.

## Post-mortem sources (primary)

- The Block — *"Loopscale loses $5.8 million in attack"*, Apr 26 2025
  (lending-market RateX PT exploit; ~$5.8M total; primary date-of-loss
  report).
- Cryptopolitan — Apr 26 2025 follow-up on the same incident
  (corroborates loss figure and collateral path).
- Loopscale incident notes — protocol-side post-mortem on the
  Loopscale Twitter / forum (RateX PT collateral mispricing as root
  cause; carried as published).
- Rekt entry — public timeline + on-chain attacker txn references.

URLs are carried as published; the Atlas does not republish the
attacker's calldata. Source list reflects what the case author and
the AI specialist had read at the time of authoring; the load-bearing
post-mortem fact for the Atlas — "Loopscale's pricing of RateX PT
collateral was the manipulable surface, and undercollateralized loans
against it drained the pool" — is consistent across all four.

## What this case ships

A minimal Anchor 1.0.x same-source twin of the PT-collateral
valuation + borrow path with the Loopscale bug class planted, the
canonical defender-side fix applied to the clean twin, and a
paired-CI run that asserts both legs.

```
05-solana-loopscale/
  clean/         # Cargo workspace: pre-exploit Anchor program with the canonical fix
    Cargo.toml
    programs/loopscale_market/
      Cargo.toml
      src/lib.rs
      tests/atlas_invariants.rs
  planted/       # Cargo workspace: same-source twin with bug planted
    Cargo.toml                                # byte-identical to clean/
    programs/loopscale_market/
      Cargo.toml                              # byte-identical to clean/
      src/lib.rs                              # <-- ONLY this file differs from clean/
      tests/atlas_invariants.rs               # byte-identical to clean/
  scorecard.clean.md
  scorecard.planted.md
  README.md
  .gitignore
```

A `diff -r clean/ planted/` shows the planted hunk as a single
localized change to `programs/loopscale_market/src/lib.rs` — the
clean twin's `min(p_oracle, twap_floor)` price-floor + the
safety-margin + the LTV check on borrow are removed. The test file
and the Cargo manifests do not change between twins.

## The bug class, reconstructed

Loopscale's pricing path for RateX PT collateral consumed an on-chain
spot oracle whose state could be moved by the attacker within a
single transaction bundle. The vulnerable `borrow` on the planted
twin trusts the latest spot:

```rust
// PLANTED (programs/loopscale_market/src/lib.rs):
let effective_price = market.pt_oracle_price;       // <-- raw spot
let collateral_value = (position.pt_collateral as u128)
    .checked_mul(effective_price as u128).unwrap();
let max_borrow = collateral_value
    .checked_mul(market.ltv_max_bps as u128).unwrap() / 10_000;
require!(
    (position.borrowed_value as u128) + (amount as u128) <= max_borrow,
    LoopError::Undercollateralized,
);
```

The clean fix:

```rust
// CLEAN (programs/loopscale_market/src/lib.rs):
// Use the lower of (a) the current on-chain spot oracle and (b) the
// conservatively-accrued TWAP floor maintained by the protocol. An
// attacker can move the spot for the duration of one transaction; the
// twap_floor is the cheapest mechanically-credible bound that
// neutralizes that lever.
let effective_price = core::cmp::min(market.pt_oracle_price, market.pt_twap_floor);
let collateral_value = (position.pt_collateral as u128)
    .checked_mul(effective_price as u128).unwrap()
    .checked_mul(market.safety_margin_bps as u128).unwrap() / 10_000;
let max_borrow = collateral_value
    .checked_mul(market.ltv_max_bps as u128).unwrap() / 10_000;
require!(
    (position.borrowed_value as u128) + (amount as u128) <= max_borrow,
    LoopError::Undercollateralized,
);
```

Plus: clean's `borrow` records the `effective_price` it used on the
market account (`last_borrow_effective_price`), so the property test
can read it post-step. Planted does the same — the field is in both
twins; the planted twin just writes a value that violates Property A.

The canonical attack sequence on the planted twin:

```
admin.init_market(pt_twap_floor = 1.00 USDC, ltv_max_bps = 7500, safety_margin = 9000)
admin.update_pt_oracle_price(1.00 USDC)
attacker.deposit_collateral(100 PT)
attacker.update_pt_oracle_price(5.00 USDC)      # <-- the manipulation
attacker.borrow(370 USDC)                       # 100 PT * 5.00 * 0.75 = 375 ≥ 370
                                                # property A fires: used_price=5.00 > twap_floor=1.00
                                                # property B fires: borrowed=370 > 100*1.00*0.75=75
```

The clean twin blocks the borrow at the last step: `effective_price
= min(5.00, 1.00) = 1.00`; `max_borrow = 100 * 1.00 * 0.90 * 0.75 =
67.5`; `require!(370 <= 67.5)` fails with `Undercollateralized`. The
attack cannot proceed; both properties hold trivially.

## The properties

### Property A — collateral-valuation / oracle bound

After every `borrow`, the price the market used to value collateral
must not exceed the conservative TWAP floor (within the
safety-margin scaling). Concretely:

```
market.last_borrow_effective_price <= market.pt_twap_floor
```

The planted twin's `borrow` writes `last_borrow_effective_price =
pt_oracle_price`, which after the attacker's spike is `5.00 >
twap_floor=1.00` — violates the bound; the marker
`"INVARIANT VIOLATED collateral_valuation_bound"` is emitted on the
post-step check.

The clean twin writes `last_borrow_effective_price = min(spot,
twap_floor)`, so the bound holds by construction.

### Property B — no undercollateralized borrow can settle

After every external transition, for every position, the borrowed
value must be backed by the conservatively-priced collateral × LTV
ratio:

```
for every position p:
  p.borrowed_value * 10_000  <=  p.pt_collateral * market.pt_twap_floor * market.ltv_max_bps
```

The clean twin holds this strictly because the `borrow` path values
collateral at `min(spot, twap_floor) * safety_margin` and gates the
borrow at LTV_max of that valuation — the borrow always sits below
the twap-floor-LTV ceiling. The planted twin's attacker borrows
~5× the twap-floor-LTV-bounded amount; the marker
`"INVARIANT VIOLATED borrow_solvency"` is emitted.

## How to reproduce locally

Requires `rustc 1.79+` (stable; this is the rust-version in the
program Cargo.toml). No Solana CLI / `cargo-build-sbf` is required to
run the Atlas test — the program is exercised as a Rust library via
its pure-logic methods. See "Toolchain choice" below for the
rationale.

```sh
# clean leg — all properties hold
cd clean
cargo test --release
# Expected: all tests pass (deterministic attack test + property test
# + unit coverage).

# planted leg — properties fire
cd ../planted
cargo test --release
# Expected: ≥1 INVARIANT VIOLATED marker emitted; cargo test exits
# non-zero.
```

Scorecard captures from a verified-2026-06-08 local run are in
[`scorecard.clean.md`](scorecard.clean.md) and
[`scorecard.planted.md`](scorecard.planted.md).

## Toolchain choice (why pure-Rust, not full LiteSVM / Crucible rails)

The cf-invariants-anchor + Crucible CI pattern that the existing
CaliperForge Solana harnesses use compiles the Anchor program to a
Solana `.so` via `cargo-build-sbf` and drives it from a sibling
Crucible clone using LiteSVM. That pattern is what `cf-invariants-
anchor` and the three Jito ports ship.

For the Atlas v0.1, the case 5 author elected to ship a lighter
testing rail:

1. The program crate is built as a normal Rust library (`cdylib +
   lib`). Tests call the program's pure-logic methods on the
   `Market` / `Position` types directly. The Anchor program SHAPE
   (`declare_id!`, `#[program]`, `#[derive(Accounts)]`, `#[account]`
   on the state structs) is preserved verbatim — the diff against an
   `.so`-deployable Anchor program is one feature flag in
   `Cargo.toml`.
2. The Atlas's CI bar is: *clean → 0 violations; planted → ≥1
   `INVARIANT VIOLATED` marker.* The pure-Rust test rail meets that
   bar deterministically and cheaply; the full LiteSVM rail meets it
   with substantial CI weight (Solana CLI install, platform-tools
   pin, sibling Crucible build, `cargo-build-sbf`).
3. The Atlas is an evaluation rig per the spec §5.3 tie-in. It does
   NOT need to deploy. The Loopscale invariant class — collateral
   valuation against a price floor — is a pure-state property; the
   on-chain machinery around it (signature verification, account
   ownership, lamport movement) is not part of the bug class.

This is documented for the next Solana case (Cashio / Mango) so the
author can decide whether the lighter pure-Rust rail is sufficient
for their invariant class or whether the full Crucible LiteSVM rail
is the right call. The shared `setup-solana` composite action in
this repo's `.github/actions/setup-solana/` ships the lighter shape
(stable Rust toolchain + cache); a Crucible-LiteSVM-using case
extends it inline rather than clobbering it.

## What this case does NOT claim

- This is NOT a fork of Loopscale's production source. The
  reconstructed market is the minimal collateral-valuation-and-borrow
  primitive needed to exercise the bug class; the protocol's full
  feature set (multi-collateral, interest accrual, liquidation
  engine, RateX-specific PT redemption logic, governance) is out of
  scope.
- The Atlas does NOT claim CaliperForge found the Loopscale exploit
  live. The property surface here is what the protocol could have
  wired into CI before mainnet; it is not a runtime guard and not a
  formal-verification proof.
- The "USDC", "PT", "SOL" labels are illustrative; the property
  surface is denominated in abstract `price` and `quantity` units.
  A production market would calibrate `pt_twap_floor`,
  `safety_margin_bps`, and `ltv_max_bps` against the asset's
  decimals, the oracle update cadence, the TWAP-accrual window, and
  the expected volume profile.
- The "5×" inflation in the deterministic attack test is the smallest
  multiplier that cleanly trips both Property A and Property B on the
  planted twin within the chosen LTV / safety-margin numbers. The
  actual on-chain Loopscale attack used a multi-step PT-pricing
  manipulation against the RateX product; the deterministic Atlas
  test compresses that into a single oracle update for clarity.

## Disclosure

The invariant surface (Property A + Property B) was proposed by the
Rust/Anchor Specialist agent (model: `claude-opus-4-7`) against the
published Loopscale post-mortem material, and accepted by the case
author. The same-source twin reconstruction (the planted
`pt_oracle_price`-trust hunk; the clean `min(spot, twap_floor)` +
safety-margin + LTV gate) was authored by the same specialist agent.
See [`../../AI_DISCLOSURE.md`](../../AI_DISCLOSURE.md).

Apache-2.0. Operator: Michael Moffett — michael@caliperforge.com —
team@caliperforge.com.
