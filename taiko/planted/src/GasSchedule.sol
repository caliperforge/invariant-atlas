// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @title GasSchedule - Taiko execution-layer mirror for the L1 gas schedule.
///
/// PLANTED-TWIN VARIANT. See `clean/src/GasSchedule.sol` for the full header.
/// The planted hunk substitutes the pre-EIP-2929 cold-SLOAD constant (800)
/// for the post-EIP-2929 value (2100). This is the bug class an execution-
/// client shim is most likely to ship if its constants table was forked
/// off an older spec snapshot and not re-checked.
contract GasSchedule {
    // Planted bug: pre-EIP-2929 constant. EIP-2200 had cold = 800; EIP-2929
    // raised it to 2100. A shim that forgot the EIP-2929 update silently
    // under-charges every storage read by 1300 gas - a multi-thousand-tx
    // discrepancy that the protocol's happy-path fuzz tests will not flag.
    uint256 internal constant L1_COLD_SLOAD_COST = 800;
    uint256 internal constant L1_WARM_SLOAD_COST = 100;

    function coldSloadCost() external pure returns (uint256) {
        return L1_COLD_SLOAD_COST;
    }

    function warmSloadCost() external pure returns (uint256) {
        return L1_WARM_SLOAD_COST;
    }
}
