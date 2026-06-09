// Atlas case 4 — Mango Markets oracle-bound invariants.
//
// This test file is BYTE-IDENTICAL between
// `cases/04-solana-mango/clean/` and `cases/04-solana-mango/planted/`.
// Only `programs/mango_market_ref/src/lib.rs` differs between the two
// twins (and the diff is localized to the body of `compute_max_borrow`);
// the property surface is the same.
//
// Properties asserted (per task spec; the clean leg holds them, the
// planted leg fires within timeout):
//
//   A. borrow_power_validation: for every state reachable,
//        borrowed ≤ max_safe_borrow_ever_authorized
//      where `max_safe_borrow_ever_authorized` is the on-chain
//      ledger field that ratchets to the SAFE-pipeline high-water
//      mark on every successful `try_borrow`. `safe_max_borrow`
//      lives in the lib and is byte-identical between the twins;
//      only the gate (`compute_max_borrow`) differs. On the clean
//      twin, the gate IS the safe pipeline, so a successful borrow
//      always grows the ledger to at least the new `borrowed` value
//      — the invariant holds by construction. On the planted twin,
//      the unsafe gate admits borrows where the canonical pipeline
//      returns `None`; the ledger does not advance, the on-chain
//      `borrowed` grows past it, and the property check fires.
//
//   B. oracle_freshness: at every post-borrow-step state with
//      `borrowed > 0`,
//        current_slot - oracle_slot ≤ FRESHNESS_BOUND_SLOTS.
//      The CLEAN twin enforces this on the borrow path (the
//      freshness gate is inside `compute_max_borrow`); the PLANTED
//      twin omits it. A sequence that lets the oracle age past the
//      bound and then borrows passes on the planted twin and fails
//      on the clean twin (clean's `borrow` reverts with
//      `StaleOracle`). NB: B is *event-style* — it asserts the
//      latest borrow was authorized against a fresh oracle, not
//      that the oracle remains fresh forever after. We check the
//      property immediately after the borrow step; subsequent
//      `tick_slot` calls that age the oracle past the bound are NOT
//      retro-violations.
//
// AI-proposed invariant surface (Rust/Anchor Specialist agent, model
// `claude-opus-4-6`), reviewed and accepted by the case author. The
// invariant class (oracle freshness + price-sanity bound + borrow-
// power validation) is the load-bearing Mango bug class — not a toy.
//
// Test harness note: the Anchor program's business logic lives in
// the `logic` module (pure functions over `&mut Market`). These
// tests call `logic::*` directly — that is the same code path the
// on-chain `borrow` / `update_oracle` / etc. instructions
// dispatch to under the SBF VM. The Atlas case is faithful at the
// function-grain; running through `cargo build-sbf` + LiteSVM would
// add CI minutes without changing the property surface.

use mango_market_ref::{
    compute_max_borrow, logic, safe_max_borrow, Market, FRESHNESS_BOUND_SLOTS,
};

// ----- property A: borrow_power_validation -----

fn assert_a_borrow_power_validation(m: &Market) {
    assert!(
        m.borrowed <= m.max_safe_borrow_ever_authorized,
        "INVARIANT VIOLATED borrow_power_validation: borrowed={} > \
         max_safe_borrow_ever_authorized={} (oracle_price={}, \
         twap_price={}, deposited_collateral={}, current_slot={}, \
         oracle_slot={}, safe_max_borrow_now={:?})",
        m.borrowed,
        m.max_safe_borrow_ever_authorized,
        m.oracle_price,
        m.twap_price,
        m.deposited_collateral,
        m.current_slot,
        m.oracle_slot,
        safe_max_borrow(m),
    );
}

// ----- property B: oracle_freshness, on a post-borrow check -----

fn assert_b_oracle_freshness_post_borrow(m: &Market) {
    if m.borrowed == 0 {
        // Symmetric case: borrowed==0 holds B trivially. The
        // freshness gate is only meaningful when there is debt
        // outstanding AND the borrow that opened it was authorized.
        return;
    }
    let age = m.current_slot.saturating_sub(m.oracle_slot);
    assert!(
        age <= FRESHNESS_BOUND_SLOTS,
        "INVARIANT VIOLATED oracle_freshness: borrowed={} but oracle aged {} slots \
         at borrow time (current_slot={}, oracle_slot={}, FRESHNESS_BOUND_SLOTS={})",
        m.borrowed,
        age,
        m.current_slot,
        m.oracle_slot,
        FRESHNESS_BOUND_SLOTS,
    );
}

// ----- helper: fresh-market factory -----

fn fresh_market(oracle_price: u64, twap_price: u64) -> Market {
    let mut m = Market {
        authority: anchor_lang::prelude::Pubkey::default(),
        oracle_price: 0,
        oracle_slot: 0,
        twap_price: 0,
        current_slot: 0,
        deposited_collateral: 0,
        borrowed: 0,
        max_safe_borrow_ever_authorized: 0,
    };
    logic::initialize(&mut m, oracle_price, twap_price)
        .expect("fresh_market: initialize");
    m
}

