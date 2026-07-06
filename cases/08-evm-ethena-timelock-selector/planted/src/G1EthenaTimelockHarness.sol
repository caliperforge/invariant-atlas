// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {EthenaTimelockController} from "ethena-timelock-defender/EthenaTimelockController.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title G1EthenaTimelockHarness — PLANTED twin for Atlas case 8
///        (Guardian audit M-01: Ethena TimelockController selector-extraction integrity).
///
/// Same-source twin of the whitelisted-executor selector-extraction path.
/// Both twins subclass Guardian's vendored `EthenaTimelockController`
/// (post-fix, MIT SPDX) at
///     lib/ethena-timelock-defender/src/EthenaTimelockController.sol
/// which is byte-identical between clean/ and planted/. The vendored file
/// is NEVER mutated. The single-hunk twin diff lives here, in the harness
/// contract's `_harnessExtractSelector` — this PLANTED twin re-implements
/// the pre-fix behavior (`bytes4(data[:SELECTOR_LENGTH])` unconditional
/// slice, which reverts out-of-bounds on empty or shorter-than-4-byte
/// calldata). The CLEAN twin uses the vendor's post-fix semantics.
///
/// A `diff -r ../clean/src ../planted/src` shows the planted hunk as a
/// single change in `_harnessExtractSelector`'s body — the three-case
/// dispatch (empty / short / full) collapses to an unconditional slice.
/// Every other file in the twin is byte-identical: the vendored
/// EthenaTimelockController, foundry.toml, remappings.txt, and the
/// invariant test file.
///
/// Bug class (per Guardian audit report M-01, 2025-05-26, Medium severity,
/// Logical Error, Resolved):
///
///   The pre-fix `executeWhitelisted` extracted the selector unconditionally
///   as `bytes4 selector = bytes4(data[:SELECTOR_LENGTH])`. On empty calldata
///   (native-asset transfers via a whitelisted receive/fallback path — the
///   whitelisted selector being `bytes4(0)`), this slice reverts with an
///   out-of-bounds error BEFORE the whitelist check runs. Consequence: a
///   whitelisted native-asset transfer that the admin had explicitly
///   authorized cannot be executed. Ethena PR#4 introduced the
///   `_extractSelector` helper that admits `data.length == 0 -> bytes4(0)`
///   and reverts with a typed `InvalidSelector(data)` on `0 < data.length < 4`,
///   while preserving the normal `data.length >= 4` case unchanged.
///
/// The audit report M-01 quotes the vulnerable code path directly (report
/// page 12): "if we tried to, set data.length to 0, it would revert in the
/// EthenaTimelockController.execute function, when trimming the call data
/// as the call data would be empty as we initially stated". The planted
/// twin's `_harnessExtractSelector` body reproduces the exact
/// `bytes4(data[:SELECTOR_LENGTH])` slice cited.
///
/// Subclass-real design note (deviation from the Director spec's §1d
/// verbatim `override` shape; see README.md §Subclass-real note):
///
///   The Director spec §1d proposed overriding `_extractSelector` in the
///   harness. But the vendored `_extractSelector` is NOT declared `virtual`
///   (see lib/ethena-timelock-defender/src/EthenaTimelockController.sol
///   L209), so an `override` in the subclass would not compile against the
///   vendor's MIT-vendored source. Mutating the vendored source to add
///   `virtual` was rejected on the rail "planted bugs live only in our
///   harness; never mutate vendored source." The subclass-real
///   interpretation adopted here: both twins add a harness entrypoint
///   `harnessExecuteWhitelisted(target, value, data)` that inlines the
///   vendored `executeWhitelisted` body from three deviations away, no
///   fewer, no more:
///     (1) the selector-extraction step is factored into
///         `_harnessExtractSelector(data)` (the twin-diff hunk);
///     (2) the base's `nonReentrant` guard is intentionally NOT applied on
///         the harness path (see the `harnessExecuteWhitelisted` comment
///         block below for the fuzz-latch rationale);
///     (3) the base's `emit WhitelistedFunctionExecuted(target, selector,
///         value, data)` on-chain observability event is omitted; the
///         invariant surface's ledger lives in the handler counters, not
///         on-chain event logs, so re-emitting it would add noise without
///         moving the property.
///   The vendored base's `isWhitelisted` public view, the `NotWhitelisted`
///   typed error, the `WHITELISTED_EXECUTOR_ROLE` gate, and the low-level
///   `Address.functionCallWithValue` ARE reused unchanged. The ONLY line
///   the two twins differ on (between clean/ and planted/) is the
///   selector-extraction body, which reduces to the exact vulnerable
///   `bytes4(data[:SELECTOR_LENGTH])` slice the audit's M-01 quotes.
///
/// Property surface asserted by test/AtlasInvariants.t.sol:
///
///   A. g1_selector_extract_native_transfer_admissible (per-call temporal).
///      For every state transition, if a `harnessExecuteWhitelisted` was
///      driven with either empty calldata OR `data.length >= 4`, AND the
///      corresponding (target, selector) pair was in the whitelist at
///      the time of the call, then the call must NOT have reverted at
///      the selector-extraction stage. This PLANTED twin fires on the
///      empty-calldata case: the pre-fix slice reverts out-of-bounds
///      before the whitelist check runs.
///
///   B. g1_selector_extract_short_data_reverts_typed (companion).
///      For every state transition, if a `harnessExecuteWhitelisted` was
///      driven with `0 < data.length < 4`, the call MUST have reverted.
///      Both twins hold: CLEAN reverts with typed `InvalidSelector(data)`;
///      PLANTED reverts with an OOB panic. The revert *shapes* differ but
///      the observable outcome (call reverted) matches — the companion
///      keeps the campaign honest about the short-data case and separates
///      the specific specification violation (empty-calldata admissibility)
///      from the general "short data reverts somehow" claim.
contract G1EthenaTimelockHarness is EthenaTimelockController {
    // SELECTOR_LENGTH = 4 is declared `private constant` on the vendored
    // base (see lib/ethena-timelock-defender/src/EthenaTimelockController.sol
    // L29). Solidity's `private` visibility means it is not accessible from
    // the derived contract, so we re-declare the same constant here. This
    // is the ONLY constant duplicated; every other symbol the harness uses
    // is inherited from the base.
    uint256 private constant SELECTOR_LENGTH = 4;

    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address[] memory whitelistedExecutors
    ) EthenaTimelockController(minDelay, proposers, executors, whitelistedExecutors) {}

    // ------------------------------------------------------------------
    // harnessExecuteWhitelisted — mirrors the vendored base's
    // `executeWhitelisted(target, value, data)` body with three named
    // deviations (see the contract-level NatSpec §Subclass-real design
    // note above for the full accounting):
    //   (1) the selector-extraction step is factored into
    //       `_harnessExtractSelector` (the twin-diff hunk);
    //   (2) the base's `nonReentrant` guard is intentionally NOT applied
    //       on the harness path (fuzz-latch rationale, discussed below);
    //   (3) the base's `emit WhitelistedFunctionExecuted(target, selector,
    //       value, data)` observability event is omitted; the invariant
    //       surface's ledger lives in the handler counters, not on-chain
    //       event logs.
    // Same `WHITELISTED_EXECUTOR_ROLE` role gate. Same whitelist check via
    // the base's public `isWhitelisted`. Same low-level call semantics via
    // `Address.functionCallWithValue`. The single-hunk twin diff (between
    // clean/ and planted/) is contained to `_harnessExtractSelector`.
    //
    // CLEAN (../clean/src/G1EthenaTimelockHarness.sol):
    //        `_harnessExtractSelector` mirrors the vendored base's
    //        post-fix `_extractSelector` semantics — empty calldata
    //        resolves to `bytes4(0)`; short calldata reverts with the
    //        typed `InvalidSelector(data)` error; full calldata slices
    //        the first four bytes. Whitelisted native-asset transfers
    //        (bytes4(0) selector) succeed.
    //
    // PLANTED: the selector is extracted via the pre-fix unconditional
    //        `bytes4(data[:SELECTOR_LENGTH])` slice, which reverts
    //        out-of-bounds on `data.length < 4` including empty calldata.
    //        Whitelisted native-asset transfers are rejected at the
    //        selector-extraction stage BEFORE the whitelist check runs.
    //
    // Reentrancy: the vendored base's `executeWhitelisted` carries a
    // `nonReentrant` guard from `ReentrancyGuard`. The harness path does
    // NOT re-enter (it makes a single external call at the end), and the
    // invariant campaign runs in a controlled harness so re-entrancy is
    // not the property surface here. The base's guard is intentionally
    // NOT applied to the harness path so multiple invariant sequences in
    // the same block do not fail on the reentrancy latch.
    // ------------------------------------------------------------------
    function harnessExecuteWhitelisted(address target, uint256 value, bytes calldata data)
        external
        payable
        onlyRole(WHITELISTED_EXECUTOR_ROLE)
    {
        bytes4 selector = _harnessExtractSelector(data);
        if (!isWhitelisted(target, selector)) {
            revert NotWhitelisted(target, selector);
        }
        Address.functionCallWithValue(target, data, value);
    }

    // ------------------------------------------------------------------
    // PLANTED twin's selector extraction — the seeded specification
    // violation. Reproduces the pre-fix behavior the audit report M-01
    // quotes: an unconditional `bytes4(data[:SELECTOR_LENGTH])` slice.
    //
    //   - data.length >= 4: slice yields the first four bytes; matches
    //     the CLEAN twin's normal-case result.
    //   - data.length < 4 (including data.length == 0): the slice
    //     `data[:4]` reads past the calldata bound and Solidity's calldata
    //     slice bounds check reverts with an OOB panic (0x32 selector).
    //     The revert happens BEFORE the whitelist check runs. On empty
    //     calldata specifically, a whitelisted `bytes4(0)` selector for
    //     a native-asset transfer is unreachable — the audit's M-01
    //     "Native Asset Transfers Always Revert" specification violation.
    //
    // The single-line body is deliberately minimal: this IS the pre-fix
    // vulnerable line the audit report reproduces verbatim.
    // ------------------------------------------------------------------
    function _harnessExtractSelector(bytes calldata data) internal pure returns (bytes4 selector) {
        // PLANTED twin: pre-fix `_extractSelector` semantics (the seeded
        // specification violation).
        //
        // The pre-fix behavior the audit's M-01 quotes: unconditional
        // slice of the first SELECTOR_LENGTH (=4) bytes. On empty or
        // shorter-than-4-byte calldata, this reverts with an OOB panic
        // BEFORE the whitelist check has a chance to run — the exact
        // pathology the audit describes.
        //
        // The CLEAN twin's counterpart at ../clean/src/G1EthenaTimelockHarness.sol
        // handles data.length == 0 (returns bytes4(0)) and 0 < data.length < 4
        // (typed InvalidSelector revert) explicitly; those two branches are
        // absent here. That absence IS the plant.
        selector = bytes4(data[:SELECTOR_LENGTH]);
    }
}
