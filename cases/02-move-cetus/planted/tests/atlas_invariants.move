// Atlas case 2 — Cetus checked_shlw + liquidity-math invariants.
//
// This test file is BYTE-IDENTICAL between cases/02-move-cetus/clean/
// and cases/02-move-cetus/planted/. Only sources/cetus_liquidity.move
// differs between the two twins; the property surface is the same.
//
// Properties asserted:
//
//   A. overflow_safety. For every reachable u256 input n,
//        checked_shlw(n).overflow_flag == (n >= (1u256 << 192))
//      The clean twin holds A across the input grid. The planted twin
//      fails at the first probe in the wide bug region
//      (2^192, 0xFFFFFFFFFFFFFFFF << 192] — the planted mask is three
//      binary orders above the correct boundary, so the function under-
//      reports overflow there and the marker
//      "INVARIANT VIOLATED overflow_safety" is printed to stdout
//      before the test aborts.
//
//   B. liquidity_tokens_conservation. After every pool operation,
//        pool.total_tokens >= pool.total_liquidity
//      In this Atlas twin sqrt_price_x64 = 1<<64 so the documented
//      ratio is 1:1; production CLMM math scales by the per-pool
//      sqrt_price. On the clean twin the canonical attack sequence
//      can't seat the malicious add_liquidity (checked_shlw aborts
//      via E_OVERFLOW), so B holds trivially. On the planted twin the
//      seat succeeds, pool.total_tokens ends at 1001 while
//      pool.total_liquidity is ~2^192, the marker
//      "INVARIANT VIOLATED liquidity_tokens_conservation" is printed,
//      and the test aborts.
//
// AI-proposed invariant surface (Move Specialist agent, model
// claude-opus-4-6), reviewed and accepted by the case author. Bug class
// is the load-bearing Cetus root cause per Dedaub / Halborn / Cyfrin /
// MerkleScience post-mortems.
//
// CI marker discipline: each invariant violation site first prints
// "INVARIANT VIOLATED <name>" via std::debug to stdout, THEN aborts
// with a sentinel code. The atlas-all CI workflow greps stdout for the
// marker (rc!=0 alone is not enough — we want to know WHICH invariant
// fired). Pattern mirrors cases/01-cairo-zklend/'s snforge marker
// emission, adapted to Move's u64-only abort codes.

#[test_only]
module cetus_liquidity::atlas_invariants;

use std::debug;
use std::string;
use cetus_liquidity::cetus_liquidity::{Self, Pool, Receipt};

const A_VICTIM: address = @0xB1C;
const A_ATTACKER: address = @0xA77;

// 2^192 — the correct overflow boundary for checked_shlw. Any n >=
// TWO_POW_192 has n << 64 >= 2^256, which truncates in u256. The
// function MUST report overflow for any such n.
fun two_pow_192(): u256 { (1u8 as u256) << 192 }

// The planted twin's wrong mask: 0xFFFFFFFFFFFFFFFF << 192. We don't
// reference this value to construct probes (the test must be byte-
// identical between twins and the test's correctness must not assume
// the planted mask). Instead, probes pick concrete witnesses inside
// the wide bug region by stepping above two_pow_192 within u256.

// Sentinel abort codes for invariant violations. Each fires AFTER the
// marker has been printed via debug::print. The codes are unique to
// the test module (location) so the CI's marker grep + rc!=0 check
// composes cleanly.
const E_INVARIANT_OVERFLOW_SAFETY: u64 = 0xA01;
const E_INVARIANT_LIQUIDITY_TOKENS_CONSERVATION: u64 = 0xB01;

// Print the marker line then abort with the sentinel. Move's assert!
// only carries a u64 code, so the marker text is surfaced via
// std::debug::print on stdout — the same channel the CI greps. On the
// clean leg these helpers are not reached; on the planted leg they
// surface the violated invariant by name before the abort.
fun violate_overflow_safety() {
    let s = string::utf8(b"INVARIANT VIOLATED overflow_safety");
    debug::print(&s);
    abort E_INVARIANT_OVERFLOW_SAFETY
}

