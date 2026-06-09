// Atlas case 1 — zkLend share-accounting invariants.
//
// This test file is BYTE-IDENTICAL between cases/01-cairo-zklend/clean/
// and cases/01-cairo-zklend/planted/. Only src/lib.cairo differs between
// the two twins; the property surface is the same.
//
// Properties asserted (per task spec; the clean-leg holds them, the
// planted-leg fires within timeout):
//
//   A. accumulator monotonicity / empty-market deposit guard:
//        for every state reachable,
//          total_shares == 0  OR  total_shares >= MIN_INIT_SHARES
//      The clean twin enforces this by requiring amount >=
//      MIN_INIT_DEPOSIT on the empty-market path and minting
//      MIN_INIT_SHARES to a dead sentinel. The planted twin's
//      `deposit(1)` on the empty market produces total_shares == 1,
//      which violates the lower bound.
//
//   B. round-trip non-amplification (per-user conservation):
//        for every user u, at every step,
//          withdrawn(u) <= deposited(u)
//      In the clean twin this holds strictly because `donate` is
//      gated to bootstrapped markets with per-step cap, and the
//      dead-shares burn keeps the accumulator at 1:1. In the planted
//      twin the canonical attack — deposit(1) → donate(LARGE) →
//      victim deposit(M) → withdraw(1) — leaves the attacker with
//      withdrawn >> deposited, violating B.
//
// AI-proposed invariant surface (Cairo Specialist agent, model
// claude-opus-4-6), reviewed and accepted by the case author. The
// invariant class (empty-market deposit guard + round-trip
// conservation) is the load-bearing zkLend bug class — not a toy.
//
// snforge note: snforge's `Fuzzable` trait does not have an
// implementation for fixed-size arrays as of 0.60.0 / 0.61.0, so
// per-step inputs are encoded as `u64` / `u128` words that the driver
// slices byte-by-byte to drive a multi-step transition sequence.
// Same pattern as cf-invariants' lending_ref fuzz driver.

// snforge SafeDispatcher is marked as an unstable feature in Cairo
// 2.18.0 and emits a per-call warning. The warning is informational
// (matches the cf-invariants existing pattern); the dispatcher is
// stable in practice.
use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait, cheat_caller_address, CheatSpan,
};
use starknet::ContractAddress;
use starknet::contract_address_const;
use zklend_market::{IZklendMarketDispatcher, IZklendMarketDispatcherTrait};
use zklend_market::{IZklendMarketSafeDispatcher, IZklendMarketSafeDispatcherTrait};

// MIN_INIT_SHARES used by the empty-market guard property (A). Must
// match the constant the CLEAN twin's src/lib.cairo declares. The
// PLANTED twin omits the enforcement but the constant is still
// in-scope (kept identical in both twins).
const MIN_INIT_SHARES: u256 = 1000_u256;

// Three fuzz users — same rotation pattern lending_ref uses.
fn caller(i: u8) -> ContractAddress {
    if i % 3 == 0 {
        contract_address_const::<0xB1>()
    } else if i % 3 == 1 {
        contract_address_const::<0xB2>()
    } else {
        contract_address_const::<0xB3>()
    }
}

fn pow2(shift: u64) -> u64 {
    let mut acc: u64 = 1;
    let mut s = shift;
    while s > 0 {
        acc = acc * 2;
        s = s - 1;
    };
    acc
}

fn byte_at(word: u64, i: usize) -> u8 {
    let shift: u64 = (i.into() * 8_u64);
    ((word / pow2(shift)) % 256_u64).try_into().unwrap()
}

fn deploy_market() -> (IZklendMarketDispatcher, IZklendMarketSafeDispatcher) {
    let contract = declare("ZklendMarket").unwrap().contract_class();
    let (addr, _) = contract.deploy(@array![]).unwrap();
    (
        IZklendMarketDispatcher { contract_address: addr },
        IZklendMarketSafeDispatcher { contract_address: addr },
    )
}

// Property A: total_shares == 0 OR total_shares >= MIN_INIT_SHARES.
fn assert_A_empty_market_guard(d: IZklendMarketDispatcher) {
    let ts = d.total_shares();
    let ta = d.total_assets();
    assert!(
        ts == 0_u256 || ts >= MIN_INIT_SHARES,
        "INVARIANT VIOLATED accumulator_empty_market_guard",
    );
    // Also: if total_shares == 0 then total_assets == 0 (no donation
    // on an unbootstrapped market). Folded into A as the symmetric
    // case.
    assert!(
        ts > 0_u256 || ta == 0_u256,
        "INVARIANT VIOLATED accumulator_empty_market_guard",
    );
}

// Property B: for every user, withdrawn(u) <= deposited(u).
fn assert_B_round_trip_conservation(d: IZklendMarketDispatcher) {
    let users = array![
        contract_address_const::<0xB1>(),
        contract_address_const::<0xB2>(),
        contract_address_const::<0xB3>(),
    ];
    let mut i: usize = 0;
    while i < users.len() {
        let u = *users.at(i);
        let dep = d.deposited(u);
        let wd = d.withdrawn(u);
        assert!(
            wd <= dep,
            "INVARIANT VIOLATED round_trip_conservation",
        );
        i += 1;
    };
}

// ---------------- Deterministic attack-sequence test ----------------

