# Atlas case 4 — Mango Markets (Solana / Anchor, Oct 2022)

**Exploit:** Mango Markets perp / lending program drained, ~$117M,
Oct 2022 (Avraham Eisenberg).
**Bug class:** Oracle price manipulation. The attacker pumped the spot
price of MNGO on a low-liquidity venue. The protocol's collateral
valuation read that spot price directly — with no freshness check, no
deviation bound vs. a TWAP / multi-source floor, and no per-instruction
sanity gate — so the attacker's MNGO collateral was marked at the
inflated price and they borrowed against it to drain the protocol's
USDC / SOL / BTC books.
**Invariant class:** oracle freshness + price-sanity bound. Collateral
valuation must use a price that is (a) recent (`slot - feed_slot ≤
FRESHNESS_BOUND`), (b) within a bounded deviation of a TWAP / multi-
source floor, and (c) clamped to the conservative leg
(`safe_price = min(spot, twap)`); borrow power must never exceed the
collateral value computed against that safe price.

## Post-mortem sources (primary)

- Helius — "Solana Hacks: A Complete History" entry for Mango Markets
  (Oct 2022) — public root-cause walkthrough of the spot-price-feed
  manipulation path.
- Mango Markets DAO incident post-mortem + the publicly-documented
  Eisenberg post-trade self-disclosure (carries the attacker's
  high-level sequence; the Atlas does NOT republish the attacker's
  calldata).
- Rekt entry — public timeline + the on-chain attacker addresses.

