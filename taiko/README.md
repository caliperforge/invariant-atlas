# Taiko Equivalence Subdir - Planted-Twin Atlas

Planted-twin invariant cases for **Taiko's Type-1 Ethereum-equivalence**
priority, plus a **differential Foundry harness** that runs the same input
against a canonical L1 reference fixture and the Taiko execution-layer
mirror under test, then asserts byte-equivalence.

Three illustrative cases ship in v0.1. The atlas scales post-grant; the
cases here are the existence proof, not the exhaustive catalogue.

## Why these cases

Taiko's grant program lists three named priorities: **Ethereum-equivalence,
based design, permissionless proposing/proving**. Each case targets one
priority surface.

| Case | Type-1 / based-rollup spec point | Taiko docs reference |
|---|---|---|
| **PrecompileParity** | Yellow Paper Appendix E (precompiled contracts): canonical L1 precompiles MUST return byte-identical output. Tested via SHA256 (`0x02`) on three input vectors (empty, the NIST FIPS 180-4 "abc" vector, fuzzed 1 KiB buffer). | Taiko docs §"Ethereum-equivalence" - "Taiko is a Type-1 ZK-EVM that aims for full equivalence with Ethereum's specification, including precompiled contracts." (https://docs.taiko.xyz/core-concepts/multi-proofs) |
| **GasScheduleEquivalence** | EIP-2929 (cold/warm storage access cost): cold SLOAD = 2100 gas, warm SLOAD = 100 gas. A Type-1 rollup MUST not silently re-price storage reads. Planted twin substitutes the pre-EIP-2929 constant (800) for cold SLOAD - the canonical bug class an execution-client shim ships when its constants table was forked off an older snapshot. | EIP-2929 §"Specification" (https://eips.ethereum.org/EIPS/eip-2929); Taiko whitepaper §"Why Type-1" - gas-schedule equivalence is the discriminator between Type-1 and Type-2 (https://taiko.xyz/whitepaper.pdf) |
| **BasedSequencingOrdering** | Based-rollup proposing rule: the prover MUST attest to the inclusion list in proposal order. Sorting by priority-fee descending IS the canonical sequencer-MEV-extraction violation that based-sequencing forbids by construction. | Taiko whitepaper §"Based Contestable Rollup" - proposing-and-proving roles are decoupled; based sequencing inherits L1's ordering rule via L1 inclusion (https://taiko.xyz/whitepaper.pdf); Taiko docs §"Based contestable rollup" (https://docs.taiko.xyz/core-concepts/based-contestable-rollup) |

## Layout

Same shape as `cases/<n>-*/` and `v4-hooks/` - `clean/` and `planted/`
are full Foundry projects. Toolchain config is byte-identical between
the two twins; only the three contracts under `src/` differ.

```
taiko/
  README.md                    # this file
  clean/
    foundry.toml               # solc 0.8.28; CI-friendly fuzz/invariant budgets
    remappings.txt
    lib/forge-std              # symlink to cases/07-evm-newmarket-2026-05/clean/lib/forge-std
    src/
      PrecompileMirror.sol     # passes through to precompile 0x02
      GasSchedule.sol          # post-EIP-2929 constants (2100 / 100)
      BasedSequencer.sol       # preserves insertion order on finalize()
    test/
      Equivalence.t.sol        # differential harness - all three cases
  planted/
    foundry.toml               # byte-identical to clean/foundry.toml
    remappings.txt
    lib/forge-std              # symlink
    src/
      PrecompileMirror.sol     # XOR-masks top byte of SHA256 output
      GasSchedule.sol          # pre-EIP-2929 cold SLOAD (800)
      BasedSequencer.sol       # sorts by priority-fee descending on finalize()
    test/
      Equivalence.t.sol        # BYTE-IDENTICAL to clean/test/Equivalence.t.sol
```

`diff taiko/clean/src taiko/planted/src` shows the three planted hunks as
single-localized mutations - the same discipline used in
`bsc-invariants` and the rest of the atlas.

## Differential harness

`test/Equivalence.t.sol` is the ONE new build component for the Taiko
program-specific demo. It composes against the existing
`hyperevm-safety` Foundry skeleton (solc 0.8.28, forge-std v1.9.4,
`INVARIANT VIOLATED <name>` marker convention from spec §5.2).

For each case, the harness:

1. Reads a fixed canonical L1 reference (precompile `0x02`,
   EIP-2929 constants, or insertion-order golden hash). Forge's local
   EVM is itself L1-equivalent, so calling precompile `0x02` directly
   gives us a contemporaneous L1 SHA256 output without forking a remote
   node.

2. Reads the Taiko execution-layer mirror under test.

3. Asserts byte-equivalence. On divergence: emits
   `INVARIANT VIOLATED <CaseName>` on stdout, dumps the L1 vs mirror
   bytes, and reverts with the same marker as the revert reason - so
   the §5.2 CI grep convention picks it up.

The harness is byte-identical between `clean/test/` and `planted/test/`.
The `clean/` leg passes silently; the `planted/` leg fires the marker on
every case that has a planted hunk. This is the same dual-leg discipline
the rest of the atlas uses.

## Running locally

Requires `forge` 1.7.x (foundry nightly compatible).

```sh
# clean leg - equivalence holds
cd clean
forge test            # 6/6 pass, zero INVARIANT VIOLATED markers

# planted leg - equivalence fails on every twin
cd ../planted
forge test -vv        # 5 of 6 tests fail with INVARIANT VIOLATED markers
                      # (warm SLOAD test stays green - the planted hunk
                      # only mutated cold SLOAD, demonstrating the
                      # single-localized-hunk discipline)
```

CI runs both legs on every push - `clean-passes` asserts zero violations
and zero exit code; `planted-bug-twin-fails` asserts at least one
`INVARIANT VIOLATED` marker on stdout and a non-zero exit code.

## Scope discipline

These three cases are illustrative. The Type-1 surface is much larger
(every precompile address, every opcode gas cost, every state-access
edge case from EIP-2929 / EIP-3529 / EIP-3651, plus the based-rollup
proving-pipeline race conditions). The post-grant atlas expands case
coverage; this v0.1 ships the pattern (planted twin + differential
harness + INVARIANT VIOLATED marker convention) that every additional
case will reuse.

The L1 reference fixture in the harness is the in-process Foundry EVM,
not a remote L1 fork. That suffices for the bug-class demonstration. A
post-grant extension can replace the in-process fixture with a forked
L1 RPC endpoint (`vm.createSelectFork`) to lift the differential harness
to a true cross-chain check; the harness already isolates the L1 vs
mirror call shape behind the same interface, so the lift is a one-line
substitution per case.

## License and attribution

Apache-2.0 (see top-level `../LICENSE`). Subdir-specific upstream
attributions for the Ethereum Yellow Paper, the EIP authors (EIP-2929),
NIST FIPS 180-4, and Taiko Labs documentation are in `./NOTICE`; the
atlas-wide NOTICE at `../NOTICE` carries the benchmark-canon and
broader toolchain-author attributions. The AI-disclosure footer for the
atlas as a whole is in `../AI_DISCLOSURE.md`.