fun violate_liquidity_tokens_conservation() {
    let s = string::utf8(b"INVARIANT VIOLATED liquidity_tokens_conservation");
    debug::print(&s);
    abort E_INVARIANT_LIQUIDITY_TOKENS_CONSERVATION
}

// Property A: checked_shlw must report overflow exactly when n << 64
// would exceed u256.
fun assert_A_overflow_safety(n: u256) {
    let (_shifted, ov) = cetus_liquidity::checked_shlw(n);
    let expected = n >= two_pow_192();
    if (ov != expected) {
        violate_overflow_safety();
    };
}

// Property B: pool's on-hand tokens must back outstanding liquidity at
// the documented Q64.64 ratio. With sqrt_price_x64 = 1<<64 the ratio
// is 1:1 in this Atlas twin.
fun assert_B_conservation(p: &Pool) {
    let l = cetus_liquidity::total_liquidity(p);
    let t = cetus_liquidity::total_tokens(p);
    if (t < l) {
        violate_liquidity_tokens_conservation();
    };
}

// ---------------- Property A grid ----------------

// Walks a hand-picked input grid spanning ordinary values, the correct
// boundary, the wide bug region, the planted-mask boundary, and
// u256::MAX. On the clean twin all 11 probes hold. On the planted twin
// probe #4 (n = 2^192) is the first to fail — overflow_flag returns
// false but expected is true.
//
// The grid is deterministic; no `sui move test` fuzzer is used because
// the property is exhaustively covered at function-grain by these 11
// witnesses (the bug-class bound is a single scalar boundary, not a
// distribution).
#[test]
fun cf_invariant_overflow_safety_grid() {
    // Ordinary values — both twins must report no overflow.
    assert_A_overflow_safety(0);
    assert_A_overflow_safety(1);
    assert_A_overflow_safety(1000);
    assert_A_overflow_safety((1u8 as u256) << 64);
    assert_A_overflow_safety((1u8 as u256) << 128);

    // Correct boundary witnesses. n = 2^192 - 1: still safe. n = 2^192
    // and n = 2^192 + 1: overflow on the shift, both twins MUST report.
    assert_A_overflow_safety(two_pow_192() - 1);
    assert_A_overflow_safety(two_pow_192());
    assert_A_overflow_safety(two_pow_192() + 1);

    // Mid-range bug-region witness. n = 2^200 sits well inside the
    // wide range that the planted mask incorrectly waves through.
    assert_A_overflow_safety((1u8 as u256) << 200);

    // High-range bug-region witness. n = 2^248 is still below the
    // planted mask (0xFFFFFFFFFFFFFFFF << 192 ≈ 2^256 - 2^192). Both
    // twins MUST report overflow.
    assert_A_overflow_safety((1u8 as u256) << 248);

    // u256::MAX. Above the planted mask, so both twins agree here —
    // this probe is the upper sanity check, not a bug-region witness.
    assert_A_overflow_safety(0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffu256);
}

// ---------------- Deterministic attack-sequence test ----------------

// Runs the canonical Cetus checked_shlw attack verbatim:
//
//   1. victim seeds the pool with 1000 liquidity for 1000 tokens
//      (legitimate; both twins admit).
//   2. attacker requests 2^192 + 1 liquidity for 1 token.
//      - CLEAN: checked_shlw(2^192 + 1) returns (0, true);
//        liquidity_to_tokens aborts at E_OVERFLOW (=4); add_liquidity
//        reverts; the test reaches the #[expected_failure] gate and
//        passes.
//      - PLANTED: checked_shlw(2^192 + 1) returns (1<<64, false);
//        tokens_required = 1; add_liquidity seats the receipt for a
//        2^192-liquidity claim against a 1-token payment. The test
//        proceeds to assert_B_conservation, which sees total_tokens
//        = 1001 < total_liquidity ≈ 2^192 + 1001, prints
//        "INVARIANT VIOLATED liquidity_tokens_conservation", and
//        aborts with E_INVARIANT_LIQUIDITY_TOKENS_CONSERVATION
//        (=0xB01). The #[expected_failure] is keyed on
//        cetus_liquidity::E_OVERFLOW; 0xB01 doesn't match → the
//        test fails. The CI's marker grep catches the printed
//        invariant name.
//
// The double-asymmetry — clean's expected E_OVERFLOW vs. planted's
// observed E_INVARIANT_LIQUIDITY_TOKENS_CONSERVATION — is the
// mechanism that makes a byte-identical test pass on clean and fail
// on planted without per-twin conditional logic.
// E_OVERFLOW from cetus_liquidity::cetus_liquidity is the code the
// clean twin's checked_shlw → liquidity_to_tokens aborts with on the
// attack call. Move's expected_failure attribute requires a literal or
// a constant from THIS module, so the value is mirrored here. The
// invariant: this constant must match cetus_liquidity::e_overflow()
// (see unit_expected_failure_pin below).
const C_E_OVERFLOW: u64 = 4;

