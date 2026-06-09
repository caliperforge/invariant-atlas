// mango_market_ref — CLEAN twin for Atlas case 4 (Mango Markets, Oct 2022).
//
// Same-source twin of the vulnerable Mango-class oracle-priced
// collateral-and-borrow program with the bug class corrected. The only
// difference vs the `planted/` twin lives in the `compute_max_borrow`
// helper at the bottom of this file:
//
//   - the freshness check (`current_slot - oracle_slot ≤ FRESHNESS_BOUND_SLOTS`)
//   - the deviation-vs-TWAP check (`|oracle - twap| ≤ twap × DEVIATION_BOUND_BPS / BPS`)
//   - the `safe_price = min(oracle_price, twap_price)` clamp
//
// are present in the clean variant and removed in the planted variant.
// Everything else — the account layout, the instruction dispatchers,
// the storage struct, the error enum, the `logic` module that owns
// every other transition — is byte-identical. A
// `diff -r ../clean/programs/mango_market_ref/src ../planted/programs/mango_market_ref/src`
// shows the planted-bug hunk as a single localized region of
// `compute_max_borrow`.
//
// Bug class reconstructed (per Helius "Solana Hacks: A Complete History"
// + the Mango DAO incident post-mortem, Oct 2022):
//
//   The protocol valued the attacker's MNGO collateral using a single
//   spot oracle. The attacker pumped MNGO's spot price on a thin venue
//   (the oracle's source); the protocol's collateral valuation read
//   the inflated spot directly — no freshness window, no TWAP-floor
//   sanity bound, no min(spot, twap) clamp. With collateral marked at
//   the pumped price, the attacker borrowed all the USDC / SOL / BTC
//   on the other side and walked.
//
// Two properties detect this bug class on the planted twin and hold
// on this clean twin (driven by tests/atlas_invariants.rs):
//
//   A. borrow_power_validation. After every external transition, the
//      on-chain `borrowed` field never exceeds the borrow power
//      computed by the property-side oracle pipeline — i.e. with the
//      safe-price floor `min(oracle_price, twap_price)`.
//   B. oracle_freshness. After every transition where `borrowed > 0`,
//      the oracle the borrow was authorized against was within the
//      freshness bound at the moment of authorization.
//
// The clean fix (the minimal hunk that diffs against `planted/`):
//
//   `compute_max_borrow` returns `Err(StaleOracle)` if the oracle has
//   aged past `FRESHNESS_BOUND_SLOTS`, returns
//   `Err(OracleDeviationOutOfBound)` if `|oracle - twap|` exceeds
//   `twap × DEVIATION_BOUND_BPS / BPS_DENOM`, and (on the success
//   path) uses `safe_price = min(oracle_price, twap_price)` to value
//   collateral. The `try_borrow` helper propagates the error so the
//   on-chain `borrow` instruction reverts; nothing reaches the
//   post-step property check.
//
// Layout note: every transition's business logic lives in the
// inner `logic` module — pure functions over `&mut Market` that take
// no Anchor `Context`. The `#[program]` instruction handlers are
// thin wrappers that unpack `ctx.accounts.market` and delegate to
// `logic::*`. This is the same factoring `compute_max_borrow` uses,
// and it is what lets `tests/atlas_invariants.rs` drive the on-
// chain bug class directly without instantiating an Anchor
// `Context` or running an SBF VM. The test surface IS the on-chain
// surface; the planted bug is in the same `compute_max_borrow`
// function the instruction calls.
//
// License: Apache-2.0.
#![allow(unexpected_cfgs)]

use anchor_lang::prelude::*;

declare_id!("Mn111tRef1111111111111111111111111111111111");

