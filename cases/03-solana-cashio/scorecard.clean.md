# Atlas case 3 — Cashio / CLEAN scorecard

> Captured from a local run on 2026-06-08 with the pinned toolchain
> (solana-cli 4.0.1 / platform-tools v1.53; anchor-lang 1.0.1;
> litesvm 0.12.0). The CI workflow `atlas-all.yml` re-asserts this
> output on every push.

## Summary

- Properties asserted: **2** (collateral_mint_authority,
  mint_backing_conservation)
- Properties violated: **0**
- Tests collected: **4**
- Tests passed: **4**
- Tests failed: **0**
- proptest cases per fuzz test: **32**
- solana-cli version: `4.0.1` (Agave, e4e3aa4)
- platform-tools version: `v1.53`
- anchor-lang version: `=1.0.1`
- litesvm version: `0.12.0`

## Test results

```
running 4 tests
test unit_initialize_bank_state ............................ ok
test unit_legitimate_mint_cash ............................. ok
test cf_attack_sequence_cashio_fake_collateral ............. ok
test cf_invariant_cashio_collateral_validation ............. ok

test result: ok. 4 passed; 0 failed; 0 ignored; 0 measured;
0 filtered out; finished in 1.28s
```

## What this scorecard demonstrates

The clean twin's `MintCash` accounts constraint
(`collateral.mint == bank.collateral_mint @ CashioError::FakeCollateral`)
rejects the canonical Cashio attack sequence at the `mint_cash` step:
the attacker's fake-collateral TokenAccount fails Anchor's account
validation; the instruction never reaches the supply-increment
handler body. The deterministic attack test asserts the rejection
and confirms `bank.total_cash_minted == 0` post-step. The 32-case
proptest fuzz mixes legitimate vs fake-collateral calls; every
fake-collateral call is rejected, the `expected_validated` accumulator
tracks `total_cash_minted` exactly, and both properties hold across
all cases.

## Reproduction

```sh
cd cases/03-solana-cashio/clean
cargo build-sbf --manifest-path programs/cashio-mint/Cargo.toml
cargo test --manifest-path tests/Cargo.toml
```

## Disclosure

The properties were AI-proposed by the Rust/Anchor Specialist agent
(model: `claude-opus-4-6`) and accepted by the case author. See
[`../../AI_DISCLOSURE.md`](../../AI_DISCLOSURE.md) for the
project-level disclosure.

cf-invariants Atlas case 3 — Apache-2.0. Operator: Michael Moffett —
michael@caliperforge.com — team@caliperforge.com.
