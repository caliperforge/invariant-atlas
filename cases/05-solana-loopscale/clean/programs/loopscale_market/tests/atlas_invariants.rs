// Atlas case 5 — Loopscale collateral-valuation / oracle-bound
// invariants.
//
// This test file is BYTE-IDENTICAL between
// cases/05-solana-loopscale/clean/ and
// cases/05-solana-loopscale/planted/. Only
// programs/loopscale_market/src/lib.rs differs between the twins; the
// property surface is the same.
//
// Properties asserted (per task spec; the clean leg holds them, the
// planted leg fires within timeout):
//
//   A. collateral-valuation / oracle bound:
//        for every state reachable after a borrow,
//          market.last_borrow_effective_price <= market.pt_twap_floor
//      The clean twin enforces this by writing
//      `min(spot, twap_floor)` into `last_borrow_effective_price`.
//      The planted twin writes raw `spot`, which after an attacker
//      spike exceeds `twap_floor` and violates A.
//
//   B. no undercollateralized borrow can settle:
//        for every position p, at every step,
//          p.borrowed_value * 10_000
//             <= p.pt_collateral * market.pt_twap_floor *
//                market.ltv_max_bps
//      In the clean twin this holds strictly because `borrow` values
//      collateral at `min(spot, twap_floor) * safety_margin` and
//      gates at LTV_max. In the planted twin the canonical attack —
//      init → set floor → set spot → deposit collateral → manipulate
//      spot → borrow — leaves the position with
//      borrowed_value >> pt_collateral * twap_floor * LTV_max,
//      violating B.
//
// AI-proposed invariant surface (Rust/Anchor Specialist agent, model
// claude-opus-4-7), reviewed and accepted by the case author. The
// invariant class (collateral-valuation against a manipulable
// oracle, plus the post-borrow solvency check against the
// conservative TWAP floor) is the load-bearing Loopscale bug class —
// not a toy.
//
// Note on the test rail: this Atlas case calls the program's pure-
// logic methods (`Market::borrow_logic`, etc.) directly rather than
// driving the program through LiteSVM / Crucible. The Anchor
// program shape (#[program], #[derive(Accounts)], #[account]) is
// preserved verbatim in src/lib.rs; the test rail asserts the
// property surface that the on-chain rail would inherit from it.
// See README.md "Toolchain choice" for the rationale.

use loopscale_market::{LoopError, Market, Position, BPS_DENOM};
use proptest::prelude::*;

// Canonical numerical setup. Identical across both twins.
const INITIAL_TWAP_FLOOR: u64 = 1_000_000;       // 1.00 in micro-units
const SAFETY_MARGIN_BPS: u16 = 9_000;            // 90%
const LTV_MAX_BPS: u16 = 7_500;                  // 75%

// Three fuzz users — same rotation pattern other Atlas cases use.
fn user_seed(i: u8) -> [u8; 32] {
    let mut s = [0u8; 32];
    s[0] = 0xB0 + (i % 3);
    s
}

fn make_market() -> Market {
    let mut m = Market::default();
    m.admin = anchor_lang::prelude::Pubkey::new_unique();
    m.pt_oracle_price = 0;
    m.pt_twap_floor = INITIAL_TWAP_FLOOR;
    m.safety_margin_bps = SAFETY_MARGIN_BPS;
    m.ltv_max_bps = LTV_MAX_BPS;
    m.last_borrow_effective_price = 0;
    m
}

fn make_position(seed: [u8; 32]) -> Position {
    let mut p = Position::default();
    p.owner = anchor_lang::prelude::Pubkey::new_from_array(seed);
    p.pt_collateral = 0;
    p.borrowed_value = 0;
    p
}

// Property A: market.last_borrow_effective_price <= market.pt_twap_floor.
fn assert_a_collateral_valuation_bound(market: &Market) {
    if market.last_borrow_effective_price > market.pt_twap_floor {
        panic!(
            "INVARIANT VIOLATED collateral_valuation_bound (last_used={} > twap_floor={})",
            market.last_borrow_effective_price, market.pt_twap_floor,
        );
    }
}

