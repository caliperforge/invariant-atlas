// cashio-mint — PLANTED twin for Atlas case 3 (Cashio, Mar 2022).
//
// Same-source twin of the vulnerable Cashio mint-against-collateral
// path with the bug class PLANTED. The collateral-mint constraint
// on `MintCash::collateral` is the difference between this file and
// the `clean/` twin; everything else is byte-identical. A
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
// Two properties detect this bug class on this planted twin (driven
// by tests/tests/atlas_invariants.rs):
//
//   A. collateral authenticity. For every successful `mint_cash`,
//      the collateral.mint equals bank.collateral_mint.
//   B. mint-backing conservation. bank.total_cash_minted does not
//      exceed bank.total_collateral_validated, where the latter is
//      incremented only when the constraint check passes.
//
// The planted hunk (the minimal diff against `clean/`):
//
//   The `MintCash` accounts struct DROPS the `constraint` annotation
//   on `collateral`. Anchor still deserializes it as a TokenAccount
//   (any valid SPL token account is accepted), but the mint-equality
//   check is gone. The handler body is unchanged.
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
    /// LP-token mint that the protocol accepts as collateral. On the
    /// PLANTED twin this field is set but never consulted by
    /// `mint_cash` — the bug class IS the missing consultation.
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
    /// account. On the PLANTED twin the accounts macro does NOT
    /// enforce `collateral.mint == bank.collateral_mint`; any SPL
    /// TokenAccount is accepted, and the handler body unconditionally
    /// increments both counters. The mint-backing-conservation
    /// invariant fires from the test side because the harness only
    /// counts validated paths in its `expected_validated`
    /// accumulator.
    pub fn mint_cash(ctx: Context<MintCash>, amount: u64) -> Result<()> {
        let bank = &mut ctx.accounts.bank;
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

/// The accounts struct for `mint_cash`. NOTE: the `constraint`
/// annotation tying `collateral.mint` to `bank.collateral_mint` is
/// MISSING here vs. the CLEAN twin — this is the planted bug. Anchor
/// will still validate the account as an SPL TokenAccount (the data
/// layout + owner-program check pass), but it will NOT cross-check
/// the underlying mint pubkey. This is the Cashio bug class in one
/// hunk.
#[derive(Accounts)]
pub struct MintCash<'info> {
    #[account(mut)]
    pub bank: Account<'info, Bank>,

    // PLANTED: constraint = collateral.mint == bank.collateral_mint
    //          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    //          The annotation is dropped. The CLEAN twin has it.
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
