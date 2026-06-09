// loopscale_market — PLANTED twin for Atlas case 5 (Loopscale, Apr 2025).
//
// Same-source twin of the vulnerable Loopscale PT-collateral
// valuation + borrow path with the bug class PLANTED. The borrow
// path here trusts the manipulable spot oracle directly — no
// `min(spot, twap_floor)` floor, no safety-margin scaling. This is
// the load-bearing bug class that the Atlas's property surface
// detects.
//
// A `diff -r ../clean/programs ../planted/programs` shows the only
// hunk vs. the clean twin is `Market::borrow_logic` — every other
// file (Cargo.toml, tests/atlas_invariants.rs, the program shape,
// the state structs, the instruction handlers) is byte-identical.
//
// Bug class reconstructed (per The Block / Cryptopolitan / Loopscale
// incident notes, Apr 2025):
//
//   Loopscale's pricing for RateX Principal Token (PT) collateral
//   consumed an on-chain spot oracle whose state could be moved by
//   the attacker within a single transaction bundle. The borrow
//   path valued PT collateral at the spot oracle without bounding
//   against a conservative TWAP floor. The attacker manipulated PT
//   price upward, took a series of undercollateralized loans
//   (~5.7M USDC + ~1,200 SOL) against the inflated collateral, and
//   walked away from the position when the price reverted.
//
// The properties that catch this on the test rail (driven by
// tests/atlas_invariants.rs — byte-identical between twins):
//
//   A. collateral-valuation / oracle bound:
//        market.last_borrow_effective_price <= market.pt_twap_floor
//      This twin writes raw spot here; after an attacker spike,
//      spot > twap_floor → marker emitted.
//
//   B. no undercollateralized borrow can settle:
//        p.borrowed_value * 10_000  <=
//          p.pt_collateral * market.pt_twap_floor * market.ltv_max_bps
//      This twin gates against spot-priced collateral, so a spike
//      lets the attacker borrow above the floor-LTV ceiling → marker
//      emitted.
//
// License: Apache-2.0.
#![allow(unexpected_cfgs)]

use anchor_lang::prelude::*;

declare_id!("Lp111tRef1111111111111111111111111111111111");

/// BPS denominator. 10_000 bps = 100%.
pub const BPS_DENOM: u128 = 10_000;

#[program]
pub mod loopscale_market {
    use super::*;

    /// Initialize the market with the conservative TWAP floor, the
    /// safety-margin scaling, and the LTV_max — values that an audited
    /// production market would set at deploy and update through
    /// governance.
    pub fn init_market(
        ctx: Context<InitMarket>,
        pt_twap_floor: u64,
        safety_margin_bps: u16,
        ltv_max_bps: u16,
    ) -> Result<()> {
        let market = &mut ctx.accounts.market;
        market.admin = ctx.accounts.admin.key();
        market.pt_oracle_price = 0;
        market.pt_twap_floor = pt_twap_floor;
        market.safety_margin_bps = safety_margin_bps;
        market.ltv_max_bps = ltv_max_bps;
        market.last_borrow_effective_price = 0;
        Ok(())
    }

    /// Submit a new spot price for PT collateral. The attacker's
    /// manipulation surface — anyone can call this in the twin (in
    /// production this would be the oracle provider, and the bug
    /// class is "the provider's price is manipulable").
    pub fn update_pt_oracle_price(ctx: Context<UpdateOracle>, new_price: u64) -> Result<()> {
        ctx.accounts.market.pt_oracle_price = new_price;
        Ok(())
    }

    /// Admin-only: update the TWAP floor. In production this would
    /// accrue over a window from off-chain or from a separate TWAP
    /// program; the twin lets the admin set it directly.
    pub fn update_pt_twap_floor(ctx: Context<UpdateTwapFloor>, new_floor: u64) -> Result<()> {
        ctx.accounts.market.pt_twap_floor = new_floor;
        Ok(())
    }

    /// Open or top-up a position with PT collateral.
    pub fn deposit_collateral(ctx: Context<DepositCollateral>, amount: u64) -> Result<()> {
        require!(amount > 0, LoopError::InvalidAmount);
        let pos = &mut ctx.accounts.position;
        pos.owner = ctx.accounts.user.key();
        pos.pt_collateral = pos
            .pt_collateral
            .checked_add(amount)
            .ok_or(LoopError::Overflow)?;
        Ok(())
    }

    /// Borrow `amount` value-units against the caller's position.
    ///
    /// This is the bug-class boundary. The PLANTED path:
    ///   1. Sets `effective_price = pt_oracle_price` directly
    ///      (no floor). <-- THE BUG.
    ///   2. Computes `collateral_value = pt_collateral *
    ///      effective_price` (no safety-margin scaling). <-- THE
    ///      BUG (omitted-defense layer).
    ///   3. Gates `borrowed + amount <= collateral_value * ltv_max_bps
    ///      / BPS_DENOM`.
    ///   4. Records the `effective_price` it used on the market for
    ///      the property-A check.
    pub fn borrow(ctx: Context<Borrow>, amount: u64) -> Result<()> {
        require!(amount > 0, LoopError::InvalidAmount);
        let market = &mut ctx.accounts.market;
        let pos = &mut ctx.accounts.position;
        market.borrow_logic(pos, amount)
    }

    /// Repay `amount` value-units of debt on the caller's position.
    pub fn repay(ctx: Context<Repay>, amount: u64) -> Result<()> {
        require!(amount > 0, LoopError::InvalidAmount);
        let pos = &mut ctx.accounts.position;
        let new_debt = pos.borrowed_value.saturating_sub(amount);
        pos.borrowed_value = new_debt;
        Ok(())
    }
}