// ============================================================
// Deterministic attack-sequence test
// ============================================================
//
// Runs the canonical Mango-class oracle-pump sequence verbatim.
// On the planted twin this fires Property A (borrowed >
// max_safe_borrow_ever_authorized because the safe-price gate was
// skipped) — the test panics with the INVARIANT VIOLATED marker
// and CI's planted leg passes. On the clean twin the deviation
// gate rejects the inflated spot at `try_borrow` time; the
// sequence cannot proceed and both properties hold trivially.
//
// Numbers (with deposited_collateral sized so the bug is reachable):
//   Initial oracle = twap = 100      (in PRICE_SCALE-fixed-point)
//   Deposit collateral = 1e9
//   Safe baseline max_borrow:
//     1e9 * 100 / 1e6 * 5_000 / 10_000 = 50_000
//   Pumped oracle = 2_000  (20× spike vs TWAP-window mid)
//   Planted max_borrow at post-pump state:
//     1e9 * 2_000 / 1e6 * 5_000 / 10_000 = 1_000_000
//   Attacker borrow request = 700_000
//     (700_000 < 1_000_000 → planted accepts; 700_000 >> 50_000 → safe rejects)

#[test]
fn cf_attack_sequence_mango_oracle_pump() {
    let mut m = fresh_market(100, 100);

    // Step 1: attacker deposits collateral.
    logic::deposit_collateral(&mut m, 1_000_000_000_u64)
        .expect("deposit_collateral");

    // Sanity baseline: oracle == twap, canonical pipeline accepts.
    assert_eq!(
        safe_max_borrow(&m),
        Some(50_000),
        "baseline safe max_borrow check",
    );
    // No borrow has happened yet; ledger is still 0. Property A
    // holds (borrowed=0 ≤ ledger=0).
    assert_a_borrow_power_validation(&m);

    // Step 2: attacker pumps the oracle 20× while TWAP stays at 100.
    // Same slot; freshness still fine — the defending guard here is
    // deviation, not freshness.
    logic::update_oracle(&mut m, 2_000, 0).expect("update_oracle");

    // After the pump, the canonical pipeline REJECTS the oracle
    // (deviation 1_900 > allowed 5), so safe_max collapses to None.
    // Any nonzero `borrowed` against this state grows past a stale
    // ledger → Property A violation.
    assert_eq!(safe_max_borrow(&m), None, "post-pump canonical rejects");
    // Sanity-print the variant gate's verdict for the scorecard.
    let _gate_verdict = compute_max_borrow(&m);

    // Step 3: attacker tries to borrow 700_000 against the pumped
    // oracle. PLANTED: planted's `compute_max_borrow` returns
    // 1_000_000; borrow succeeds; `borrowed = 700_000`; ledger
    // stays at 0 (safe pipeline returned None). CLEAN: the
    // deviation gate inside `compute_max_borrow` returns
    // `Err(OracleDeviationOutOfBound)`; `try_borrow` propagates;
    // `borrowed` stays 0.
    let _ = logic::try_borrow(&mut m, 700_000);

    // Property A:
    //   CLEAN  : borrowed=0,        ledger=0       → 0 ≤ 0      ✓
    //   PLANTED: borrowed=700_000,  ledger=0       → 700_000 > 0 ✗ marker
    assert_a_borrow_power_validation(&m);

    // Property B: borrowed==0 on clean (trivial); on planted
    // borrowed > 0 with age=0, so B holds here (the freshness leg
    // is exercised by `cf_attack_sequence_mango_stale_oracle`
    // below).
    assert_b_oracle_freshness_post_borrow(&m);
}

// ============================================================
// Deterministic stale-oracle sequence (freshness leg)
// ============================================================
//
// Lets the oracle age past FRESHNESS_BOUND_SLOTS, then borrows. The
// CLEAN twin rejects the borrow on `StaleOracle`; the PLANTED twin
// admits it. Property A AND Property B fire on planted's post-step
// check.

#[test]
fn cf_attack_sequence_mango_stale_oracle() {
    let mut m = fresh_market(100, 100);
    logic::deposit_collateral(&mut m, 1_000_000_000_u64)
        .expect("deposit_collateral");

    // Push current_slot past the freshness window. The oracle was
    // posted at slot 0; we advance to slot FRESHNESS_BOUND_SLOTS + 1.
    logic::tick_slot(&mut m, FRESHNESS_BOUND_SLOTS + 1);

    // Confirm the canonical pipeline now rejects on freshness.
    assert_eq!(
        safe_max_borrow(&m),
        None,
        "post-stale canonical rejects on freshness",
    );

    // Attempt the borrow. CLEAN: reverts with `StaleOracle`. PLANTED:
    // succeeds; on-chain `borrowed = 10_000`.
    let _ = logic::try_borrow(&mut m, 10_000);

    // Property A: ledger stayed 0 (safe pipeline returned None on
    // every borrow attempt). Planted's `borrowed=10_000 > 0` →
    // marker. Clean's `borrowed=0 ≤ 0` → trivially holds.
    assert_a_borrow_power_validation(&m);
    // Property B: planted's `borrowed > 0` with `age > bound` →
    // marker. Clean's `borrowed == 0` → trivially holds.
    assert_b_oracle_freshness_post_borrow(&m);
}

