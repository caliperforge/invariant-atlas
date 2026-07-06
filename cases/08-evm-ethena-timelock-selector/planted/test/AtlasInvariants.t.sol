// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

// Atlas case 8 — Guardian audit M-01 (Ethena TimelockController
// selector-extraction integrity) invariants.
//
// This test file is BYTE-IDENTICAL between cases/08-evm-ethena-timelock-selector/clean/
// and cases/08-evm-ethena-timelock-selector/planted/. Only src/G1EthenaTimelockHarness.sol
// differs between the two twins — the twin diff is confined to
// `_harnessExtractSelector`'s body inside the harness. The vendored
// EthenaTimelockController source at lib/ethena-timelock-defender/src/EthenaTimelockController.sol
// is also byte-identical between clean/ and planted/.
//
// Properties asserted (per the Guardian audit report M-01 "Native Asset
// Transfers Always Revert", 2025-05-26, Medium/Logical Error/Resolved;
// the clean leg holds them, the planted leg fires within the 256-run x
// depth-50 invariant runner budget plus a deterministic regression test):
//
//   A. g1_selector_extract_native_transfer_admissible (per-call temporal).
//        For every state transition, if the handler drove an empty-calldata
//        `harnessExecuteWhitelisted` call against a target whose bytes4(0)
//        selector was in the whitelist, the call MUST have succeeded. We
//        record cumulative (attempts, successes); the invariant asserts
//        attempts == successes.
//        CLEAN: the post-fix `_harnessExtractSelector` returns bytes4(0)
//               on empty calldata, the whitelist check passes, the outbound
//               call succeeds. attempts == successes at every step.
//        PLANTED: the pre-fix unconditional `bytes4(data[:SELECTOR_LENGTH])`
//               slice reverts out-of-bounds on empty calldata BEFORE the
//               whitelist check runs. attempts > successes → violates.
//
//   B. g1_selector_extract_short_data_reverts_typed (companion).
//        For every state transition, if the handler drove a
//        `harnessExecuteWhitelisted` call with `0 < data.length < 4` bytes
//        AND the (target, garbage-selector) pair was NOT whitelisted, the
//        call MUST have reverted. Both twins hold:
//        CLEAN reverts with the typed `InvalidSelector(data)` error at
//        `_harnessExtractSelector`. PLANTED reverts with an OOB panic at
//        the slice. The revert *shapes* differ but the observable outcome
//        (call reverted) matches — the companion keeps the campaign honest
//        about the short-data case and separates the specific specification
//        violation (empty-calldata admissibility) from the general "short
//        data reverts somehow" claim.
//
// AI-proposed invariant surface (Solidity Specialist agent, model
// claude-opus-4-6), against the Guardian audit M-01 report's own
// verbatim quotation of the pre-fix vulnerable code path
// (`bytes4 selector = bytes4(data[:SELECTOR_LENGTH])` unconditional
// slice, page 12). The class-fidelity gate hard-checks that the planted
// twin's `_harnessExtractSelector` body reproduces the exact
// `bytes4(data[:SELECTOR_LENGTH])` slice the audit cites.
//
// Foundry note: the stateful invariant runner is driven by `Handler` (a
// small actor-rotating wrapper) registered via `targetContract`. The
// deterministic regression `test_regression_g1_whitelisted_native_transfer_admissible`
// scripts the canonical empty-calldata whitelisted transfer end-to-end
// so the planted leg fires even if the fuzzer's random walk does not
// happen to hit the empty-calldata path within its run budget.

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {G1EthenaTimelockHarness} from "../src/G1EthenaTimelockHarness.sol";

// -------------------- MockTarget --------------------
//
// The Ethena timelock's `executeWhitelisted` outbound call needs a real
// contract on the other end (the base's `addToWhitelist` rejects targets
// with `code.length == 0`). MockTarget accepts ETH via `receive()` (the
// native-transfer path the audit's M-01 named as the specification-
// violation payload) and exposes `noop()` for the normal-calldata leg.
contract MockTarget {
    uint256 public receivedCount;
    uint256 public receivedValue;
    uint256 public noopCount;

    receive() external payable {
        receivedCount++;
        receivedValue += msg.value;
    }

    // Normal-calldata leg. Payable so `harnessExecuteWhitelisted` can
    // forward `msg.value` unchanged.
    function noop() external payable {
        noopCount++;
    }
}

