// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @title GasSchedule (CLEAN twin) - Taiko execution-layer mirror for the L1 gas schedule.
///
/// Type-1 Ethereum-equivalence requires that the rollup charge L1's exact
/// gas costs for every opcode. The Atlas models the gas schedule as an
/// in-Solidity bookkeeping contract rather than executing real opcodes  -
/// real opcode costs would be the *Foundry VM's* costs, which are already
/// L1-equivalent; the bug class we want to catch is the *execution-client
/// shim* that quietly reuses a stale gas constant (EIP-2929, EIP-3529,
/// EIP-3651) or invents a "Taiko-cheaper" constant. The shim is a contract;
/// the contract is what the mirror models.
///
/// Specific cost we track: EIP-2929 cold-vs-warm SLOAD. Cold = 2100 gas
/// (EIP-2929 §"Specification": COLD_SLOAD_COST), warm = 100 gas
/// (WARM_STORAGE_READ_COST). A single deviation on either constant is a
/// Type-1 break.
///
/// Twin shape: CLEAN mirror returns the L1 constants verbatim. PLANTED twin
/// returns a constant that is off by the canonical EIP-2929 vs EIP-2200
/// regression (the cold-read used to be 800 under EIP-2200; the EIP-2929
/// uplift is the bug class an execution-client shim is most likely to miss).
///
/// Reference: EIP-2929 (Gas cost increases for state access opcodes),
/// EIP-3529 (Reduction in refunds). Cited in README.
contract GasSchedule {
    // CLEAN: post-EIP-2929 cold-SLOAD = 2100 (per EIP-2929 §Specification:
    // COLD_SLOAD_COST). A shim that forks its constants table off an older
    // spec snapshot and forgets the EIP-2929 uplift silently under-charges
    // every storage read - the canonical bug class this mirror catches.
    uint256 internal constant L1_COLD_SLOAD_COST = 2100;
    /// @notice Per-EIP-2929 §Specification: WARM_STORAGE_READ_COST.
    uint256 internal constant L1_WARM_SLOAD_COST = 100;

    /// @notice Mirror the canonical L1 cold-SLOAD gas cost.
    function coldSloadCost() external pure returns (uint256) {
        return L1_COLD_SLOAD_COST;
    }

    /// @notice Mirror the canonical L1 warm-SLOAD gas cost.
    function warmSloadCost() external pure returns (uint256) {
        return L1_WARM_SLOAD_COST;
    }
}