// ============================================================
// Fuzzed multi-step sequence
// ============================================================
//
// Drives N mixed operations using a deterministic seeded LCG (no
// `proptest` dep — keeps Cargo.toml minimal and CI hermetic).
// Each step picks an op in {deposit, update_oracle, update_twap,
// tick_slot, borrow, repay} and an amount; ignores errors (the
// safe-dispatcher equivalent of case 1's Cairo SafeDispatcher);
// Property A runs after every step. Property B is only checked
// post-borrow-step (per the event-style note in the file header).
//
// The seed set below is sized to match case 1's snforge
// `fuzzer(runs: 64)` budget. The LCG mixer covers the (op, amount,
// oracle, twap, slot) sub-space deterministically; the clean leg
// holds A across all 64 sequences; the planted leg fires A on the
// first sequence whose decoded ops include an oracle update + a
// nonzero borrow against the resulting deviating / stale state.

fn lcg_step(state: &mut u64) -> u64 {
    // Numerical Recipes 64-bit constants. Good-enough mixer for a
    // deterministic property test; we are NOT cryptographically
    // randomizing the search space, just walking it deterministically.
    *state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    *state
}

fn drive_one_sequence(seed: u64) {
    let mut m = fresh_market(100, 100);
    let mut s = seed;

    for _ in 0..16 {
        let r = lcg_step(&mut s);
        let op = r % 6;
        let amount_small = (r >> 8) % 1_000 + 1;
        let amount_collat = (r >> 8) % 1_000_000_000 + 1;
        let oracle_price = (r >> 16) % 5_000 + 1;
        let twap_price = (r >> 24) % 5_000 + 1;
        let slot_delta = (r >> 32) % 50;
        let oracle_slot = m.current_slot.saturating_sub((r >> 40) % 30);

        // B is event-style: only checked when a borrow actually
        // succeeded THIS step. A failed try_borrow (e.g. clean's
        // freshness gate rejecting) does not refresh "the borrow
        // that opened this debt was authorized fresh" — the debt
        // sitting on the books is from a PRIOR successful borrow,
        // and that one was already checked at the time it landed.
        let mut borrow_succeeded_this_step = false;
        let _ = match op {
            0 => logic::deposit_collateral(&mut m, amount_collat),
            1 => logic::update_oracle(&mut m, oracle_price, oracle_slot),
            2 => logic::update_twap(&mut m, twap_price),
            3 => {
                logic::tick_slot(&mut m, slot_delta);
                Ok(())
            }
            4 => {
                let res = logic::try_borrow(&mut m, amount_small);
                if res.is_ok() {
                    borrow_succeeded_this_step = true;
                }
                res
            }
            5 => logic::try_repay(&mut m, amount_small),
            _ => Ok(()),
        };

        assert_a_borrow_power_validation(&m);
        if borrow_succeeded_this_step {
            assert_b_oracle_freshness_post_borrow(&m);
        }
    }
}

#[test]
fn cf_fuzz_mango_oracle_bound() {
    for seed in 0..64_u64 {
        drive_one_sequence(seed.wrapping_mul(7919).wrapping_add(11));
    }
}

// ============================================================
// Unit test: legitimate happy path holds on both twins
// ============================================================

#[test]
fn unit_deposit_borrow_repay_legitimate() {
    // A user deposits collateral with a quiet oracle (no pump, no
    // staleness), borrows half their safe-priced limit, then repays
    // in full. Both twins should accept the flow and end with
    // borrowed == 0; both properties hold throughout.
    let mut m = fresh_market(100, 100);
    logic::deposit_collateral(&mut m, 1_000_000_000_u64)
        .expect("deposit_collateral");

    // Safe max_borrow at this state = 50_000.
    assert_eq!(safe_max_borrow(&m), Some(50_000));

    // Borrow half the safe max — well within bound on both twins.
    logic::try_borrow(&mut m, 25_000).expect("legitimate borrow");
    assert_a_borrow_power_validation(&m);
    assert_b_oracle_freshness_post_borrow(&m);

    // Repay in full.
    logic::try_repay(&mut m, 25_000).expect("legitimate repay");
    assert_eq!(m.borrowed, 0);
    assert_a_borrow_power_validation(&m);
    assert_b_oracle_freshness_post_borrow(&m);
}