// -------------------- Handler --------------------
//
// Foundry's stateful invariant runner calls one or more "target contracts"
// with fuzzed arguments. This Handler wraps the harness so the fuzzer can
// drive three distinct call shapes — empty calldata, normal (4+-byte)
// calldata, and short (1-3-byte) calldata — through a common surface. All
// three shapes go through the harness's `WHITELISTED_EXECUTOR_ROLE`-gated
// entrypoint via `vm.prank(EXECUTOR)`.
//
// The handler carries a per-shape (attempts, successes) ledger. Invariant
// A compares `emptyCalldata_attempts == emptyCalldata_successes`; invariant
// B compares `shortCalldata_successes == 0`. Both are cumulative counters
// so a single failed call is enough to violate the invariant permanently
// — Foundry's shrinker will narrow the failing sequence to the minimal
// call that first tripped the counter.
contract Handler is Test {
    G1EthenaTimelockHarness public immutable harness;
    MockTarget public immutable target;
    address public immutable EXECUTOR;

    // Per-shape (attempts, successes) counters. Property A asserts
    // `emptyCalldata_attempts == emptyCalldata_successes` (holds on CLEAN,
    // diverges on PLANTED). Property B asserts `shortCalldata_successes == 0`
    // (holds on both, keeps the campaign honest).
    uint256 public emptyCalldata_attempts;
    uint256 public emptyCalldata_successes;
    uint256 public shortCalldata_attempts;
    uint256 public shortCalldata_successes;
    uint256 public normalCalldata_attempts;
    uint256 public normalCalldata_successes;

    constructor(G1EthenaTimelockHarness _harness, MockTarget _target, address _executor) {
        harness = _harness;
        target = _target;
        EXECUTOR = _executor;
    }

    receive() external payable {}

    // ------------------------------------------------------------------
    // drive_emptyCalldata — the specification-violation payload.
    //
    // Whitelisted native-asset transfer: `data == ""`, whitelisted selector
    // is `bytes4(0)`. On CLEAN, `_harnessExtractSelector` returns bytes4(0),
    // the whitelist check passes, and the outbound low-level call triggers
    // MockTarget's `receive()` with `value`. On PLANTED, the pre-fix
    // unconditional slice `bytes4(data[:4])` reverts out-of-bounds BEFORE
    // the whitelist check runs — the call never reaches the target.
    //
    // The counter divergence on PLANTED (attempts > successes) is what
    // invariant A detects.
    // ------------------------------------------------------------------
    function drive_emptyCalldata(uint96 valueSeed) public {
        emptyCalldata_attempts++;
        uint256 v = (uint256(valueSeed) % 1 ether) + 1;
        vm.deal(EXECUTOR, v);
        vm.prank(EXECUTOR);
        try harness.harnessExecuteWhitelisted{value: v}(address(target), v, "") {
            emptyCalldata_successes++;
        } catch {
            // Selector-extraction revert on PLANTED (OOB panic on the
            // pre-fix slice); no other revert path applies here because
            // (target, bytes4(0)) is whitelisted at setUp and the
            // WHITELISTED_EXECUTOR_ROLE is granted to EXECUTOR.
        }
    }

    // ------------------------------------------------------------------
    // drive_normalCalldata — the normal path both twins accept.
    //
    // Whitelisted 4-byte call: `data == abi.encodeWithSelector(target.noop.selector)`,
    // whitelisted selector is `MockTarget.noop.selector`. Both twins
    // extract the selector as the first four bytes (the case where CLEAN
    // and PLANTED semantically agree) and the whitelist check passes.
    // Kept in the handler surface so the campaign covers the normal
    // path — a regression that broke `harnessExecuteWhitelisted` on
    // normal 4-byte calldata would surface as `normalCalldata_successes`
    // stalling at 0.
    // ------------------------------------------------------------------
    function drive_normalCalldata(uint96 valueSeed) public {
        normalCalldata_attempts++;
        uint256 v = (uint256(valueSeed) % 1 ether) + 1;
        vm.deal(EXECUTOR, v);
        bytes memory data = abi.encodeWithSelector(MockTarget.noop.selector);
        vm.prank(EXECUTOR);
        try harness.harnessExecuteWhitelisted{value: v}(address(target), v, data) {
            normalCalldata_successes++;
        } catch {}
    }

    // ------------------------------------------------------------------
    // drive_shortCalldata — 1-, 2-, or 3-byte data.
    //
    // CLEAN: `_harnessExtractSelector` reverts with the typed
    //        `InvalidSelector(data)` error (the middle branch of the
    //        three-case dispatch).
    // PLANTED: the pre-fix slice reverts out-of-bounds (raw panic 0x32).
    //
    // Different revert *shapes* — CLEAN's typed error vs. PLANTED's raw
    // panic — but both revert. Property B asserts
    // `shortCalldata_successes == 0` on both twins; the invariant runner
    // sees no divergence. What property B guards against: a bug that
    // silently truncates 1-3 byte calldata into a 4-byte selector by
    // zero-padding (which would let a garbage selector match a
    // whitelisted one). Neither twin has that bug; both hold.
    //
    // The `data` bytes are populated with arbitrary values (0x42, 0x43,
    // 0x44) that will not match any whitelisted selector on the harness
    // — so even if the CLEAN twin's InvalidSelector branch somehow got
    // bypassed, the whitelist check would still reject.
    // ------------------------------------------------------------------
    function drive_shortCalldata(uint8 lenSeed, uint96 valueSeed) public {
        shortCalldata_attempts++;
        uint256 len = (uint256(lenSeed) % 3) + 1; // 1, 2, or 3 bytes
        bytes memory data = new bytes(len);
        if (len >= 1) data[0] = 0x42;
        if (len >= 2) data[1] = 0x43;
        if (len >= 3) data[2] = 0x44;
        uint256 v = (uint256(valueSeed) % 1 ether) + 1;
        vm.deal(EXECUTOR, v);
        vm.prank(EXECUTOR);
        try harness.harnessExecuteWhitelisted{value: v}(address(target), v, data) {
            shortCalldata_successes++;
        } catch {}
    }
}

