// Atlas case 3 — Cashio collateral-validation invariants.
//
// This test file is BYTE-IDENTICAL between
// cases/03-solana-cashio/clean/ and cases/03-solana-cashio/planted/.
// Only programs/cashio-mint/src/lib.rs differs between the two twins;
// the property surface is the same.
//
// Properties asserted (per task spec; the clean leg holds them, the
// planted leg fires within timeout):
//
//   A. collateral authenticity:
//        for every successful mint_cash(collateral, amount):
//          collateral.mint == bank.collateral_mint
//
//      The clean twin enforces this with an Anchor accounts
//      constraint on `MintCash::collateral`. The planted twin
//      omits the constraint; a fake-collateral mint_cash succeeds
//      with `collateral.mint != bank.collateral_mint` and the
//      post-step property check fires.
//
//   B. mint-backing conservation:
//        bank.total_cash_minted <= expected_validated
//
//      where `expected_validated` is the harness's accumulator over
//      amounts whose collateral.mint matched bank.collateral_mint at
//      ix-handler entry. On the clean twin the constraint gate is
//      the only path to the increment, so cash_minted tracks
//      expected_validated exactly. On the planted twin a fake-
//      collateral call increments cash_minted without the harness
//      bumping expected_validated, and the property fires.
//
// AI-proposed invariant surface (Rust/Anchor Specialist agent,
// model claude-opus-4-6), reviewed and accepted by the case author.
// The invariant class (collateral-mint authenticity + supply
// conservation) is the load-bearing Cashio bug class — not a toy.
//
// LiteSVM note: the test loads the compiled BPF .so directly via
// litesvm::LiteSVM::add_program. The collateral TokenAccount is
// crafted byte-by-byte (manual layout of spl-token's 165-byte
// Account format) so the test does not need to issue an actual SPL
// Token InitializeAccount ix — we control the on-chain state
// directly. This is the same pattern cf-invariants-pyth uses for
// crafting Config PDA preimages in its Crucible fuzz harness.

use anchor_lang::prelude::Pubkey;
use anchor_lang::{AccountDeserialize, InstructionData, ToAccountMetas};
use litesvm::LiteSVM;
use solana_account::Account as SolanaAccount;
use solana_instruction::Instruction;
use solana_keypair::Keypair;
use solana_signer::Signer;
use solana_system_interface::program as system_program;
use solana_transaction::Transaction;
use proptest::prelude::*;

use cashio_mint::{accounts as cashio_accounts, instruction as cashio_ix, Bank};

// SPL Token program ID. Hand-coded to avoid pulling spl-token's own
// program-id surface (which couples to its anchor-version-specific
// re-export). Matches the canonical mainnet pubkey:
// TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA.
const SPL_TOKEN_ID: Pubkey = Pubkey::new_from_array([
    6, 221, 246, 225, 215, 101, 161, 147, 217, 203, 225, 70, 206, 235, 121, 172, 28, 180, 133,
    237, 95, 91, 55, 145, 58, 140, 245, 133, 126, 255, 0, 169,
]);

// Path the BPF .so lives at after `cargo build-sbf` runs against the
// program crate. cargo build-sbf writes into <workspace_root>/target/
// deploy/<crate_name>.so — `cashio_mint.so` (the `-` in the crate name
// is normalized to `_`).
//
// Resolved at runtime as <CARGO_MANIFEST_DIR>/../target/deploy/
// cashio_mint.so so the test crate's own manifest dir anchors the
// path without depending on the user's CWD.
fn program_so_path() -> std::path::PathBuf {
    let manifest_dir = env!("CARGO_MANIFEST_DIR");
    std::path::PathBuf::from(manifest_dir)
        .join("..")
        .join("target")
        .join("deploy")
        .join("cashio_mint.so")
}

fn program_id() -> Pubkey {
    cashio_mint::ID
}

/// Build a fresh LiteSVM with the program loaded and a funded payer.
fn setup() -> (LiteSVM, Keypair) {
    let mut svm = LiteSVM::new();
    let so_path = program_so_path();
    assert!(
        so_path.exists(),
        "cashio_mint.so missing at {} — run `cargo build-sbf --manifest-path programs/cashio-mint/Cargo.toml` first",
        so_path.display(),
    );
    svm.add_program_from_file(program_id(), &so_path)
        .expect("add cashio_mint program");
    let payer = Keypair::new();
    svm.airdrop(&payer.pubkey(), 10_000_000_000).unwrap();
    (svm, payer)
}

