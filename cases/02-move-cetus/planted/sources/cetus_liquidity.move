// cetus_liquidity — PLANTED twin for Atlas case 2 (Cetus, May 2025).
//
// Same-source twin of the vulnerable Cetus CLMM liquidity-math path.
// The planted hunk is the `checked_shlw` mask constant + boundary
// inequality. Everything else is byte-identical to clean/. A
// `diff -r ../clean/sources ../planted/sources` is the review surface
// for the planted-bug hunk.
//
// Bug class reconstructed (per Dedaub / Halborn / Cyfrin /
// MerkleScience post-mortems, May 2025):
//
//   The CLMM's liquidity-math path scales a candidate liquidity
//   value `n` by 2^64 (Q64.64 fixed-point) before dividing by a
//   `sqrt_price_x64` factor to get the tokens required to mint
//   that liquidity. To prevent `n << 64` from overflowing u256 the
//   protocol wrapped the shift in `checked_shlw`, which compares
//   `n` against an upper-bound mask and returns an overflow flag.
//
//   The mask was hard-coded as `0xFFFFFFFFFFFFFFFF << 192`, but the
//   correct mask is `1 << 192`. Because the wrong mask sits about
//   3 binary orders above the correct boundary, every value in the
//   wide range `(2^192, 0xFFFFFFFFFFFFFFFF << 192]` slips past the
//   check; `n << 64` then silently truncates (u256 left-shift
//   wraps); `liquidity_to_tokens` returns a value many orders below
//   the liquidity it implies; the protocol credits the huge
//   liquidity but takes ~1 token. The attacker then redeems the
//   liquidity for the pool's tokens and drains.
//
// Two properties detect this bug class on the planted twin and hold
// on this clean twin (driven by tests/atlas_invariants.move):
//
//   A. overflow_safety. For every reachable u256 input n,
//        checked_shlw(n).overflow_flag == (n >= (1u256 << 192)).
//
//   B. liquidity_tokens_conservation. After every operation,
//        pool.total_tokens >= pool.total_liquidity.
//      (With sqrt_price_x64 = 1<<64 the price ratio is 1:1; in a
//      production AMM the conservation is L*price scaled, with the
//      same bug class boundary.)
//
// The clean fix (the minimal hunk that diffs against `planted/`):
//
//   1. checked_shlw: replace mask = 0xFFFFFFFFFFFFFFFF << 192 with
//      mask = 1 << 192, and replace `n > mask` with `n >= mask`.
//      The boundary inequality flip is part of the canonical fix:
//      at n = 2^192 exactly, n << 64 = 2^256 which truncates to 0,
//      so n == mask itself must be reported as overflow.
//
// License: Apache-2.0.

module cetus_liquidity::cetus_liquidity;

// E_AMOUNT_ZERO: add_liquidity rejects L == 0 so the receipt is
// non-trivial. The Atlas keeps this gate because removing it would
// change the property surface (a zero-L receipt would deposit zero
// tokens — vacuously fine — but blur the bug-class blast radius).
const E_AMOUNT_ZERO: u64 = 1;
// E_INSUFFICIENT_TOKENS: caller must offer at least the
// liquidity-implied token cost. This is the gate the planted
// checked_shlw bypasses: under-reported tokens_required lets a
// 1-token offer satisfy a 2^192-liquidity request.
const E_INSUFFICIENT_TOKENS: u64 = 2;
// E_OVERFLOW: checked_shlw reports overflow → abort. On the clean
// twin this fires for the attack liquidity (2^192 + 1) and stops
// the sequence at add_liquidity. On the planted twin the same call
// silently truncates instead of aborting.
const E_OVERFLOW: u64 = 4;

// Q64.64 sqrt-price for this Atlas twin. price = 1 → sqrt_price = 1 →
// sqrt_price_x64 = 1 << 64. A real CLMM stores per-pool sqrt_price_x64;
// pinning it at the unit value here keeps the bug class isolated to
// the mask boundary, where it actually lives.
const SQRT_PRICE_X64: u256 = 1 << 64;