// -------------------- Invariant test contract --------------------

contract AtlasInvariantsTest is StdInvariant, Test {
    G1EthenaTimelockHarness internal harness;
    MockTarget internal mockTarget;
    Handler internal handler;

    address internal constant PROPOSER = address(0xB0B);
    address internal constant EXECUTOR = address(0xEEEE);

    function setUp() public {
        // Standard TimelockController constructor shape. `proposers` gets
        // PROPOSER_ROLE; `executors` gets EXECUTOR_ROLE (empty here — the
        // vendor's `execute` path is not the invariant surface).
        // `whitelistedExecutors` gets WHITELISTED_EXECUTOR_ROLE — this is
        // the role the harness's `harnessExecuteWhitelisted` gates on.
        address[] memory proposers = new address[](1);
        proposers[0] = PROPOSER;
        address[] memory executors = new address[](0);
        address[] memory whitelistedExecutors = new address[](1);
        whitelistedExecutors[0] = EXECUTOR;

        harness = new G1EthenaTimelockHarness(1 days, proposers, executors, whitelistedExecutors);
        mockTarget = new MockTarget();

        // Whitelist (mockTarget, bytes4(0)) for native-asset transfers
        // and (mockTarget, MockTarget.noop.selector) for the normal path.
        // The vendored `addToWhitelist` has `onlyTimelock` gating
        // (`_msgSender() == address(this)`). We satisfy it by pranking as
        // the harness address itself — the shortest path to authoritative
        // whitelist state without running the full schedule/execute
        // dance. The invariant fires on `executeWhitelisted`, not on
        // `addToWhitelist`, so short-circuiting setup is fine.
        vm.prank(address(harness));
        harness.addToWhitelist(address(mockTarget), bytes4(0));
        vm.prank(address(harness));
        harness.addToWhitelist(address(mockTarget), MockTarget.noop.selector);

        handler = new Handler(harness, mockTarget, EXECUTOR);

        // Only the handler's drive_* functions are fuzzable. The harness
        // and mockTarget are exercised THROUGH the handler so the
        // (attempts, successes) ledger stays consistent with the
        // on-chain outcomes.
        targetContract(address(handler));
    }

    // ------------------------------------------------------------------
    // Property A — g1_selector_extract_native_transfer_admissible.
    //
    // For every state transition, the count of empty-calldata whitelisted
    // execute attempts MUST equal the count of successes. The handler
    // records an attempt on every entry into drive_emptyCalldata and a
    // success only when the outbound call returned without reverting.
    //
    // CLEAN: `_harnessExtractSelector` returns bytes4(0) on empty
    //        calldata (post-fix semantics), the whitelist check passes,
    //        the outbound low-level call succeeds. attempts == successes.
    //
    // PLANTED: `bytes4(data[:SELECTOR_LENGTH])` unconditional slice
    //        reverts out-of-bounds on empty calldata (pre-fix semantics).
    //        The catch clause absorbs the revert; attempts increments
    //        but successes does not. attempts > successes → violates.
    //
    // Vacuously holds when no drive_emptyCalldata call has been attempted
    // yet.
    // ------------------------------------------------------------------
    function invariant_g1_selector_extract_native_transfer_admissible() public view {
        require(
            handler.emptyCalldata_attempts() == handler.emptyCalldata_successes(),
            "INVARIANT VIOLATED g1_selector_extract_native_transfer_admissible"
        );
    }

    // ------------------------------------------------------------------
    // Property B — g1_selector_extract_short_data_reverts_typed.
    //
    // For every state transition, no short-calldata (1-3 byte, unrelated
    // content) whitelisted-execute attempt should have succeeded. Both
    // twins hold: CLEAN reverts with the typed InvalidSelector(data),
    // PLANTED reverts with an OOB panic on the slice.
    //
    // Guards against a hypothetical bug where 1-3 byte calldata would be
    // zero-padded into a 4-byte selector — which would let a garbage
    // selector accidentally match a whitelisted one. Neither twin does
    // that; both fire this defense.
    // ------------------------------------------------------------------
    function invariant_g1_selector_extract_short_data_reverts_typed() public view {
        require(
            handler.shortCalldata_successes() == 0,
            "INVARIANT VIOLATED g1_selector_extract_short_data_reverts_typed"
        );
    }

    // ------------------------------------------------------------------
    // Deterministic regression — the canonical M-01 payload end-to-end.
    //
    // Scripts a whitelisted-executor calling `harnessExecuteWhitelisted`
    // with 1 ether of value and empty calldata against a MockTarget whose
    // `bytes4(0)` selector was pre-registered in setUp. This is the exact
    // shape the audit report M-01 names: a native-asset transfer to a
    // whitelisted receive/fallback path.
    //
    // CLEAN: the call succeeds; MockTarget's `receive()` fires; the
    //        `execOk` flag is true; the require holds → test passes.
    // PLANTED: the call reverts at the selector-extraction step (pre-fix
    //        OOB slice); `execOk` is false; the require fails with the
    //        `INVARIANT VIOLATED g1_selector_extract_native_transfer_admissible`
    //        marker → test fails.
    //
    // Kept as a fixed-shape test alongside the fuzz campaign so the
    // planted leg fires deterministically even if the fuzzer's random
    // walk did not happen to hit `drive_emptyCalldata` within its run
    // budget.
    // ------------------------------------------------------------------
    function test_regression_g1_whitelisted_native_transfer_admissible() public {
        vm.deal(EXECUTOR, 1 ether);
        vm.prank(EXECUTOR);
        (bool execOk, ) = address(harness).call{value: 1 ether}(
            abi.encodeWithSelector(
                G1EthenaTimelockHarness.harnessExecuteWhitelisted.selector,
                address(mockTarget),
                uint256(1 ether),
                bytes("")
            )
        );
        emit log_named_uint("whitelisted_native_transfer_ok", execOk ? 1 : 0);
        require(
            execOk,
            "INVARIANT VIOLATED g1_selector_extract_native_transfer_admissible"
        );
    }

    // ------------------------------------------------------------------
    // Unit tests — entrypoint coverage
    // ------------------------------------------------------------------

    function test_unit_constructor_state() public view {
        assertTrue(
            harness.hasRole(harness.WHITELISTED_EXECUTOR_ROLE(), EXECUTOR),
            "ctor: executor role granted"
        );
        assertTrue(
            harness.hasRole(harness.PROPOSER_ROLE(), PROPOSER),
            "ctor: proposer role granted"
        );
        assertTrue(
            harness.isWhitelisted(address(mockTarget), bytes4(0)),
            "ctor: native transfer whitelisted"
        );
        assertTrue(
            harness.isWhitelisted(address(mockTarget), MockTarget.noop.selector),
            "ctor: noop whitelisted"
        );
    }

    function test_unit_normal_calldata_call_succeeds() public {
        // Legitimate 4-byte calldata call succeeds on both twins. The
        // twin diff is confined to the shorter-than-4-byte branches;
        // the normal-length path is behaviorally identical.
        vm.deal(EXECUTOR, 1 ether);
        vm.prank(EXECUTOR);
        harness.harnessExecuteWhitelisted{value: 1 ether}(
            address(mockTarget),
            1 ether,
            abi.encodeWithSelector(MockTarget.noop.selector)
        );
        assertEq(mockTarget.noopCount(), 1, "noop called");
    }

    function test_unit_non_whitelisted_selector_rejected() public {
        // Sanity: even on the planted twin, a non-whitelisted selector
        // still gets rejected by the base's `isWhitelisted` check. The
        // planted bug is at the selector-extraction step, upstream of
        // the whitelist gate — the whitelist itself continues to work.
        // This unit asserts the defense-in-depth on both legs.
        bytes memory data = abi.encodeWithSelector(bytes4(0xDEADBEEF));
        vm.deal(EXECUTOR, 1 ether);
        vm.prank(EXECUTOR);
        (bool ok, ) = address(harness).call{value: 1 ether}(
            abi.encodeWithSelector(
                G1EthenaTimelockHarness.harnessExecuteWhitelisted.selector,
                address(mockTarget),
                uint256(1 ether),
                data
            )
        );
        assertFalse(ok, "non-whitelisted selector must be rejected");
    }
}