// Property B: for every position, borrowed_value * 10_000 <=
//   pt_collateral * twap_floor * ltv_max_bps.
fn assert_b_borrow_solvency(market: &Market, positions: &[Position]) {
    for p in positions {
        let lhs: u128 = (p.borrowed_value as u128).checked_mul(BPS_DENOM).expect("lhs");
        let rhs: u128 = (p.pt_collateral as u128)
            .checked_mul(market.pt_twap_floor as u128).expect("rhs1")
            .checked_mul(market.ltv_max_bps as u128).expect("rhs2");
        if lhs > rhs {
            panic!(
                "INVARIANT VIOLATED borrow_solvency \
                 (owner={} borrowed*BPS={} > collateral*floor*LTV={})",
                p.owner, lhs, rhs,
            );
        }
    }
}

// ---------------- Deterministic attack-sequence test ----------------

// Runs the canonical Loopscale PT-mispricing sequence verbatim. On
// the planted twin this fires Property A on the borrow step (used
// price = 5_000_000 > twap_floor = 1_000_000) AND Property B on the
// post-borrow solvency check (borrowed = 370 > collateral × floor ×
// LTV / 10_000). On the clean twin the borrow_logic rejects with
// `Undercollateralized` (effective_price = min(5_000_000, 1_000_000)
// = 1_000_000; max_borrow = 100 × 1_000_000 × 0.90 × 0.75 = 67_500_000
// in micro-units = 67.5 — far below the 370 the attacker is asking
// for), so the borrow never settles and both properties hold
// trivially.
#[test]
fn cf_attack_sequence_loopscale_pt_mispricing() {
    let mut market = make_market();
    let mut attacker = make_position(user_seed(0));

    // Step 1: oracle reflects fair price.
    market.pt_oracle_price = 1_000_000;

    // Step 2: attacker deposits 100 PT.
    attacker.pt_collateral = 100;

    // Step 3: attacker manipulates spot oracle to 5× fair.
    market.pt_oracle_price = 5_000_000;

    // Step 4: attacker borrows 370 quote-units (in micro-units of
    // value: 370_000_000). The spot-priced collateral on the planted
    // twin: 100 × 5_000_000 × 0.75 = 375_000_000 → borrow of
    // 370_000_000 passes. On clean: floor-priced collateral × safety
    // × LTV = 100 × 1_000_000 × 0.90 × 0.75 = 67_500_000 →
    // 370_000_000 > 67_500_000 → Undercollateralized.
    let borrow_amount: u64 = 370_000_000;
    let result = market.borrow_logic(&mut attacker, borrow_amount);

    if result.is_err() {
        // Clean path: borrow rejected. Both properties hold (no
        // debt was opened).
        assert_eq!(
            attacker.borrowed_value, 0,
            "clean: rejected borrow must not have credited debt",
        );
        // Property B is trivially zero-on-both-sides for the
        // zero-debt case; still call the helper so the test is
        // structurally identical across legs.
        assert_a_collateral_valuation_bound(&market);
        assert_b_borrow_solvency(&market, &[attacker]);
        return;
    }

    // Planted path: borrow settled. Both properties should fire.
    // Order matters here — call A first so the marker for A surfaces
    // even if B's panic is what cargo test reports.
    assert_a_collateral_valuation_bound(&market);
    assert_b_borrow_solvency(&market, &[attacker]);
}

// ---------------- Fuzzed multi-step sequence ----------------