/// Craft an SPL TokenAccount at `pubkey` holding `amount` of `mint`,
/// owned by `owner`. The packed account bytes are written directly
/// to the LiteSVM account store; no InitializeAccount ix is issued.
/// This is how we materialize the attacker's "fake collateral" token
/// account without minting actual SPL Token supply.
///
/// SPL Token Account layout (spl-token 9, 165 bytes total):
///   0..32      mint:             Pubkey
///   32..64     owner:            Pubkey
///   64..72     amount:           u64 (little-endian)
///   72..108    delegate:         COption<Pubkey>   (4-byte tag || 32-byte pubkey or zeros)
///   108..109   state:            u8 (1 = Initialized)
///   109..121   is_native:        COption<u64>      (4-byte tag || 8-byte u64 or zeros)
///   121..129   delegated_amount: u64
///   129..165   close_authority:  COption<Pubkey>
fn craft_token_account(
    svm: &mut LiteSVM,
    pubkey: Pubkey,
    mint: Pubkey,
    owner: Pubkey,
    amount: u64,
) {
    let mut data = vec![0u8; 165];
    data[0..32].copy_from_slice(&mint.to_bytes());
    data[32..64].copy_from_slice(&owner.to_bytes());
    data[64..72].copy_from_slice(&amount.to_le_bytes());
    // delegate: COption::None → tag = 0u32 LE, rest zero. Already zero.
    // state = 1 (Initialized).
    data[108] = 1;
    // is_native: COption::None → already zero.
    // delegated_amount: 0 → already zero.
    // close_authority: COption::None → already zero.

    let account = SolanaAccount {
        lamports: 2_039_280, // SPL Token account rent-exempt minimum (mainnet baseline)
        data,
        owner: SPL_TOKEN_ID,
        executable: false,
        rent_epoch: 0,
    };
    svm.set_account(pubkey, account).expect("set token account");
}

/// Initialize the Bank PDA. Returns the Bank pubkey.
fn init_bank(svm: &mut LiteSVM, payer: &Keypair, collateral_mint: Pubkey) -> Pubkey {
    let bank = Keypair::new();

    let ix_data = cashio_ix::Initialize { collateral_mint }.data();
    let accounts = cashio_accounts::Initialize {
        bank: bank.pubkey(),
        authority: payer.pubkey(),
        system_program: system_program::ID,
    }
    .to_account_metas(None);

    let ix = Instruction {
        program_id: program_id(),
        accounts,
        data: ix_data,
    };

    let blockhash = svm.latest_blockhash();
    let tx = Transaction::new_signed_with_payer(
        &[ix],
        Some(&payer.pubkey()),
        &[payer, &bank],
        blockhash,
    );
    svm.send_transaction(tx).expect("initialize bank");

    bank.pubkey()
}

/// Send a `mint_cash` transaction. Returns Ok if the program accepted
/// it (planted twin will accept fake collateral; clean twin will
/// reject with CashioError::FakeCollateral).
fn try_mint_cash(
    svm: &mut LiteSVM,
    payer: &Keypair,
    bank: Pubkey,
    collateral: Pubkey,
    amount: u64,
) -> Result<(), String> {
    let ix_data = cashio_ix::MintCash { amount }.data();
    let accounts = cashio_accounts::MintCash {
        bank,
        collateral,
        authority: payer.pubkey(),
    }
    .to_account_metas(None);

    let ix = Instruction {
        program_id: program_id(),
        accounts,
        data: ix_data,
    };

    let blockhash = svm.latest_blockhash();
    let tx = Transaction::new_signed_with_payer(
        &[ix],
        Some(&payer.pubkey()),
        &[payer],
        blockhash,
    );
    svm.send_transaction(tx).map(|_| ()).map_err(|e| format!("{e:?}"))
}