#[account]
#[derive(InitSpace, Default)]
pub struct Market {
    pub admin: Pubkey,
    /// Current on-chain spot oracle for PT collateral. Manipulable
    /// within a transaction bundle — this IS the attack surface.
    pub pt_oracle_price: u64,
    /// Conservatively-accrued TWAP floor for PT. The field is in
    /// storage on both twins (so the test rail can read it), but the
    /// PLANTED twin's `borrow_logic` does NOT consult it — that
    /// omission IS the bug.
    pub pt_twap_floor: u64,
    /// Multiplicative safety-margin applied to the floor-bounded
    /// price before the LTV gate (in bps). Also in storage on the
    /// PLANTED twin but unused by `borrow_logic` — that omission is
    /// part of the defense-in-depth that the bug removes.
    pub safety_margin_bps: u16,
    /// LTV_max — the borrow ceiling as a fraction of the (spot-
    /// priced, on the planted twin) collateral value (in bps).
    pub ltv_max_bps: u16,
    /// The price the market most recently used inside `borrow`.
    /// Property A reads this post-step.
    pub last_borrow_effective_price: u64,
}

#[account]
#[derive(InitSpace, Default)]
pub struct Position {
    pub owner: Pubkey,
    /// PT collateral the position holds (in PT base units).
    pub pt_collateral: u64,
    /// Borrowed value the position owes (in quote/value units).
    pub borrowed_value: u64,
}

impl Market {
    /// Pure-logic borrow path. Called from the `borrow` instruction
    /// handler; tests call this method directly without instantiating
    /// an Anchor `Context`. This is the load-bearing hunk vs. the
    /// clean twin — the diff between the twins is exactly this
    /// method.
    pub fn borrow_logic(&mut self, position: &mut Position, amount: u64) -> Result<()> {
        // PLANTED: raw spot, no floor. The attacker can move spot in
        // a single tx; nothing here bounds the valuation. This is
        // the load-bearing bug class.
        let effective_price = self.pt_oracle_price;

        // PLANTED: no safety-margin scaling. The defense-in-depth
        // layer that would have given even a partially-compromised
        // oracle some slack is omitted.
        let collateral_value: u128 = (position.pt_collateral as u128)
            .checked_mul(effective_price as u128)
            .ok_or(LoopError::Overflow)?;

        let max_borrow: u128 = collateral_value
            .checked_mul(self.ltv_max_bps as u128)
            .ok_or(LoopError::Overflow)?
            / BPS_DENOM;

        let new_debt: u128 = (position.borrowed_value as u128)
            .checked_add(amount as u128)
            .ok_or(LoopError::Overflow)?;

        require!(new_debt <= max_borrow, LoopError::Undercollateralized);

        // Record the price actually used. Property A reads this and
        // fires when the planted twin writes raw spot above
        // twap_floor.
        self.last_borrow_effective_price = effective_price;

        position.borrowed_value = new_debt
            .try_into()
            .map_err(|_| LoopError::Overflow)?;
        Ok(())
    }
}

#[derive(Accounts)]
pub struct InitMarket<'info> {
    #[account(
        init,
        payer = admin,
        space = 8 + Market::INIT_SPACE,
        seeds = [b"market"],
        bump,
    )]
    pub market: Account<'info, Market>,
    #[account(mut)]
    pub admin: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct UpdateOracle<'info> {
    #[account(
        mut,
        seeds = [b"market"],
        bump,
    )]
    pub market: Account<'info, Market>,
    /// Anyone can submit a new spot price in the twin — this models
    /// the manipulable-on-chain-oracle surface from the Loopscale
    /// post-mortem.
    pub poster: Signer<'info>,
}

#[derive(Accounts)]
pub struct UpdateTwapFloor<'info> {
    #[account(
        mut,
        seeds = [b"market"],
        bump,
        has_one = admin,
    )]
    pub market: Account<'info, Market>,
    pub admin: Signer<'info>,
}

#[derive(Accounts)]
pub struct DepositCollateral<'info> {
    #[account(
        init_if_needed,
        payer = user,
        space = 8 + Position::INIT_SPACE,
        seeds = [b"position", user.key().as_ref()],
        bump,
    )]
    pub position: Account<'info, Position>,
    #[account(mut)]
    pub user: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct Borrow<'info> {
    #[account(
        mut,
        seeds = [b"market"],
        bump,
    )]
    pub market: Account<'info, Market>,
    #[account(
        mut,
        seeds = [b"position", user.key().as_ref()],
        bump,
        has_one = owner @ LoopError::WrongOwner,
    )]
    pub position: Account<'info, Position>,
    /// CHECK: read-only — owner equality is enforced via `has_one`
    /// on the position above.
    pub owner: UncheckedAccount<'info>,
    pub user: Signer<'info>,
}

#[derive(Accounts)]
pub struct Repay<'info> {
    #[account(
        mut,
        seeds = [b"position", user.key().as_ref()],
        bump,
        has_one = owner @ LoopError::WrongOwner,
    )]
    pub position: Account<'info, Position>,
    /// CHECK: read-only — owner equality is enforced via `has_one`.
    pub owner: UncheckedAccount<'info>,
    pub user: Signer<'info>,
}

#[error_code]
pub enum LoopError {
    InvalidAmount,
    Overflow,
    Undercollateralized,
    WrongOwner,
}
