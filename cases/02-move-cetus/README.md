# Atlas case 2 — Cetus (Move / Sui, May 2025)

**Exploit:** Cetus Protocol CLMM drained, ~$223M, May 2025.
**Bug class:** flawed `checked_shlw` overflow check — the constant on
the upper-bound mask was `0xFFFFFFFFFFFFFFFF << 192` instead of
`0x1 << 192`. Any liquidity value in `(2^192, mask]` passes the
check; the subsequent `n << 64` silently truncates (u256 left-shift
wraps); the AMM math then computes a tokens-required value many
orders of magnitude smaller than the liquidity it credits — the
attacker mints huge liquidity for ~1 token and drains the pool.
**Invariant class:** (a) overflow-safety on the shift/bound check;
(b) liquidity ↔ token-amount conservation (tokens required to claim
liquidity must scale with the liquidity, never collapse to ~1).

## Post-mortem sources (primary)

- Dedaub root-cause analysis — function-grain walkthrough of the
  flawed `checked_shlw` mask and the math path that consumes it.
- Halborn write-up — same incident, attack-trace focus + the
  bookkeeping mismatch (huge liquidity, ~1 token paid).
- Cyfrin breakdown — defender-side framing of the missing
  overflow gate.
- MerkleScience post-mortem — on-chain trace of the attacker's
  add-liquidity / remove-liquidity sequence.