#[test]
#[expected_failure(abort_code = C_E_OVERFLOW, location = cetus_liquidity)]
fun cf_attack_sequence_cetus_overflow() {
    let mut p = cetus_liquidity::new_pool();

    // Step 1: victim seeds the pool with normal liquidity.
    let r_v = cetus_liquidity::add_liquidity(&mut p, 1000, 1000, A_VICTIM);

    // Step 2: attacker requests huge liquidity for 1 token. On CLEAN
    // this call aborts at E_OVERFLOW and the expected_failure gate
    // catches it; the rest of the test body is unreachable on clean.
    // On PLANTED this call succeeds.
    let r_a = cetus_liquidity::add_liquidity(
        &mut p,
        two_pow_192() + 1,
        1,
        A_ATTACKER,
    );

    // Reached only on PLANTED. Property B is now violated by a wide
    // margin (total_tokens = 1001 vs. total_liquidity ≈ 2^192 + 1001);
    // the assertion prints the marker and aborts with a code that does
    // NOT match the expected_failure gate above, so the test fails on
    // PLANTED.
    assert_B_conservation(&p);

    // Tail of the post-mortem trace, kept for documentation. The
    // attacker's remove_liquidity on the planted twin pulls
    // ~total_tokens out for a 1-token payment. Not reached on either
    // twin (clean aborted at step 2; planted aborted at the B check
    // above), but kept here so the deterministic sequence is visible
    // end-to-end for review.
    let tokens_out = cetus_liquidity::remove_liquidity(&mut p, r_a);
    let _ = tokens_out;
    let _ = r_v;
    let _ = p;
}

// ---------------- Unit tests (entrypoint coverage) ----------------

// Pin the locally-mirrored C_E_OVERFLOW against the source-module
// accessor. If the source module's E_OVERFLOW value ever changes,
// this test fails loud BEFORE the attack-sequence test has a chance
// to silently mis-absorb an unexpected abort code on the clean leg.
#[test]
fun unit_expected_failure_pin() {
    assert!(C_E_OVERFLOW == cetus_liquidity::e_overflow(), 100);
}

#[test]
fun unit_new_pool_initial_state() {
    let p = cetus_liquidity::new_pool();
    assert!(cetus_liquidity::total_liquidity(&p) == 0, 1);
    assert!(cetus_liquidity::total_tokens(&p) == 0, 2);
    let _ = p;
}

// Legitimate add → remove round-trip. Both twins admit this (the bug
// class is gated on the overflow path, not the ordinary path). The
// property checks hold trivially on both twins.
#[test]
fun unit_add_then_remove_legitimate_round_trip() {
    let mut p = cetus_liquidity::new_pool();
    let r = cetus_liquidity::add_liquidity(&mut p, 10_000, 10_000, A_VICTIM);

    // Pool sees the deposit.
    assert!(cetus_liquidity::total_liquidity(&p) == 10_000, 10);
    assert!(cetus_liquidity::total_tokens(&p) == 10_000, 11);
    assert!(cetus_liquidity::receipt_tokens_paid(&r) == 10_000, 12);
    assert_A_overflow_safety(10_000);
    assert_B_conservation(&p);

    let tokens_out = cetus_liquidity::remove_liquidity(&mut p, r);
    assert!(tokens_out == 10_000, 13);
    assert!(cetus_liquidity::total_liquidity(&p) == 0, 14);
    assert!(cetus_liquidity::total_tokens(&p) == 0, 15);
    assert_B_conservation(&p);
    let _ = p;
}