/// Fixed-point scale for oracle prices. 1e6 matches Pyth's per-feed
/// `expo = -6` default; the constant is small enough to keep the
/// u128 intermediate arithmetic safely within range for the Atlas
/// scenario's deposit / borrow magnitudes (≤ 1e12).
pub const PRICE_SCALE: u64 = 1_000_000;
/// Basis-point denominator for the LTV and deviation bounds.
pub const BPS_DENOM: u64 = 10_000;
/// Maximum loan-to-value, in bps. 50% — conservative for a thin-book
/// collateral asset; matches the order-of-magnitude Mango's MNGO-class
/// margin tier used post-incident in the recovered protocol.
pub const LTV_BPS: u64 = 5_000;
/// Freshness bound in slots. 25 slots is ~10 s on Solana's ~400 ms
/// slot time. Pyth-class confidence-interval guidance suggests a
/// staleness window in this band for collateral-bearing instructions.
pub const FRESHNESS_BOUND_SLOTS: u64 = 25;
/// Deviation-vs-TWAP bound, in bps. 500 bps = 5%. A spot that has
/// moved more than 5% off its TWAP-window mid in a single update is
/// rejected as untrusted — this is the load-bearing Mango-class fix
/// (the attacker's pump moved oracle spot ~20× TWAP).
pub const DEVIATION_BOUND_BPS: u64 = 500;

#[program]
pub mod mango_market_ref {
    use super::*;

    pub fn initialize(
        ctx: Context<Initialize>,
        initial_oracle_price: u64,
        initial_twap_price: u64,
    ) -> Result<()> {
        let m = &mut ctx.accounts.market;
        m.authority = ctx.accounts.authority.key();
        logic::initialize(m, initial_oracle_price, initial_twap_price)?;
        Ok(())
    }

    /// Post a fresh spot price + the slot at which it was observed.
    pub fn update_oracle(ctx: Context<UpdateOracle>, price: u64, slot: u64) -> Result<()> {
        logic::update_oracle(&mut ctx.accounts.market, price, slot)?;
        Ok(())
    }

    /// Post the TWAP-window mid.
    pub fn update_twap(ctx: Context<UpdateOracle>, twap_price: u64) -> Result<()> {
        logic::update_twap(&mut ctx.accounts.market, twap_price)?;
        Ok(())
    }

    /// Advance the program's notion of `current_slot`. Real Solana
    /// programs read this from `Clock::sysvar`; for the Atlas twin we
    /// expose it as an instruction so the deterministic test can
    /// simulate the passage of time and exercise the freshness gate.
    pub fn tick_slot(ctx: Context<UpdateOracle>, delta: u64) -> Result<()> {
        logic::tick_slot(&mut ctx.accounts.market, delta);
        Ok(())
    }

    pub fn deposit_collateral(
        ctx: Context<DepositCollateral>,
        amount: u64,
    ) -> Result<()> {
        logic::deposit_collateral(&mut ctx.accounts.market, amount)?;
        Ok(())
    }

    /// Borrow against deposited collateral. Delegates to
    /// `logic::try_borrow` which calls `compute_max_borrow` for the
    /// freshness + deviation + safe-price-floor gate.
    pub fn borrow(ctx: Context<Borrow>, amount: u64) -> Result<()> {
        logic::try_borrow(&mut ctx.accounts.market, amount)?;
        Ok(())
    }

    pub fn repay(ctx: Context<Borrow>, amount: u64) -> Result<()> {
        logic::try_repay(&mut ctx.accounts.market, amount)?;
        Ok(())
    }
}

// ----- accounts / state -----

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(
        init,
        payer = authority,
        space = 8 + Market::INIT_SPACE,
        seeds = [b"market", authority.key().as_ref()],
        bump,
    )]
    pub market: Account<'info, Market>,
    #[account(mut)]
    pub authority: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct UpdateOracle<'info> {
    #[account(
        mut,
        seeds = [b"market", authority.key().as_ref()],
        bump,
        has_one = authority,
    )]
    pub market: Account<'info, Market>,
    pub authority: Signer<'info>,
}

#[derive(Accounts)]
pub struct DepositCollateral<'info> {
    #[account(
        mut,
        seeds = [b"market", authority.key().as_ref()],
        bump,
        has_one = authority,
    )]
    pub market: Account<'info, Market>,
    pub authority: Signer<'info>,
}

#[derive(Accounts)]
pub struct Borrow<'info> {
    #[account(
        mut,
        seeds = [b"market", authority.key().as_ref()],
        bump,
        has_one = authority,
    )]
    pub market: Account<'info, Market>,
    pub authority: Signer<'info>,
}