/// Read the Bank PDA back as a `Bank` struct.
fn read_bank(svm: &LiteSVM, bank: Pubkey) -> Bank {
    let raw = svm.get_account(&bank).expect("bank account exists");
    // Anchor's AccountDeserialize::try_deserialize verifies the 8-byte
    // discriminator then borsh-deserializes the body.
    Bank::try_deserialize(&mut &raw.data[..]).expect("deserialize Bank")
}

// Property A check. Returns Ok(()) if the property holds; panics
// with the canonical marker if it does not.
fn assert_a_collateral_authenticity(
    last_call_succeeded: bool,
    collateral_mint_used: Pubkey,
    bank_collateral_mint: Pubkey,
) {
    if last_call_succeeded && collateral_mint_used != bank_collateral_mint {
        println!(
            "INVARIANT VIOLATED collateral_mint_authority \
             (collateral.mint={} bank.collateral_mint={})",
            collateral_mint_used, bank_collateral_mint,
        );
        panic!("INVARIANT VIOLATED collateral_mint_authority");
    }
}

// Property B check. Mint-backing conservation:
//   bank.total_cash_minted <= expected_validated
// where expected_validated is the harness's accumulator of amounts
// whose collateral.mint matched bank.collateral_mint at ix-handler
// entry. On the planted twin this fires whenever a fake-collateral
// call succeeded.
fn assert_b_mint_backing_conservation(bank: &Bank, expected_validated: u64) {
    if bank.total_cash_minted > expected_validated {
        println!(
            "INVARIANT VIOLATED mint_backing_conservation \
             (total_cash_minted={} expected_validated={} bank.total_collateral_validated={})",
            bank.total_cash_minted, expected_validated, bank.total_collateral_validated,
        );
        panic!("INVARIANT VIOLATED mint_backing_conservation");
    }
}

// ---------------- Deterministic attack-sequence test ----------------

/// Runs the canonical Cashio attack sequence verbatim:
///   1. Initialize bank with LEGIT_LP_MINT as collateral.
///   2. Attacker crafts a token account holding ATTACKER_FAKE_MINT.
///   3. Attacker calls mint_cash with the fake account.
///
/// On the CLEAN twin: step 3 reverts with CashioError::FakeCollateral.
/// The post-step properties hold trivially (no CASH was minted).
///
/// On the PLANTED twin: step 3 succeeds; total_cash_minted is
/// incremented against a fake-mint collateral; both properties fire
/// and the markers are emitted before panic.
#[test]
fn cf_attack_sequence_cashio_fake_collateral() {
    let (mut svm, payer) = setup();

    let legit_lp_mint = Pubkey::new_unique();
    let attacker_fake_mint = Pubkey::new_unique();
    let bank = init_bank(&mut svm, &payer, legit_lp_mint);

    let fake_collateral_account = Pubkey::new_unique();
    craft_token_account(
        &mut svm,
        fake_collateral_account,
        attacker_fake_mint,
        payer.pubkey(),
        1_000_000_000,
    );

    let amount = 1_000_000_000_u64;
    let mint_result = try_mint_cash(&mut svm, &payer, bank, fake_collateral_account, amount);

    let bank_state = read_bank(&svm, bank);

    // Harness-side accumulator: only the validated path counts.
    // The attack's collateral is FAKE, so expected_validated stays 0.
    let expected_validated: u64 = 0;

    // Property A: the call only succeeded on planted; on planted the
    // collateral.mint != bank.collateral_mint so the marker fires.
    assert_a_collateral_authenticity(
        mint_result.is_ok(),
        attacker_fake_mint,
        bank_state.collateral_mint,
    );

    // Property B: on planted, bank.total_cash_minted == amount and
    // expected_validated == 0, so the marker fires.
    assert_b_mint_backing_conservation(&bank_state, expected_validated);

    // On the clean twin we reach here: the mint_result was Err, the
    // bank state is untouched, and both properties hold trivially.
    assert!(mint_result.is_err(), "CLEAN twin should reject fake collateral");
    assert_eq!(bank_state.total_cash_minted, 0);
    assert_eq!(bank_state.total_collateral_validated, 0);
}

// ---------------- Legitimate-flow unit test ----------------

