# Exploit→Invariant Atlas (v0.1)

[![atlas-all](https://github.com/caliperforge/invariant-atlas/actions/workflows/atlas-all.yml/badge.svg?branch=main)](https://github.com/caliperforge/invariant-atlas/actions/workflows/atlas-all.yml?query=branch%3Amain)

A cross-VM, defender-side, pre-deploy CI benchmark: for each historical exploit,
a runnable invariant property and a same-source twin where the property *would
have* caught the bug class on the pre-exploit code under CI run.

**Status:** v0.1 shipped — all six cases land across Cairo, Move, Solana, and
EVM, each with both CI legs asserted (clean passes / planted fires). The
[`v4-hooks/`](v4-hooks/) subdir (Uniswap Foundation Security grant lane, three
hook-class invariants H1/H2/H3) is also in the matrix as `v4-hooks-cases`.
The [`taiko/`](taiko/) subdir (Taiko Labs grant lane, three Type-1
Ethereum-equivalence twins — PrecompileMirror / GasSchedule / BasedSequencer)
is also in the matrix as `taiko-cases`.

---

## Related work and positioning

> **Related work.** Three projects already anchor the "exploits ↔ defense" canon and the Atlas extends them rather than competes. **DeFiHackLabs** (SunWeb3Sec) reproduces 572 historical EVM exploits as Foundry PoCs — the attacker-side reference for EVM. **Trace2Inv** (Chen et al., FSE 2024, arXiv:2404.14580) is the peer-reviewed defender-side benchmark: 27 historical EVM exploits ($2B+ total), measured against runtime invariant guards (18/27 blocked by one invariant, 23/27 by combination, 0.28% false-positive rate). **FLAMES** (arXiv:2510.21401, Oct 2025) and **PropertyGPT** are the LLM-synthesized-invariant line for Solidity. The Atlas is differentiated on three axes against this canon. **(a) Cross-VM into non-EVM:** Trace2Inv and DeFiHackLabs are EVM-only; the Atlas's case set is Cairo / Solana / Move first, with EVM included as a bridge to the canon, not as the lead. Formal-verification tooling for Solana is still early-stage — a Solana prover exists, but the practice is nascent — and no public defender-side invariant benchmark exists for Cairo, Solana, or Move today. **(b) Pre-deploy CI gate, not runtime guard:** Trace2Inv evaluates *runtime* invariant enforcement (would the guard have blocked the tx at execution time). The Atlas evaluates *pre-deploy property tests* — the CI gate a protocol could have wired in before mainnet. Different threat model, different deployment shape, complementary. **(c) Tied to runnable harnesses we already maintain:** every Atlas case extends an existing CaliperForge harness (seven CI-green Apache-2.0 repos: cf-invariants + 12 Sepolia contracts on Cairo; cf-invariants-anchor + the 3 Jito ports + cf-invariants-pyth on Solana; a Move PoC on Sui), so the benchmark and the reference implementation co-evolve. The Atlas is, in one sentence, *Trace2Inv's defender-side rigor, applied pre-deploy in CI, across the VMs that line of work has not yet covered, against the exploits whose post-mortems are public and whose invariant class is clean.*

## What this Atlas does NOT claim

- **Not a "complete" benchmark.** Trace2Inv's 27 EVM cases took a peer-reviewed academic group; v0.1 ships 6–8 across 4 VMs. The honest claim is *first defender-side cross-VM benchmark*, not *exhaustive*.
- **Not "we caught these exploits."** The Atlas demonstrates that runnable invariant properties exist that *would have* failed against the pre-exploit code. The protocols themselves did not run them; CaliperForge did not find the exploits live.
- **Not formal verification.** Pre-deploy property tests are coverage-guided, not exhaustive. The Atlas's claim is "the property catches this specific historical exploit's class of failure under CI run," not "the property proves the absence of the bug class."

---

## Case set (v0.1)

The case order puts the non-EVM legs FIRST so the visual signal is "non-EVM-led
benchmark with an EVM bridge to the canon," not "EVM benchmark with a non-EVM
appendix."

| # | VM | Exploit | Date | Loss | Invariant class | Status |
|---|---|---|---|---|---|---|
| **C1** | Cairo / Starknet | [zkLend](cases/01-cairo-zklend/) | Feb 2025 | ~$10M | accumulator monotonicity + round-trip conservation + precision-loss bound | **shipped (template-setter)** |
| **C2** | Move / Sui | [Cetus](cases/02-move-cetus/) | May 2025 | ~$223M | overflow-safety + liquidity↔token conservation | **shipped** |
| **C3** | Solana | [Cashio](cases/03-solana-cashio/) | Mar 2022 | ~$50M | account / authority validation | **shipped** |
| **C4** | Solana | [Mango Markets](cases/04-solana-mango/) | Oct 2022 | ~$117M | oracle freshness + price-sanity bound | **shipped** |
| **C5** | Solana | [Loopscale](cases/05-solana-loopscale/) | Apr 2025 | ~$5.8M | collateral-valuation oracle bound | **shipped** |
| **C6** | EVM (bridge) | [Trace2Inv-set, access-control class](cases/06-evm-access-control/) | Aug 2021 (representative) | ~$8.9M (Punk Protocol representative) | privileged-function authorization | **shipped** |

## How each case is structured

```
cases/<n>-<vm>-<protocol>/
  README.md             # post-mortem cite, property prose, run instructions
  clean/                # reconstructed pre-exploit Cairo + property test
                        #   — invariants HOLD under fuzz
  planted/              # same-source twin with the planted bug
                        #   — invariants FAIL under fuzz within timeout
  scorecard.clean.md    # expected clean-leg run
  scorecard.planted.md  # expected planted-leg run
```

Both `clean/` and `planted/` are full Scarb projects (per case VM), so `diff
cases/<n>-*/clean/src cases/<n>-*/planted/src` shows the planted bug as a
single localized hunk. CI runs both legs on every push.

## CI

Per case, the workflow asserts BOTH legs explicitly:

- **clean-passes:** the case's invariant suite runs against the CLEAN
  reference; CI asserts zero property violations within the case-specific
  timeout. Exit code zero AND no `INVARIANT VIOLATED` marker.
- **planted-bug-twin-fails:** the same suite runs against the PLANTED-BUG
  twin; CI asserts at least one violation. Exit code non-zero AND the
  marker present on stdout.

The top-level `atlas-all.yml` workflow runs every case on every push.
A `nightly.yml` cron runs the matrix daily so an upstream toolchain release
(scarb / snforge / anchor / foundry / move) surfaces as a red badge the
morning it lands, not when the next contributor stumbles on it.

## Running case 1 locally

Requires `scarb 2.18.0` and `snforge 0.60.x` or `0.61.x`.

```sh
# clean leg — properties hold
cd cases/01-cairo-zklend/clean
scarb build
snforge test

# planted leg — properties fire (≥1 INVARIANT VIOLATED marker; non-zero exit)
cd ../planted
scarb build
snforge test
```

See [cases/01-cairo-zklend/README.md](cases/01-cairo-zklend/README.md) for the
property prose, the planted-bug diff, and post-mortem citations.

## License

Apache-2.0 (see [LICENSE](LICENSE)). Attributions for the upstream canon,
the affected protocols' published post-mortems, and the toolchain authors are
in [NOTICE](NOTICE).

## AI disclosure

See [AI_DISCLOSURE.md](AI_DISCLOSURE.md).

## Contact

Operator: Michael Moffett — michael@caliperforge.com — team@caliperforge.com.