public struct Pool has store, drop {
    total_liquidity: u256,
    total_tokens: u256,
}

public struct Receipt has store, drop {
    owner: address,
    liquidity: u256,
    tokens_paid: u256,
}

public fun new_pool(): Pool {
    Pool { total_liquidity: 0, total_tokens: 0 }
}

public fun total_liquidity(p: &Pool): u256 { p.total_liquidity }
public fun total_tokens(p: &Pool): u256 { p.total_tokens }
public fun receipt_owner(r: &Receipt): address { r.owner }
public fun receipt_liquidity(r: &Receipt): u256 { r.liquidity }
public fun receipt_tokens_paid(r: &Receipt): u256 { r.tokens_paid }

// e_overflow / e_insufficient_tokens accessors. Exposed for the
// test module's #[expected_failure(abort_code = ...)] absorption of
// the clean leg's E_OVERFLOW abort on the canonical attack call.
public fun e_overflow(): u64 { E_OVERFLOW }
public fun e_insufficient_tokens(): u64 { E_INSUFFICIENT_TOKENS }

// PLANTED checked_shlw: the bug.
//
// Mask is `0xFFFFFFFFFFFFFFFF << 192` (wrong) instead of `1 << 192`,
// and the inequality is `>` instead of `>=`. Together these let any
// liquidity value in `(2^192, 0xFFFFFFFFFFFFFFFF << 192]` slip
// past, and the subsequent `n << 64` truncates silently in u256.
public fun checked_shlw(n: u256): (u256, bool) {
    let mask: u256 = (0xffffffffffffffffu64 as u256) << 192;
    if (n > mask) {
        (0, true)
    } else {
        (n << 64, false)
    }
}

// liquidity_to_tokens: the consumer of checked_shlw. Returns the
// token amount required to mint `liquidity` LP units against this
// Atlas twin's Q64.64 sqrt_price.
//
// The bug surfaces here only insofar as `checked_shlw` returns
// overflow=false for an n that does in fact overflow; the body of
// this function correctly aborts on overflow when reported.
fun liquidity_to_tokens(liquidity: u256): u256 {
    let (shifted, overflow) = checked_shlw(liquidity);
    assert!(!overflow, E_OVERFLOW);
    shifted / SQRT_PRICE_X64
}

// add_liquidity: caller offers `tokens_offered` against a request
// to mint `liquidity` LP units. Aborts if the caller's offer is
// below the computed cost OR if liquidity is zero. Returns a
// Receipt that the caller can later redeem via remove_liquidity.
//
// On the planted twin the canonical attack passes
// (liquidity = 2^192 + 1, tokens_offered = 1) and the receipt is
// issued for the huge liquidity against a 1-token payment.
public fun add_liquidity(
    pool: &mut Pool,
    liquidity: u256,
    tokens_offered: u256,
    owner: address,
): Receipt {
    assert!(liquidity > 0, E_AMOUNT_ZERO);
    let tokens_required = liquidity_to_tokens(liquidity);
    assert!(tokens_offered >= tokens_required, E_INSUFFICIENT_TOKENS);
    pool.total_liquidity = pool.total_liquidity + liquidity;
    pool.total_tokens = pool.total_tokens + tokens_required;
    Receipt { owner, liquidity, tokens_paid: tokens_required }
}

// remove_liquidity: caller surrenders the receipt for a pro-rata
// share of the pool's tokens. The bug-class drain happens here on
// the planted twin: attacker's receipt holds 2^192 / (2^192 + 1000)
// of the pool, so tokens_out collects nearly the full pool balance
// against a 1-token payment.
public fun remove_liquidity(
    pool: &mut Pool,
    receipt: Receipt,
): u256 {
    let Receipt { owner: _, liquidity, tokens_paid: _ } = receipt;
    let tokens_out = if (pool.total_liquidity == 0) {
        0
    } else {
        (liquidity * pool.total_tokens) / pool.total_liquidity
    };
    pool.total_liquidity = pool.total_liquidity - liquidity;
    pool.total_tokens = pool.total_tokens - tokens_out;
    tokens_out
}