// Runs the canonical zkLend inflation sequence verbatim. On the
// planted twin this fires Property B (withdrawn(attacker) >>
// deposited(attacker)) — the test panics with the
// INVARIANT VIOLATED marker and CI's planted leg passes. On the
// clean twin the empty-market guard rejects the 1-wei seed via the
// safe dispatcher; the sequence cannot proceed and both properties
// hold trivially.
#[test]
fn cf_attack_sequence_zklend_inflation() {
    let (d, safe) = deploy_market();
    let addr = d.contract_address;
    let attacker = contract_address_const::<0xA77>();
    let victim = contract_address_const::<0xB1C>();

    // Step 1: attacker seeds with 1 wei. Reverts on CLEAN
    // (amount < MIN_INIT_DEPOSIT); succeeds on PLANTED.
    cheat_caller_address(addr, attacker, CheatSpan::TargetCalls(1));
    let _ = safe.deposit(1_u256);

    // Step 2: attacker donates large to pump the accumulator.
    // Reverts on CLEAN if step 1 was rejected (donate on empty
    // market) or if amount exceeds the per-step cap; succeeds on
    // PLANTED.
    cheat_caller_address(addr, attacker, CheatSpan::TargetCalls(1));
    let _ = safe.donate(10_000_u256);

    // Step 3: victim deposits an amount that would truncate to zero
    // shares on the planted twin (amount < total_assets /
    // total_shares = 10001 / 1 = 10001). 5000 < 10001 → zero
    // shares minted to victim.
    cheat_caller_address(addr, victim, CheatSpan::TargetCalls(1));
    let _ = safe.deposit(5_000_u256);

    // Property check after the victim deposit. On planted, victim's
    // deposit is recorded but minted 0 shares; total_assets is now
    // 15001, total_shares still 1. Property A asserts total_shares
    // >= MIN_INIT_SHARES (1000) — VIOLATED on planted, marker
    // emitted.
    assert_A_empty_market_guard(d);

    // Step 4: attacker withdraws their 1 share. On planted, this
    // returns 1 * 15001 / 1 = 15001 wei — attacker.withdrawn = 15001
    // vs attacker.deposited = 1.
    cheat_caller_address(addr, attacker, CheatSpan::TargetCalls(1));
    let _ = safe.withdraw(1_u256);

    // Property B fires here on planted (withdrawn(attacker)=15001 >
    // deposited(attacker)=1). On clean, attacker has no shares
    // (step 1 reverted) so safe.withdraw(1) reverts on
    // "insufficient shares"; property B holds (withdrawn==0 ==
    // deposited==0 for both users).
    assert_B_round_trip_conservation(d);
}

// ---------------- Fuzzed multi-step sequence ----------------

// Drives 8 mixed operations across 3 callers. Each step picks an op
// in {deposit, withdraw, donate, noop} and an amount; the safe
// dispatcher absorbs reverts so the CLEAN leg can ignore blocked
// attack sub-sequences without crashing. Property A and B are
// checked after every step.
#[test]
#[fuzzer(runs: 64, seed: 7777)]
fn cf_invariant_zklend_share_accounting(
    op_word: u64,
    who_word: u64,
    amt_word: u64,
) {
    let (d, safe) = deploy_market();
    let addr = d.contract_address;

    let mut i: usize = 0;
    while i < 8 {
        let caller_i = caller(byte_at(who_word, i));
        let op = byte_at(op_word, i) % 4;
        let amt_byte = byte_at(amt_word, i);
        // Scaled amounts: deposits and withdraws stay small enough
        // that the truncation path (planted) hits on victim
        // deposits; donates scale 1000x to actually move the
        // accumulator.
        let deposit_amount: u256 = (amt_byte.into() + 1_u256);
        let withdraw_shares: u256 = (amt_byte.into() + 1_u256);
        let donate_amount: u256 = (amt_byte.into() + 1_u256) * 1000_u256;

        if op == 0 {
            cheat_caller_address(addr, caller_i, CheatSpan::TargetCalls(1));
            let _ = safe.deposit(deposit_amount);
        } else if op == 1 {
            let owned = d.shares_of(caller_i);
            let safe_shares = if withdraw_shares <= owned { withdraw_shares } else { owned };
            if safe_shares > 0_u256 {
                cheat_caller_address(addr, caller_i, CheatSpan::TargetCalls(1));
                let _ = safe.withdraw(safe_shares);
            }
        } else if op == 2 {
            cheat_caller_address(addr, caller_i, CheatSpan::TargetCalls(1));
            let _ = safe.donate(donate_amount);
        }
        // op == 3: noop. Keeps the search wider.

        assert_A_empty_market_guard(d);
        assert_B_round_trip_conservation(d);
        i += 1;
    };
}

// ---------------- Unit tests (entrypoint coverage) ----------------

#[test]
fn unit_constructor_initial_state() {
    let (d, _) = deploy_market();
    assert!(d.total_assets() == 0_u256, "ctor: total_assets");
    assert!(d.total_shares() == 0_u256, "ctor: total_shares");
}

#[test]
fn unit_deposit_then_withdraw_legitimate() {
    // Legitimate flow: a single user deposits MIN_INIT_DEPOSIT * 10
    // and immediately withdraws all their shares. On both clean
    // (with the dead-shares burn) and planted (no burn) this should
    // complete without firing any invariant — the clean twin loses
    // MIN_INIT_SHARES to the dead sentinel but the user's withdrawn
    // is still <= deposited.
    let (d, safe) = deploy_market();
    let addr = d.contract_address;
    let u = contract_address_const::<0xB1>();
    cheat_caller_address(addr, u, CheatSpan::TargetCalls(1));
    let _ = safe.deposit(10_000_u256);
    let owned = d.shares_of(u);
    if owned > 0_u256 {
        cheat_caller_address(addr, u, CheatSpan::TargetCalls(1));
        let _ = safe.withdraw(owned);
    }
    assert_A_empty_market_guard(d);
    assert_B_round_trip_conservation(d);
}