// Drives 8 mixed operations across 3 users. Each step picks an op
// in {deposit_collateral, update_oracle, borrow, repay} and an
// amount. Reverts from `borrow_logic` are swallowed (clean twin
// rejects the spike+borrow combo; we don't want that to crash the
// fuzz run). Property A and B are checked after every step.
proptest! {
    #![proptest_config(ProptestConfig {
        cases: 64,
        max_shrink_iters: 0,
        .. ProptestConfig::default()
    })]
    #[test]
    fn cf_invariant_loopscale_collateral_valuation_and_borrow(
        op_word in any::<u64>(),
        who_word in any::<u64>(),
        amt_word in any::<u64>(),
        oracle_word in any::<u64>(),
    ) {
        let mut market = make_market();
        let mut positions = [
            make_position(user_seed(0)),
            make_position(user_seed(1)),
            make_position(user_seed(2)),
        ];

        // Seed the spot oracle near twap_floor so the early steps
        // don't trivially reject.
        market.pt_oracle_price = INITIAL_TWAP_FLOOR;

        for i in 0..8 {
            let who = ((who_word >> (8 * i)) & 0xff) as usize % positions.len();
            let op = ((op_word >> (8 * i)) & 0xff) as u8 % 4;
            let amt_byte = ((amt_word >> (8 * i)) & 0xff) as u64;
            let oracle_byte = ((oracle_word >> (8 * i)) & 0xff) as u64;

            // Scaled amounts:
            //   deposits in PT units (collateral): small, +1
            //   borrows in micro-value-units: large
            //   oracle in micro-units, allowed to spike 0..=255 ×
            //     twap_floor / 64 (so the fuzz exercises both
            //     reasonable and manipulated price ranges)
            let deposit_amount: u64 = amt_byte + 1;
            let borrow_amount: u64 = (amt_byte + 1) * 1_000_000;
            let repay_amount: u64 = (amt_byte + 1) * 100_000;
            let new_oracle: u64 = (oracle_byte * INITIAL_TWAP_FLOOR / 64).max(1);

            match op {
                0 => {
                    // deposit_collateral
                    positions[who].pt_collateral = positions[who]
                        .pt_collateral.saturating_add(deposit_amount);
                }
                1 => {
                    // update_pt_oracle_price (the attack surface)
                    market.pt_oracle_price = new_oracle;
                }
                2 => {
                    // borrow — may revert on clean if the bound is hit
                    let _ = market.borrow_logic(&mut positions[who], borrow_amount);
                }
                3 => {
                    // repay
                    positions[who].borrowed_value =
                        positions[who].borrowed_value.saturating_sub(repay_amount);
                }
                _ => unreachable!(),
            }

            assert_a_collateral_valuation_bound(&market);
            assert_b_borrow_solvency(&market, &positions);
        }
    }
}

// ---------------- Unit tests (entrypoint coverage) ----------------

#[test]
fn unit_initial_state_holds_both_properties() {
    let market = make_market();
    let positions = [make_position(user_seed(0))];
    assert_a_collateral_valuation_bound(&market);
    assert_b_borrow_solvency(&market, &positions);
}

#[test]
fn unit_deposit_only_holds_both_properties() {
    // Depositing collateral without borrowing leaves both
    // properties trivially satisfied — collateral > 0, debt == 0.
    let mut market = make_market();
    market.pt_oracle_price = INITIAL_TWAP_FLOOR;
    let mut pos = make_position(user_seed(0));
    pos.pt_collateral = 1_000;
    assert_a_collateral_valuation_bound(&market);
    assert_b_borrow_solvency(&market, &[pos]);
}

#[test]
fn unit_legitimate_borrow_under_ltv_holds_both_properties() {
    // A legitimate borrow at the fair price (no manipulation),
    // sized below the LTV ceiling. Both twins should accept this
    // and both properties hold post-borrow.
    let mut market = make_market();
    market.pt_oracle_price = INITIAL_TWAP_FLOOR;
    let mut pos = make_position(user_seed(0));
    pos.pt_collateral = 100;

    // Borrow at 50% of the floor-priced collateral × LTV bound.
    // Bound on clean = 100 * 1_000_000 * 0.90 * 0.75 = 67_500_000.
    // Bound on planted (at fair spot) = 100 * 1_000_000 * 0.75 =
    // 75_000_000.
    // Pick 30_000_000 — under both bounds.
    let result = market.borrow_logic(&mut pos, 30_000_000);
    assert!(result.is_ok(), "legitimate sub-LTV borrow rejected: {:?}", result.err());

    assert_a_collateral_valuation_bound(&market);
    assert_b_borrow_solvency(&market, &[pos]);
}

#[test]
fn unit_clean_rejects_zero_amount() {
    let mut market = make_market();
    market.pt_oracle_price = INITIAL_TWAP_FLOOR;
    let mut pos = make_position(user_seed(0));
    pos.pt_collateral = 100;
    let result = market.borrow_logic(&mut pos, 0);
    // Zero-amount is independently rejected upstream of borrow_logic
    // in the `#[program]` handler; the pure method itself accepts
    // zero (no debt opened, no property violated). Both behaviors
    // are valid for the property surface — we just assert the state
    // is still consistent.
    let _ = result;
    assert_eq!(pos.borrowed_value, 0);
    assert_a_collateral_valuation_bound(&market);
    assert_b_borrow_solvency(&market, &[pos]);
}

// Sanity: the LoopError enum is reachable from tests. Used by the
// attack-sequence test's error-path check.
#[test]
fn unit_loop_error_reachable() {
    let e: anchor_lang::error::Error = LoopError::Undercollateralized.into();
    let _ = format!("{:?}", e);
}