/// A legitimate mint_cash with a genuine LP collateral account must
/// succeed on BOTH twins and leave both properties holding. This
/// confirms the planted twin still passes the legitimate path —
/// the bug is the missing rejection of fake collateral, NOT a
/// blanket break of mint_cash.
#[test]
fn unit_legitimate_mint_cash() {
    let (mut svm, payer) = setup();

    let legit_lp_mint = Pubkey::new_unique();
    let bank = init_bank(&mut svm, &payer, legit_lp_mint);

    let legit_collateral = Pubkey::new_unique();
    craft_token_account(
        &mut svm,
        legit_collateral,
        legit_lp_mint,
        payer.pubkey(),
        5_000,
    );

    let amount = 5_000_u64;
    let r = try_mint_cash(&mut svm, &payer, bank, legit_collateral, amount);
    assert!(r.is_ok(), "legitimate mint_cash should succeed on both twins: {r:?}");

    let bank_state = read_bank(&svm, bank);
    assert_eq!(bank_state.total_cash_minted, amount);
    assert_eq!(bank_state.total_collateral_validated, amount);

    let expected_validated = amount;
    assert_a_collateral_authenticity(true, legit_lp_mint, bank_state.collateral_mint);
    assert_b_mint_backing_conservation(&bank_state, expected_validated);
}

// ---------------- Constructor coverage ----------------

#[test]
fn unit_initialize_bank_state() {
    let (mut svm, payer) = setup();
    let legit_lp_mint = Pubkey::new_unique();
    let bank = init_bank(&mut svm, &payer, legit_lp_mint);

    let bank_state = read_bank(&svm, bank);
    assert_eq!(bank_state.collateral_mint, legit_lp_mint);
    assert_eq!(bank_state.total_cash_minted, 0);
    assert_eq!(bank_state.total_collateral_validated, 0);
}

// ---------------- Property fuzz (proptest) ----------------

// Drives a mix of legitimate vs fake collateral mint_cash calls; the
// harness keeps a running `expected_validated` accumulator on the
// path the CLEAN twin would have accepted. Property A is checked
// after each successful call; Property B is checked after each step.
//
// On the CLEAN twin: every fake-collateral call is rejected by
// Anchor's constraint; the only succeeding calls are the legitimate
// ones, expected_validated tracks total_cash_minted exactly, and
// both properties hold across all 32 cases.
//
// On the PLANTED twin: a fake-collateral call succeeds; the
// collateral.mint != bank.collateral_mint, Property A fires;
// expected_validated stays behind total_cash_minted, Property B
// fires. The markers are emitted and the test panics on the first
// violation.
proptest! {
    #![proptest_config(ProptestConfig {
        cases: 32,
        // The fuzz is deterministic by default in CI; we want the
        // planted-leg violation to be repeatable across runs.
        .. ProptestConfig::default()
    })]

    #[test]
    fn cf_invariant_cashio_collateral_validation(
        use_fakes in proptest::collection::vec(any::<bool>(), 4..=8),
        amounts in proptest::collection::vec(1u64..=1_000_000_u64, 4..=8),
    ) {
        let (mut svm, payer) = setup();

        let legit_lp_mint = Pubkey::new_unique();
        let attacker_fake_mint = Pubkey::new_unique();
        let bank = init_bank(&mut svm, &payer, legit_lp_mint);

        let mut expected_validated: u64 = 0;

        let n = use_fakes.len().min(amounts.len());
        for i in 0..n {
            let use_fake = use_fakes[i];
            let amount = amounts[i];

            let collateral_account = Pubkey::new_unique();
            let collateral_mint_used = if use_fake { attacker_fake_mint } else { legit_lp_mint };
            craft_token_account(
                &mut svm,
                collateral_account,
                collateral_mint_used,
                payer.pubkey(),
                amount,
            );

            let r = try_mint_cash(&mut svm, &payer, bank, collateral_account, amount);
            let succeeded = r.is_ok();

            if succeeded && !use_fake {
                expected_validated = expected_validated.saturating_add(amount);
            }

            let bank_state = read_bank(&svm, bank);
            assert_a_collateral_authenticity(succeeded, collateral_mint_used, bank_state.collateral_mint);
            assert_b_mint_backing_conservation(&bank_state, expected_validated);
        }
    }
}
