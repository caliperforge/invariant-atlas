// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {PrecompileMirror} from "../src/PrecompileMirror.sol";
import {GasSchedule} from "../src/GasSchedule.sol";
import {BasedSequencer} from "../src/BasedSequencer.sol";

/// @title EquivalenceTest - the ONE differential Foundry harness.
///
/// For each of the three planted-twin cases (precompile parity, gas-
/// schedule accounting, based-sequencing ordering) this harness runs the
/// same input against:
///
///   - L1 reference fixture: canonical Ethereum semantics, constructed
///     in-test from the Yellow Paper / EIP constants / canonical
///     precompile addresses. Forge's local EVM is itself L1-equivalent,
///     so calling precompile `0x02` directly gives us a contemporaneous
///     L1 SHA256 output without forking a remote node.
///
///   - Taiko execution-layer mirror: the contract under test. Clean leg's
///     mirror MUST be byte-equivalent to L1; planted leg's mirror MUST
///     diverge by exactly the single planted hunk and fire the
///     `INVARIANT VIOLATED <case>` marker on stdout (spec §5.2 / the
///     `bsc-invariants` and `hyperevm-safety` convention).
///
/// The file is byte-identical between `clean/test/` and `planted/test/`.
/// Only the three source contracts under `src/` differ between the twins.
///
/// Scope discipline: cases are illustrative, not exhaustive. The atlas
/// scales post-grant; the differential harness pattern is the reusable
/// shape, the three cases are the existence proof.
contract EquivalenceTest is Test {
    PrecompileMirror internal precompile;
    GasSchedule internal gas;
    BasedSequencer internal seq;

    // EIP-2929 canonical constants - used as the L1 fixture for the
    // gas-schedule equivalence case.
    uint256 internal constant L1_COLD_SLOAD = 2100;
    uint256 internal constant L1_WARM_SLOAD = 100;

    function setUp() public {
        precompile = new PrecompileMirror();
        gas = new GasSchedule();
        seq = new BasedSequencer();
    }

    // -------------------------------------------------------------------
    // Case 1: precompile parity. Type-1 spec point: canonical L1
    // precompiles return byte-identical output on Taiko. Tested via
    // SHA256 (precompile 0x02) on three input vectors: empty bytes, the
    // ASCII string "abc" (NIST FIPS 180-4 test vector), and a 1 KiB
    // pseudo-random buffer.
    // -------------------------------------------------------------------

    function test_precompileParity_emptyInput() public view {
        bytes memory input = bytes("");
        bytes32 l1 = sha256(input);
        bytes32 mirrored = precompile.sha256Mirrored(input);
        if (l1 != mirrored) {
            console2.log("INVARIANT VIOLATED PrecompileParity");
            console2.logBytes32(l1);
            console2.logBytes32(mirrored);
            revert("INVARIANT VIOLATED PrecompileParity");
        }
    }

    function test_precompileParity_abcVector() public view {
        bytes memory input = bytes("abc");
        bytes32 l1 = sha256(input);
        bytes32 mirrored = precompile.sha256Mirrored(input);
        if (l1 != mirrored) {
            console2.log("INVARIANT VIOLATED PrecompileParity");
            console2.logBytes32(l1);
            console2.logBytes32(mirrored);
            revert("INVARIANT VIOLATED PrecompileParity");
        }
    }

    function testFuzz_precompileParity_randomBuffer(bytes memory input) public view {
        // Bound input length so the campaign stays CI-friendly.
        if (input.length > 1024) {
            assembly {
                mstore(input, 1024)
            }
        }
        bytes32 l1 = sha256(input);
        bytes32 mirrored = precompile.sha256Mirrored(input);
        if (l1 != mirrored) {
            console2.log("INVARIANT VIOLATED PrecompileParity");
            console2.log("  input.length =", input.length);
            console2.logBytes32(l1);
            console2.logBytes32(mirrored);
            revert("INVARIANT VIOLATED PrecompileParity");
        }
    }

    // -------------------------------------------------------------------
    // Case 2: gas-schedule equivalence. Type-1 spec point: post-EIP-2929
    // cold-SLOAD = 2100 gas; warm-SLOAD = 100 gas. A Taiko mirror that
    // ships pre-EIP-2929 constants under-charges every storage read by
    // 1300 gas - silently extracts value from app developers who priced
    // their fees against the L1 schedule.
    // -------------------------------------------------------------------

    function test_gasSchedule_coldSloadEquivalence() public view {
        uint256 mirrored = gas.coldSloadCost();
        if (mirrored != L1_COLD_SLOAD) {
            console2.log("INVARIANT VIOLATED GasScheduleEquivalence");
            console2.log("  expected L1 cold SLOAD =", L1_COLD_SLOAD);
            console2.log("  mirrored               =", mirrored);
            revert("INVARIANT VIOLATED GasScheduleEquivalence");
        }
    }

    function test_gasSchedule_warmSloadEquivalence() public view {
        uint256 mirrored = gas.warmSloadCost();
        if (mirrored != L1_WARM_SLOAD) {
            console2.log("INVARIANT VIOLATED GasScheduleEquivalence");
            console2.log("  expected L1 warm SLOAD =", L1_WARM_SLOAD);
            console2.log("  mirrored               =", mirrored);
            revert("INVARIANT VIOLATED GasScheduleEquivalence");
        }
    }

    // -------------------------------------------------------------------
    // Case 3: based-sequencing ordering. Type-1 / based-rollup spec
    // point: the prover MUST attest to the inclusion list in proposal
    // order; sorting by priority fee descending is a sequencer-MEV-
    // extraction violation that based-sequencing forbids.
    //
    // Adversarial schedule: propose tx in priority-fee ASCENDING order so
    // that a "sort by priority fee descending" planted bug REORDERS, but
    // a clean insertion-order finalize preserves the original list.
    // -------------------------------------------------------------------

    function test_basedSequencingOrdering_preservesProposalOrder() public {
        bytes32 txA = keccak256("tx-A");
        bytes32 txB = keccak256("tx-B");
        bytes32 txC = keccak256("tx-C");

        // Proposal order: A (low fee), B (mid fee), C (high fee).
        seq.propose(txA, 1 gwei);
        seq.propose(txB, 5 gwei);
        seq.propose(txC, 50 gwei);

        bytes32[] memory order = seq.finalize();

        bytes32[3] memory expected = [txA, txB, txC];
        bool diverged =
            order.length != 3 || order[0] != expected[0] || order[1] != expected[1] || order[2] != expected[2];
        if (diverged) {
            console2.log("INVARIANT VIOLATED BasedSequencingOrdering");
            console2.log("  expected[0]");
            console2.logBytes32(expected[0]);
            console2.log("  observed[0]");
            console2.logBytes32(order[0]);
            console2.log("  expected[1]");
            console2.logBytes32(expected[1]);
            console2.log("  observed[1]");
            console2.logBytes32(order[1]);
            console2.log("  expected[2]");
            console2.logBytes32(expected[2]);
            console2.log("  observed[2]");
            console2.logBytes32(order[2]);
            revert("INVARIANT VIOLATED BasedSequencingOrdering");
        }
    }
}
