# Atlas case 3 — Cashio / PLANTED scorecard

> Captured from a local run on 2026-06-08 with the pinned toolchain
> (solana-cli 4.0.1 / platform-tools v1.53; anchor-lang 1.0.1;
> litesvm 0.12.0). The CI workflow `atlas-all.yml` re-asserts this
> output on every push: planted leg succeeds when rc != 0 AND
> `INVARIANT VIOLATED` marker present on stdout.

## Summary

- Properties asserted: **2** (collateral_mint_authority,
  mint_backing_conservation)
- Properties violated: **1** (collateral_mint_authority; fires
  before mint_backing_conservation in both failing tests)
- Tests collected: **4**
- Tests passed: **2** (constructor + legitimate-flow tests do not
  trigger the bug class)
- Tests failed: **2** — both with the
  `INVARIANT VIOLATED collateral_mint_authority` marker
- proptest cases at first violation in the fuzz test: **2**
- solana-cli version: `4.0.1`
- platform-tools version: `v1.53`
- anchor-lang version: `=1.0.1`
- litesvm version: `0.12.0`

## Test results

```
running 4 tests
test unit_initialize_bank_state ............................ ok
test unit_legitimate_mint_cash ............................. ok
test cf_attack_sequence_cashio_fake_collateral ............. FAILED
    INVARIANT VIOLATED collateral_mint_authority
test cf_invariant_cashio_collateral_validation ............. FAILED
    INVARIANT VIOLATED collateral_mint_authority
    proptest minimal failing input:
      use_fakes = [false, true, false, false]
      amounts   = [1, 1, 1, 1]

test result: FAILED. 2 passed; 2 failed; 0 ignored; 0 measured;
0 filtered out; finished in 2.88s
```

## Failing sequence — deterministic attack test

```
cf_attack_sequence_cashio_fake_collateral:
  init_bank(legit_lp_mint = LEGIT_LP_MINT)   ok
  craft_token_account(
    fake_collateral_account,
    mint  = ATTACKER_FAKE_MINT,
    owner = payer,
    amount = 1_000_000_000,
  )                                           ok
  mint_cash(
    collateral = fake_collateral_account,
    amount     = 1_000_000_000,
  )                                           ok  ← bug surface

  Post-state:
    bank.total_cash_minted        = 1_000_000_000
    bank.total_collateral_validated = 1_000_000_000  (program-side counter)
    expected_validated (harness)    = 0              (no validation ever happened)

  INVARIANT VIOLATED collateral_mint_authority
    (collateral.mint = ATTACKER_FAKE_MINT
     bank.collateral_mint = LEGIT_LP_MINT)

  → Property B (mint_backing_conservation) would also have fired
    at the same step (total_cash_minted = 1e9 > expected_validated = 0);
    Property A fires first in the assertion order.
```

## Failing sequence — proptest

```
cf_invariant_cashio_collateral_validation (minimal shrunk input):
  use_fakes = [false, true, false, false]
  amounts   = [1, 1, 1, 1]

  step 0: legit collateral, amount 1     → ok, expected_validated = 1
  step 1: FAKE collateral, amount 1      → planted: ok (clean: rejects)
          Property A fires immediately on the post-step check:
          INVARIANT VIOLATED collateral_mint_authority

  proptest shrunk to the minimum failing prefix; the test would also
  have caught the same violation on every random case in which any
  use_fake[i] == true (≈ half of 32 cases per run).
```

## What this scorecard demonstrates

The planted twin's missing `collateral.mint == bank.collateral_mint`
constraint on the `MintCash` accounts struct is the load-bearing
Cashio bug class; both the deterministic attack test (modelled
directly on the Helius post-mortem's "fake collateral" sequence) and
the proptest random fuzz catch it within the test timeout. Property B
(mint-backing conservation) would also fire on the planted attack
sequence — in this test order Property A fires first because
collateral-authenticity is checked before backing-conservation in the
`assert_*` order.

## Reproduction

```sh
cd cases/03-solana-cashio/planted
cargo build-sbf --manifest-path programs/cashio-mint/Cargo.toml
cargo test --manifest-path tests/Cargo.toml
# Expected: rc != 0, ≥1 INVARIANT VIOLATED marker on stdout.
```

## Disclosure

The properties were AI-proposed by the Rust/Anchor Specialist agent
(model: `claude-opus-4-6`) and accepted by the case author. The
same-source twin reconstruction was authored by the same agent
against the published Helius / rekt post-mortems.

See [`../../AI_DISCLOSURE.md`](../../AI_DISCLOSURE.md) for the
project-level disclosure.

cf-invariants Atlas case 3 — Apache-2.0. Operator: Michael Moffett —
michael@caliperforge.com — team@caliperforge.com.