#[account]
#[derive(InitSpace)]
pub struct Market {
    pub authority: Pubkey,
    /// Last-posted spot oracle price, fixed-point scale `PRICE_SCALE`.
    pub oracle_price: u64,
    /// Slot at which `oracle_price` was observed.
    pub oracle_slot: u64,
    /// Current TWAP-window mid, fixed-point scale `PRICE_SCALE`.
    pub twap_price: u64,
    /// Program-tracked slot. Bumped by `tick_slot`; real protocols
    /// read this from the Clock sysvar.
    pub current_slot: u64,
    /// Cumulative deposited collateral, in collateral-asset units
    /// (lamports-equivalent at PRICE_SCALE / 1).
    pub deposited_collateral: u64,
    /// Outstanding borrowed amount, in stable-asset units.
    pub borrowed: u64,
    /// Property-side ledger. Updated on every `try_borrow` success
    /// to the high-water mark of the SAFE (canonical) max_borrow
    /// pipeline AT THAT INSTANT. The Property A invariant asserts
    /// `borrowed ≤ max_safe_borrow_ever_authorized` after every
    /// transition — captures the "no borrow against a manipulated
    /// oracle" intuition without requiring re-evaluation against
    /// post-borrow oracle drift (a real Mango run liquidates rather
    /// than reverts on benign drift; the bug class is authorization,
    /// not subsequent solvency). Maintained identically on both
    /// twins via `safe_max_borrow`, which is byte-identical between
    /// `clean/` and `planted/`; only `compute_max_borrow` (the gate)
    /// differs.
    pub max_safe_borrow_ever_authorized: u64,
}

#[error_code]
pub enum MangoError {
    InvalidAmount,
    InvalidPrice,
    Overflow,
    Underflow,
    StaleOracle,
    OracleDeviationOutOfBound,
    BorrowExceedsCollateralValue,
    RepayExceedsDebt,
}

// ----- the pure-logic module -----
//
// Every transition's business rule lives here as a `&mut Market`
// pure function so `tests/atlas_invariants.rs` can drive the same
// code the on-chain instructions dispatch to without instantiating
// an Anchor `Context` or booting an SBF VM. The planted twin's
// `compute_max_borrow` drops the three guards (freshness, deviation,
// safe-price floor); the rest of this module is byte-identical
// across the twins.

pub mod logic {
    use super::*;

    pub fn initialize(
        m: &mut Market,
        initial_oracle_price: u64,
        initial_twap_price: u64,
    ) -> std::result::Result<(), MangoError> {
        if initial_oracle_price == 0 || initial_twap_price == 0 {
            return Err(MangoError::InvalidPrice);
        }
        m.oracle_price = initial_oracle_price;
        m.twap_price = initial_twap_price;
        m.oracle_slot = 0;
        m.current_slot = 0;
        m.deposited_collateral = 0;
        m.borrowed = 0;
        m.max_safe_borrow_ever_authorized = 0;
        Ok(())
    }

    pub fn update_oracle(
        m: &mut Market,
        price: u64,
        slot: u64,
    ) -> std::result::Result<(), MangoError> {
        if price == 0 {
            return Err(MangoError::InvalidPrice);
        }
        m.oracle_price = price;
        m.oracle_slot = slot;
        Ok(())
    }

    pub fn update_twap(
        m: &mut Market,
        twap_price: u64,
    ) -> std::result::Result<(), MangoError> {
        if twap_price == 0 {
            return Err(MangoError::InvalidPrice);
        }
        m.twap_price = twap_price;
        Ok(())
    }

    pub fn tick_slot(m: &mut Market, delta: u64) {
        m.current_slot = m.current_slot.saturating_add(delta);
    }

    pub fn deposit_collateral(
        m: &mut Market,
        amount: u64,
    ) -> std::result::Result<(), MangoError> {
        if amount == 0 {
            return Err(MangoError::InvalidAmount);
        }
        m.deposited_collateral = m
            .deposited_collateral
            .checked_add(amount)
            .ok_or(MangoError::Overflow)?;
        Ok(())
    }

