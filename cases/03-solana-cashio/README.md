# Atlas case 3 — Cashio (Solana / Anchor, Mar 2022)

**Exploit:** Cashio mainnet drained, ~$50M, March 2022.
**Bug class:** missing collateral-account validation. The `mint_print`
path consumed a `collateral` `TokenAccount` whose `mint` field was
never asserted to equal the protocol-configured LP-token mint, so an
attacker supplied a token account holding a fake mint and minted
unlimited CASH.
**Invariant class:** account / authority validation — *only the
genuine LP token (correct mint + owner program) is accepted as
collateral*. Mint supply must be backed by validated collateral.

## Post-mortem sources (primary)

- Helius. *"Solana Hacks: A Complete History"* — Cashio entry; the
  canonical defender-side timeline.
- rekt. *"Cashio — rekt"* — public post-mortem with the on-chain
  attacker timeline.
- Samczsun-class write-ups (carry as published) on the same incident.

The Atlas does not republish attacker calldata; the URLs are carried
as cited by the primary sources above.

## What this case ships

A minimal Anchor 1.0.1 same-source twin of the mint-against-collateral
path with the Cashio bug class planted, the canonical defender-side
fix applied to the clean twin, and a paired-CI run that asserts both
legs. The harness is LiteSVM in-process (mirror of cf-invariants-anchor
and the cf-invariants-pyth Crucible fuzz pattern).

```
03-solana-cashio/
  clean/         # Anchor 1.0.1 program: pre-exploit path WITH the fix
    programs/cashio-mint/src/lib.rs
    programs/cashio-mint/Cargo.toml
    tests/tests/atlas_invariants.rs
    tests/Cargo.toml
    Cargo.toml
  planted/       # same-source twin with the bug planted
    programs/cashio-mint/src/lib.rs    # <-- ONLY this file differs from clean/
    programs/cashio-mint/Cargo.toml    # byte-identical to clean/
    tests/tests/atlas_invariants.rs    # byte-identical to clean/
    tests/Cargo.toml                   # byte-identical to clean/
    Cargo.toml                         # byte-identical to clean/
  scorecard.clean.md
  scorecard.planted.md
  README.md
```

`diff -r clean/ planted/` shows the planted hunk as a localized change
to `programs/cashio-mint/src/lib.rs` — the `mint_cash` accounts
struct's collateral-mint constraint is removed. The test module and
the cargo manifests do not change between twins.

## The bug class, reconstructed

The vulnerable `mint_cash` instruction accepts a `collateral`
`TokenAccount` and credits CASH supply 1:1 against the deposited
amount. The `Bank` PDA stores the *configured* `collateral_mint`
pubkey at initialization. The bug class is the *missing* constraint
that ties the two together at instruction time:

```rust
// PLANTED (cases/03-solana-cashio/planted/programs/cashio-mint/src/lib.rs):
#[derive(Accounts)]
pub struct MintCash<'info> {
    #[account(mut)]
    pub bank: Account<'info, Bank>,
    // The collateral account is loaded as an SPL TokenAccount but its
    // `mint` field is NEVER asserted against `bank.collateral_mint`.
    // Any caller-controlled token account is accepted as collateral.
    pub collateral: Account<'info, TokenAccount>,
    pub authority: Signer<'info>,
}
```

The clean fix is one constraint annotation:

```rust
// CLEAN (cases/03-solana-cashio/clean/programs/cashio-mint/src/lib.rs):
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
```

The canonical attack sequence on the planted twin:

```
Init:        bank.collateral_mint = LEGIT_LP_MINT
             bank.total_cash_minted = 0
             bank.total_collateral_validated = 0

Attacker:    create token account A_fake
               A_fake.mint = ATTACKER_FAKE_MINT  (not LEGIT_LP_MINT)
               A_fake.amount = 1_000_000_000

Attacker:    mint_cash(collateral=A_fake, amount=1_000_000_000)
                planted: instruction accepts; bank.total_cash_minted += 1e9
                clean:   instruction reverts with CashioError::FakeCollateral

Post-state (planted):
   bank.total_cash_minted        = 1_000_000_000
   bank.total_collateral_validated = 0   (nothing legit ever deposited)
   → INVARIANT VIOLATED mint_backing_conservation
```

