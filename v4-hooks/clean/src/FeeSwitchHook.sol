// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IHooks} from "./IHooks.sol";

/// @title FeeSwitchHook (H2 CLEAN twin) - beforeSwap/afterSwap fee path.
///
/// Hook accrues a protocol fee (FEE_BPS of amountIn) into an internal
/// ledger on every swap, unless the swap caller (the `sender` argument,
/// which in production v4 is the routing contract calling
/// `PoolManager.swap`) is on an admin-controlled exempt list. The bug
/// class lives in WHERE the waiver decision comes from: an
/// admin-controlled mapping (clean), or a caller-controlled flag inside
/// hookData (planted).
///
/// CLEAN: waiver is gated by the admin-set `isExempt[sender]` mapping.
/// hookData is ignored for the fee decision.
///
/// PLANTED (see ../../../planted/src/FeeSwitchHook.sol): waiver also
/// checks a flag in `hookData[0]`. Any caller can paste the waiver byte
/// and evade the fee.
///
/// Audit-finding category: "Hook honors a caller-supplied 'fee waiver'
/// without authentication." The v4-hook audit canon flags this as a
/// recurring shape across hooks that wire dynamic-fee or rebate logic
/// to hookData.
///
/// What this is NOT:
///   - NOT a fork of any specific production fee-switch hook. The shape
///     is the minimal "decide waive, accrue fee" loop the bug class
///     requires.
///   - NOT a runtime guard. The property in test/H2_FeeEvasion.t.sol is
///     a pre-deploy stateful invariant test.
contract FeeSwitchHook is IHooks {
    /// Admin who controls the exempt mapping. Set at construction.
    address public immutable admin;

    /// Admin-controlled exempt list keyed by the swap caller (router)
    /// address. Routers in this set pay zero fee.
    mapping(address => bool) public isExempt;

    /// Running total of accrued protocol fees, in input-token units.
    /// The test's invariant compares this to the handler's expected
    /// ledger (recomputed from swap volume + admin exempt-set state).
    uint256 public accruedFees;

    /// Protocol fee in basis points (30 = 0.30%).
    uint256 public constant FEE_BPS = 30;

    event ExemptUpdated(address indexed actor, bool allowed);
    event FeeAccrued(address indexed sender, uint256 amountIn, uint256 fee);

    error NotAdmin();

    constructor(address _admin) {
        require(_admin != address(0), "FeeSwitchHook: zero admin");
        admin = _admin;
    }

    function setExempt(address actor, bool allowed) external {
        if (msg.sender != admin) revert NotAdmin();
        isExempt[actor] = allowed;
        emit ExemptUpdated(actor, allowed);
    }

    function beforeSwap(address, IHooks.PoolKey calldata, IHooks.SwapParams calldata, bytes calldata) external pure {
        // No-op on this hook. The fee logic lives in afterSwap because
        // the accrual is sized against the realized amountIn.
    }

    function afterSwap(
        address sender,
        IHooks.PoolKey calldata,
        IHooks.SwapParams calldata,
        uint256 amountIn,
        uint256,
        bytes calldata hookData
    ) external {
        // CLEAN: hookData is not consulted for the waiver decision. The
        // admin's exempt mapping is the only authorization source.
        (hookData);
        if (!isExempt[sender]) {
            uint256 fee = (amountIn * FEE_BPS) / 10000;
            accruedFees += fee;
            emit FeeAccrued(sender, amountIn, fee);
        }
    }
}