    pub fn try_borrow(
        m: &mut Market,
        amount: u64,
    ) -> std::result::Result<(), MangoError> {
        if amount == 0 {
            return Err(MangoError::InvalidAmount);
        }
        let max = compute_max_borrow(m)?;
        let new_borrowed = m
            .borrowed
            .checked_add(amount)
            .ok_or(MangoError::Overflow)?;
        if new_borrowed > max {
            return Err(MangoError::BorrowExceedsCollateralValue);
        }
        m.borrowed = new_borrowed;
        // Ledger update: ratchet the safe-pipeline high-water mark.
        // On CLEAN, `compute_max_borrow == safe_max_borrow` so the
        // ratchet covers every successful borrow. On PLANTED, the
        // unsafe gate admits borrows where `safe_max_borrow` returns
        // `None`; the ratchet does NOT advance, so the post-step
        // property check finds `borrowed > max_safe_borrow_ever_
        // authorized` and fires.
        if let Some(safe_max) = safe_max_borrow(m) {
            if safe_max > m.max_safe_borrow_ever_authorized {
                m.max_safe_borrow_ever_authorized = safe_max;
            }
        }
        Ok(())
    }

    pub fn try_repay(
        m: &mut Market,
        amount: u64,
    ) -> std::result::Result<(), MangoError> {
        if amount == 0 {
            return Err(MangoError::InvalidAmount);
        }
        if amount > m.borrowed {
            return Err(MangoError::RepayExceedsDebt);
        }
        m.borrowed -= amount;
        Ok(())
    }
}

// ----- the load-bearing pure helper -----
//
// CLEAN-twin contract:
//   1. `current_slot - oracle_slot ≤ FRESHNESS_BOUND_SLOTS`  → else `StaleOracle`
//   2. `|oracle - twap| ≤ twap × DEVIATION_BOUND_BPS / BPS`  → else `OracleDeviationOutOfBound`
//   3. value collateral at `min(oracle_price, twap_price)`   → the safe floor
//
// The PLANTED twin's `compute_max_borrow` is the only diff vs this
// file — see `planted/programs/mango_market_ref/src/lib.rs`.
pub fn compute_max_borrow(m: &Market) -> std::result::Result<u64, MangoError> {
    let age = m.current_slot.saturating_sub(m.oracle_slot);
    if age > FRESHNESS_BOUND_SLOTS {
        return Err(MangoError::StaleOracle);
    }
    let delta = m.oracle_price.abs_diff(m.twap_price);
    let allowed = ((m.twap_price as u128) * (DEVIATION_BOUND_BPS as u128)
        / (BPS_DENOM as u128)) as u64;
    if delta > allowed {
        return Err(MangoError::OracleDeviationOutOfBound);
    }
    let safe_price = core::cmp::min(m.oracle_price, m.twap_price);
    let value = (m.deposited_collateral as u128)
        .saturating_mul(safe_price as u128)
        / (PRICE_SCALE as u128);
    Ok(((value * (LTV_BPS as u128)) / (BPS_DENOM as u128)) as u64)
}

/// The canonical "safe" max-borrow pipeline. Byte-identical between
/// the clean and planted twins — this is the variant-independent
/// reference the ledger ratchets against. The clean twin's
/// `compute_max_borrow` IS this function; the planted twin's
/// `compute_max_borrow` skips all three guards. By splitting the
/// gate from the ledger reference, the property surface stays
/// variant-blind: every twin computes the same `safe_max_borrow`,
/// and the only thing that varies is whether the on-chain `borrow`
/// instruction enforced it.
///
/// Returns `None` when the canonical pipeline rejects the oracle
/// (stale OR deviation out of bound) — i.e. the safe ceiling
/// collapses to 0. The ledger does not advance against a `None`.
pub fn safe_max_borrow(m: &Market) -> Option<u64> {
    let age = m.current_slot.saturating_sub(m.oracle_slot);
    if age > FRESHNESS_BOUND_SLOTS {
        return None;
    }
    let delta = m.oracle_price.abs_diff(m.twap_price);
    let allowed = ((m.twap_price as u128) * (DEVIATION_BOUND_BPS as u128)
        / (BPS_DENOM as u128)) as u64;
    if delta > allowed {
        return None;
    }
    let safe_price = core::cmp::min(m.oracle_price, m.twap_price);
    let value = (m.deposited_collateral as u128)
        .saturating_mul(safe_price as u128)
        / (PRICE_SCALE as u128);
    Some(((value * (LTV_BPS as u128)) / (BPS_DENOM as u128)) as u64)
}