(URLs are carried as published; the Atlas does not republish the
attacker's tx-level calldata.)

## What this case ships

A minimal Anchor (anchor-lang 1.0.1) same-source twin of an oracle-
priced collateral-valuation-and-borrow program with the Mango bug
class planted, the canonical defender-side fix applied to the clean
twin, and a paired-CI run that asserts both legs.

```
04-solana-mango/
  clean/         # Cargo workspace: pre-exploit Anchor with the canonical fix
    Cargo.toml
    programs/mango_market_ref/
      Cargo.toml
      src/lib.rs
      tests/atlas_invariants.rs
  planted/       # Cargo workspace: same-source twin with bug planted
    Cargo.toml                          # byte-identical to clean/
    programs/mango_market_ref/
      Cargo.toml                        # byte-identical to clean/
      src/lib.rs                        # <-- ONLY this file differs from clean/
      tests/atlas_invariants.rs           # byte-identical to clean/
  scorecard.clean.md
  scorecard.planted.md
  README.md
```

A `diff -r clean/programs planted/programs` shows the planted hunk as a
single localized change to `mango_market_ref/src/lib.rs` — the
`compute_max_borrow` path drops the freshness check, the deviation-vs-
TWAP check, and the `safe_price = min(spot, twap)` floor. The property
test and the workspace manifest are byte-identical between twins.

## The bug class, reconstructed

The vulnerable `borrow` accepts the raw spot oracle:

```rust
// PLANTED (planted/programs/mango_market_ref/src/lib.rs):
// no freshness check, no deviation check, no min(spot, twap) floor.
fn compute_max_borrow(market: &Market) -> u64 {
    let value = (market.deposited_collateral as u128)
        .saturating_mul(market.oracle_price as u128)
        / PRICE_SCALE as u128;
    ((value * LTV_BPS as u128) / BPS_DENOM as u128) as u64
}
```

The clean fix:

```rust
// CLEAN (clean/programs/mango_market_ref/src/lib.rs):
fn compute_max_borrow(market: &Market) -> std::result::Result<u64, MangoError> {
    // (a) freshness:
    if market.current_slot.saturating_sub(market.oracle_slot)
        > FRESHNESS_BOUND_SLOTS
    {
        return Err(MangoError::StaleOracle);
    }
    // (b) deviation vs. TWAP floor:
    let delta = market.oracle_price.abs_diff(market.twap_price);
    let allowed =
        (market.twap_price as u128 * DEVIATION_BOUND_BPS as u128 / BPS_DENOM as u128) as u64;
    if delta > allowed {
        return Err(MangoError::OracleDeviationOutOfBound);
    }
    // (c) clamp to the conservative leg:
    let safe_price = core::cmp::min(market.oracle_price, market.twap_price);
    let value = (market.deposited_collateral as u128)
        .saturating_mul(safe_price as u128)
        / PRICE_SCALE as u128;
    Ok(((value * LTV_BPS as u128) / BPS_DENOM as u128) as u64)
}
```

The canonical attack sequence on the planted twin:

```
attacker.deposit_collateral(1_000)              total=1_000, oracle=100, twap=100
                                                safe-priced max_borrow = 50
                                                (1000 * 100 / 1_000_000 * 50% = 50)
attacker.update_oracle(price=2_000, slot=0)     oracle=2_000  (20x pump)
attacker.borrow(700)                            planted max_borrow:
                                                  1000 * 2000 / 1_000_000 * 50% = 1_000
                                                  700 < 1_000 → ACCEPTED
                                                clean max_borrow:
                                                  delta=1_900 > allowed=5 (5% of 100) → REJECTED
                                                  (clean panics at the require_borrow_within_max gate)
                                                attacker has borrowed 700 against
                                                collateral worth (at safe price) 50.
```

The clean twin blocks the sequence at step 3: `borrow(700)` reverts
with `OracleDeviationOutOfBound`. The attacker cannot borrow against
the pumped price; both properties hold trivially.

## The properties

### Property A — borrow-power validation against the safe price

After every external transition, the on-chain `borrowed` field never
exceeds the borrow power computed by the property-side oracle pipeline
(freshness-checked, deviation-bounded, floored at
`min(spot, twap)`):

```
borrowed ≤ deposited_collateral × min(oracle_price, twap_price)
                              × LTV_BPS / BPS_DENOM / PRICE_SCALE
```

The planted twin's `borrow` uses the raw `oracle_price` without the
`min(.)` floor; once the attacker pumps the oracle to 2000 against a
TWAP of 100, a single `borrow(700)` produces `borrowed=700` while the
safe-priced max is `50` — Property A fires, marker
`"INVARIANT VIOLATED borrow_power_validation"` is emitted.

### Property B — oracle freshness bound

After every external transition, if `borrowed > 0` the oracle the
borrow was authorized against was within the freshness bound at the
moment of authorization:

```
current_slot - oracle_slot ≤ FRESHNESS_BOUND_SLOTS  whenever borrowed > 0
                                                    (at the post-borrow step)
```

The clean twin enforces this on every `borrow`. The planted twin
omits it: an attacker can let the oracle go stale (`tick_slot` past
the bound) and still borrow against the last posted price. Property B
fires on the post-borrow check, marker
`"INVARIANT VIOLATED oracle_freshness"`.

## How to reproduce locally

Requires Rust `stable` (1.75+) and `cargo`. No SBF toolchain is
required for the property tests — the Anchor program crate compiles
on the host (anchor-lang 1.0.1 supports host-target builds), and the
test harness drives the same `compute_max_borrow` pure-function path
that the on-chain `borrow` handler dispatches to.

```sh
# clean leg — all properties hold
cd clean
cargo test --release
# Expected: 5 passed, 0 failed (1 lib unit test + 4 integration tests).

# planted leg — properties fire
cd ../planted
cargo test --release
# Expected: 2 passed, 3 failed; all three failures carry the
# `INVARIANT VIOLATED` marker on stdout.
```

Scorecard captures from a verified-2026-06-08 local run are in
[`scorecard.clean.md`](scorecard.clean.md) and
[`scorecard.planted.md`](scorecard.planted.md).

## What this case does NOT claim

- This is NOT a fork of Mango Markets' production source. The
  reconstructed market is the minimal collateral-valuation-and-borrow
  primitive priced off a single oracle needed to exercise the bug
  class; the protocol's full feature set (perps engine, multi-asset
  margin, liquidator path, on-chain orderbook, governance, MNGO
  token) is out of scope.
- The Atlas does NOT claim CaliperForge found the Mango exploit live.
  The property surface here is what the protocol could have wired
  into CI before mainnet; it is not a runtime guard and not a
  formal-verification proof.
- The constants (`FRESHNESS_BOUND_SLOTS = 25`,
  `DEVIATION_BOUND_BPS = 500`, `LTV_BPS = 5_000`,
  `PRICE_SCALE = 1_000_000`) are illustrative for the Atlas twin; a
  production market would calibrate them against the asset's price
  feed volatility, TWAP window, expected redemption flow, and the
  liquidator coverage profile.

## Disclosure

The invariant surface (Property A + Property B) was proposed by the
Rust/Anchor Specialist agent (model: `claude-opus-4-6`) against the
published Helius / Mango DAO post-mortems and accepted by the case
author. The same-source twin reconstruction was authored by the same
specialist agent. See [`../../AI_DISCLOSURE.md`](../../AI_DISCLOSURE.md).

Apache-2.0. Operator: Michael Moffett — michael@caliperforge.com —
team@caliperforge.com.