(URLs are carried as published; the Atlas does not republish the
attacker's calldata.)

## What this case ships

A minimal Sui Move (2024 edition) same-source twin of the Cetus
CLMM liquidity-math path with the bug class planted in
`planted/sources/cetus_liquidity.move` and the canonical defender-
side fix applied to `clean/sources/cetus_liquidity.move`. A paired
CI run asserts both legs.

```
02-move-cetus/
  clean/         # Sui Move 2024 package: pre-exploit math with the
                 # corrected mask
    Move.toml
    sources/cetus_liquidity.move
    tests/atlas_invariants.move
  planted/       # Sui Move 2024 package: same-source twin with the
                 # flawed mask planted
    Move.toml                     # byte-identical to clean/
    sources/cetus_liquidity.move  # <-- ONLY this file differs
    tests/atlas_invariants.move   # byte-identical to clean/
  scorecard.clean.md
  scorecard.planted.md
  README.md
```

A `diff -r clean/ planted/` shows the planted hunk as a single
localized change to `sources/cetus_liquidity.move` — the mask
constant inside `checked_shlw`, plus the boundary inequality. The
test module and the `Move.toml` do not change between twins.

## The bug class, reconstructed

The vulnerable `checked_shlw` on the planted twin:

```move
// PLANTED (02-move-cetus/planted/sources/cetus_liquidity.move):
public fun checked_shlw(n: u256): (u256, bool) {
    let mask: u256 = (0xffffffffffffffff as u256) << 192;
    if (n > mask) {
        (0, true)
    } else {
        (n << 64, false)
    }
}
```

The clean fix:

```move
// CLEAN (02-move-cetus/clean/sources/cetus_liquidity.move):
public fun checked_shlw(n: u256): (u256, bool) {
    let mask: u256 = (1 as u256) << 192;
    if (n >= mask) {
        (0, true)
    } else {
        (n << 64, false)
    }
}
```

Why the planted mask is wrong: `checked_shlw` is meant to gate
`n << 64` against u256 overflow. `n << 64` overflows u256 iff
`n >= 2^192` (because `2^192 << 64 = 2^256`, which truncates to
zero in u256). The correct mask therefore is `1 << 192 = 2^192`,
and the gate is `n >= mask`. The planted version's mask is
`0xFFFFFFFFFFFFFFFF << 192 ≈ 2^256 − 2^192`, three orders of
magnitude (binary) above the correct boundary; the gate becomes
`n > mask` which only triggers for `n` near `u256::MAX`. Every
value in the wide range `(2^192, 0xFFFFFFFFFFFFFFFF << 192]`
sneaks through, and the subsequent `n << 64` truncates silently.

The canonical attack sequence on the planted twin (faithful to the
Cetus on-chain trace per the Dedaub / Halborn / Cyfrin / MerkleScience
post-mortems):

```
victim.add_liquidity(L = 1000, tokens_offered = 1000)
    ok → pool.total_liquidity = 1000, pool.total_tokens = 1000

attacker.add_liquidity(L = 2^192 + 1, tokens_offered = 1)
    checked_shlw(2^192 + 1)
      planted: mask = 0xffffffffffffffff << 192
               (2^192 + 1) > mask  →  false
               returned (((2^192 + 1) << 64) mod 2^256, false)
                       = (1 << 64, false)
      tokens_required = (1 << 64) / (1 << 64) = 1
    1 (tokens_offered) >= 1 (tokens_required) → accepted
    ok → pool.total_liquidity ≈ 2^192 + 1001,
         pool.total_tokens   = 1001

INVARIANT VIOLATED liquidity_tokens_conservation
    pool.total_tokens = 1001 < pool.total_liquidity ≈ 2^192 + 1001

attacker.remove_liquidity(receipt)
    pro-rata tokens_out ≈ pool.total_tokens × L_attacker / L_total ≈ 1001
    attacker.tokens_paid = 1; tokens_out ≈ 1001 → drained.
```

The clean twin blocks the sequence at step 2: `checked_shlw(2^192 + 1)`
returns `(0, true)`; `liquidity_to_tokens` aborts at `E_OVERFLOW`;
`add_liquidity` reverts; pool state is unchanged. The attack cannot
proceed; both properties hold trivially.

## The properties

### Property A — overflow-safety on `checked_shlw`

For every reachable input `n: u256`, the `checked_shlw` function
must report overflow exactly when `n << 64` would exceed u256:

```
overflow_flag(n) == (n >= (1 << 192))
```

The deterministic property test walks a hand-picked input grid
that covers (a) ordinary values, (b) the correct boundary
`2^192 − 1`, `2^192`, `2^192 + 1`, (c) the wide-bug-region values
`(2^192, 0xFFFFFFFFFFFFFFFF << 192]`, and (d) values above the
planted mask. The clean twin holds the property for the full grid;
the planted twin fails at `n = 2^192` (or the first probe in the
bug region the grid hits) and emits the marker
`INVARIANT VIOLATED overflow_safety` to stdout before aborting.

### Property B — liquidity ↔ token-amount conservation

After every `add_liquidity` / `remove_liquidity` step, the pool's
on-hand tokens must back its outstanding liquidity at the documented
ratio. In this Atlas twin `sqrt_price_x64 = 1 << 64` so the documented
ratio is 1:1 and the invariant collapses to:

```
pool.total_tokens >= pool.total_liquidity
```

The deterministic attack test (above) drives the canonical Cetus
sequence; on the planted twin the post-attack pool has
`total_tokens = 1001` and `total_liquidity ≈ 2^192 + 1001`, so
`total_tokens < total_liquidity` by ~2^192 — the marker
`INVARIANT VIOLATED liquidity_tokens_conservation` is emitted.

## How to reproduce locally

Requires `sui` 1.73.x (Move 2024 edition is the default; the
package's `Move.toml` pins it).

```sh
# clean leg — all properties hold
cd clean
sui move build
sui move test
# Expected: 5 passed, 0 failed.

# planted leg — properties fire
cd ../planted
sui move build
sui move test
# Expected: 3 passed, 2 failed. Both failures carry an
# INVARIANT VIOLATED marker on stdout.
```

Scorecard captures from a verified-2026-06-08 local run are in
[`scorecard.clean.md`](scorecard.clean.md) and
[`scorecard.planted.md`](scorecard.planted.md).

## What this case does NOT claim

- This is NOT a fork of Cetus's production source. The reconstructed
  liquidity-math path is the minimal AMM primitive needed to exercise
  the bug class; the protocol's full feature set (concentrated
  liquidity ticks, swap routing, fee accrual, oracle layer, governance,
  etc.) is out of scope.
- The Atlas does NOT claim CaliperForge found the Cetus exploit live.
  The property surface here is what the protocol could have wired into
  CI before mainnet; it is not a runtime guard and not a formal-
  verification proof.
- The simplified `sqrt_price_x64 = 1 << 64` (price = 1) is illustrative
  for the Atlas twin; a production AMM calibrates the price factor
  per pool. The bug class (mask boundary on the overflow check) is
  independent of the price factor.

## Disclosure

The invariant surface (Property A + Property B) was proposed by the
Move Specialist agent (model: `claude-opus-4-6`) against the
published Dedaub / Halborn / Cyfrin / MerkleScience post-mortems and
accepted by the case author. The same-source twin reconstruction was
authored by the same specialist agent. See
[`../../AI_DISCLOSURE.md`](../../AI_DISCLOSURE.md).

Apache-2.0. Operator: Michael Moffett — michael@caliperforge.com —
team@caliperforge.com.