The clean twin blocks the sequence on the `mint_cash` call: Anchor's
account validation macro raises `CashioError::FakeCollateral`. The
instruction never reaches the supply increment; both properties hold
trivially.

## The properties

### Property A — collateral authenticity

For every successful `mint_cash` instruction, the collateral
account's `mint` field MUST equal `bank.collateral_mint`:

```
forall successful_mint_cash(c, amount):
    c.mint == bank.collateral_mint
```

The planted twin accepts a `mint_cash` whose collateral has
`mint == ATTACKER_FAKE_MINT`; the post-step check fires and emits
`INVARIANT VIOLATED collateral_mint_authority`.

### Property B — mint-backing conservation

After every external transition, the total CASH minted is bounded
above by the total *validated* collateral deposited:

```
bank.total_cash_minted <= bank.total_collateral_validated
```

`total_collateral_validated` is the test harness's accumulator for
deposits whose collateral.mint matched at instruction-handler entry.
On the clean twin, the constraint gate is the only path that
increments either counter, so they advance together and the property
holds. On the planted twin, `mint_cash` against a fake collateral
account increments `total_cash_minted` without ever passing the
check, and the property fires with
`INVARIANT VIOLATED mint_backing_conservation`.

## How to reproduce locally

Requires Agave `solana-cli` (stable channel, v4.x as of 2026-06-08;
provides `cargo build-sbf`) and stable Rust. Anchor CLI is NOT
required — `cargo build-sbf` produces the
deployable `.so` and the integration test loads it via LiteSVM.

```sh
# clean leg — all properties hold
cd clean
cargo build-sbf --manifest-path programs/cashio-mint/Cargo.toml
cargo test --manifest-path tests/Cargo.toml
# Expected: tests pass; no `INVARIANT VIOLATED` markers on stdout.

# planted leg — properties fire
cd ../planted
cargo build-sbf --manifest-path programs/cashio-mint/Cargo.toml
cargo test --manifest-path tests/Cargo.toml
# Expected: tests fail; ≥1 `INVARIANT VIOLATED` marker on stdout.
```

Scorecard captures are in [`scorecard.clean.md`](scorecard.clean.md)
and [`scorecard.planted.md`](scorecard.planted.md).

## What this case does NOT claim

- **Not a "complete" benchmark.** Trace2Inv's 27 EVM cases took a
  peer-reviewed academic group; v0.1 ships 6–8 across 4 VMs. The
  honest claim is *first defender-side cross-VM benchmark*, not
  *exhaustive*.
- **Not "we caught these exploits."** The Atlas demonstrates that
  runnable invariant properties exist that *would have* failed
  against the pre-exploit code. The protocols themselves did not run
  them; CaliperForge did not find the exploits live.
- **Not formal verification.** Pre-deploy property tests are
  coverage-guided, not exhaustive. The Atlas's claim is "the
  property catches this specific historical exploit's class of
  failure under CI run," not "the property proves the absence of
  the bug class."

This case in particular is NOT a fork of Cashio's production source.
The reconstructed `cashio-mint` program is the minimal Anchor
primitive needed to exercise the collateral-validation bug class —
the protocol's full feature set (bridged-collateral redemption,
governance, fee accrual, multi-collateral support, etc.) is out of
scope.

## Disclosure

The invariant surface (Property A + Property B) was proposed by the
Rust/Anchor Specialist agent (model: `claude-opus-4-6`) against the
published Helius / rekt post-mortems and accepted by the case
author. The same-source twin reconstruction was authored by the
same specialist agent. See
[`../../AI_DISCLOSURE.md`](../../AI_DISCLOSURE.md).

Apache-2.0. Operator: Michael Moffett — michael@caliperforge.com —
team@caliperforge.com.
