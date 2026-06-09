// cashio-mint — CLEAN twin for Atlas case 3 (Cashio, Mar 2022).
//
// Same-source twin of the vulnerable Cashio mint-against-collateral
// path with the bug class corrected. The collateral-mint constraint
// on `MintCash::collateral` is the difference between this file and
// the `planted/` twin; everything else is byte-identical. A
// `diff -r ../clean/programs/cashio-mint/src ../planted/programs/cashio-mint/src`
// is the review surface for the planted-bug hunk.
//
// Bug class reconstructed (per Helius "Solana Hacks: A Complete
// History" entry on Cashio + rekt write-up, Mar 2022):
//
//   The `mint_print` (mint-against-collateral) path consumed a
//   `collateral` TokenAccount whose `mint` field was never asserted
//   to equal the protocol-configured LP-token mint. Any caller-
//   controlled token account passed Anchor's `Account<TokenAccount>`
//   deserialization (it's a valid SPL token account), and the
//   handler credited CASH supply 1:1 against `collateral.amount`
//   without ever cross-checking that the underlying mint was the
//   genuine Saber LP. The attacker built a token account holding a
//   fake mint and minted ~$50M of CASH against it.
//
// Two properties detect this bug class on the planted twin and hold
// on this clean twin (driven by tests/tests/atlas_invariants.rs):
//
//   A. collateral authenticity. For every successful `mint_cash`,
//      the collateral.mint equals bank.collateral_mint.
//   B. mint-backing conservation. bank.total_cash_minted does not
//      exceed bank.total_collateral_validated, where the latter is
//      incremented only when the constraint check passes.
//
// The clean fix (the minimal hunk that diffs against `planted/`):
//
//   The `MintCash` accounts struct annotates `collateral` with
//     #[account(constraint = collateral.mint == bank.collateral_mint
//                            @ CashioError::FakeCollateral)]
//   Anchor's macro emits the check before the handler body runs;
//   the planted twin omits this annotation entirely.
//
// License: Apache-2.0.

#![allow(clippy::result_large_err, unexpected_cfgs)]

use anchor_lang::prelude::*;
use anchor_spl::token::TokenAccount;

declare_id!("AomFqBosc8aKiiL8f2cYRyJXzUFoEEH6qLdYmyJCJnva");

#[program]
pub mod cashio_mint {
    use super::*;

    /// Initialize the Bank PDA. `collateral_mint` is the configured
    /// LP-token mint that the protocol accepts as collateral; the
    /// load-bearing constraint check in `mint_cash` ties every
    /// instruction-time collateral account to this field.
    pub fn initialize(
        ctx: Context<Initialize>,
        collateral_mint: Pubkey,
    ) -> Result<()> {
        let bank = &mut ctx.accounts.bank;
        bank.collateral_mint = collateral_mint;
        bank.authority = ctx.accounts.authority.key();
        bank.total_cash_minted = 0;
        bank.total_collateral_validated = 0;
        Ok(())
    }

    /// Mint `amount` of CASH against the supplied `collateral`
    /// account. The Anchor accounts macro on `MintCash` enforces
    /// `collateral.mint == bank.collateral_mint` BEFORE this handler
    /// body runs; any handler-body invariant counter increment is
    /// therefore gated behind the validated-collateral check. This is
    /// the load-bearing fix vs. the Cashio bug class.
    pub fn mint_cash(ctx: Context<MintCash>, amount: u64) -> Result<()> {
        let bank = &mut ctx.accounts.bank;
        // We reached this point only because the accounts-struct
        // constraint accepted the collateral — increment BOTH
        // counters atomically. The property test's invariant B
        // (total_cash_minted <= total_collateral_validated) holds
        // strictly because the two counters move together here.
        bank.total_collateral_validated = bank
            .total_collateral_validated
            .checked_add(amount)
            .ok_or(CashioError::Overflow)?;
        bank.total_cash_minted = bank
            .total_cash_minted
            .checked_add(amount)
            .ok_or(CashioError::Overflow)?;
        Ok(())
    }
}

/// Persistent state. Stripped to the bug-class minimum: the
/// configured collateral mint and the two property counters. The
/// production Cashio protocol carried additional fee, bridged-
/// collateral, and governance fields not relevant to this bug class.
#[account]
pub struct Bank {
    pub authority: Pubkey,
    pub collateral_mint: Pubkey,
    pub total_cash_minted: u64,
    pub total_collateral_validated: u64,
}

impl Bank {
    /// 8 (discriminator) + 32 + 32 + 8 + 8 = 88 bytes.
    pub const SIZE: usize = 8 + 32 + 32 + 8 + 8;
}

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(
        init,
        payer = authority,
        space = Bank::SIZE,
    )]
    pub bank: Account<'info, Bank>,
    #[account(mut)]
    pub authority: Signer<'info>,
    pub system_program: Program<'info, System>,
}

/// The accounts struct for `mint_cash`. The `constraint` annotation
/// on `collateral` is the CLEAN-vs-PLANTED hunk: it enforces that
/// the collateral account's underlying mint matches the bank's
/// configured collateral mint. The planted twin removes this
/// annotation, leaving `collateral` validated only as "any SPL
/// TokenAccount" — which is exactly the Cashio bug.
#[derive(Accounts)]
pub struct MintCash<'info> {
    #[account(mut)]
    pub bank: Account<'info, Bank>,

    #[account(
        constraint = collateral.mint == bank.collateral_mint
            @ CashioError::FakeCollateral
    )]
    pub collateral: Account<'info, TokenAccount>,

    pub authority: Signer<'info>,
}

#[error_code]
pub enum CashioError {
    #[msg("collateral.mint does not match bank.collateral_mint")]
    FakeCollateral,
    #[msg("arithmetic overflow")]
    Overflow,
}
