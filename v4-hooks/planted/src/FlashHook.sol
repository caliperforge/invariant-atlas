// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IHooks} from "./IHooks.sol";
import {MockPoolManager} from "./MockPoolManager.sol";

/// @title FlashHook (H3 PLANTED twin) - nested-call flash accounting.
///
/// Hook offers a small bonus rebate path that triggers when the
/// caller-supplied `hookData[0] == 0xBB`. The bonus is paid by a nested
/// `manager.take(sender, BONUS)` call inside `beforeSwap`. The bug
/// class lives in whether the hook also settles its own resulting debit
/// so the unlock's end-of-callback net-delta check still holds.
///
/// CLEAN: hook pairs `take` with a matching `settle` so its own delta
/// nets to zero. The user receives the bonus, the hook covers it from
/// its own balance sheet, and the unlock's flash-accounting check
/// holds.
///
/// PLANTED (see ../../../planted/src/FlashHook.sol): hook calls `take`
/// without the matching `settle`. The hook's delta ends the unlock at
/// `-BONUS`, the pool manager reverts with `DeltaNotZero(-BONUS)`, and
/// the unlock cannot complete. On the real Uniswap v4 PoolManager this
/// same shape would fail the flash-accounting invariant identically.
///
/// Audit-finding category: "Hook makes nested PoolManager calls inside
/// a callback without settling its own delta." The v4-hook audit canon
/// flags this as the highest-severity recurring shape, because it
/// either (a) breaks the unlock (DoS on every swap that hits the hook
/// path) or (b) leaks PoolManager-held funds if the manager's net-delta
/// assertion is sidestepped.
///
/// What this is NOT:
///   - NOT a fork of a production rebate-hook contract. The shape is
///     the minimal "nested take, optional settle" loop the bug class
///     requires.
///   - NOT a runtime guard. The property in test/H3_FlashAccounting.t.sol
///     is a pre-deploy stateful invariant test.
contract FlashHook is IHooks {
    MockPoolManager public immutable manager;

    /// Bonus magnitude paid out to the user on the rebate path.
    uint256 public constant BONUS = 7;

    event BonusPaid(address indexed recipient, uint256 amount);

    constructor(MockPoolManager _manager) {
        require(address(_manager) != address(0), "FlashHook: zero manager");
        manager = _manager;
    }

    function beforeSwap(address sender, IHooks.PoolKey calldata, IHooks.SwapParams calldata, bytes calldata hookData)
        external
    {
        if (hookData.length >= 1 && hookData[0] == 0xBB) {
            // Pay sender BONUS from the manager. This debits this
            // hook (msg.sender of the take call) in the manager's
            // delta ledger by BONUS.
            manager.take(sender, BONUS);

            // PLANTED: the matching `manager.settle(BONUS)` call is
            // removed. The hook's debit is never offset; end-of-unlock
            // net delta is -BONUS for this hook, the manager reverts
            // with DeltaNotZero(-BONUS), and the unlock cannot
            // complete.

            emit BonusPaid(sender, BONUS);
        }
    }

    function afterSwap(address, IHooks.PoolKey calldata, IHooks.SwapParams calldata, uint256, uint256, bytes calldata)
        external
        pure {
        // No-op on this hook.
    }
}
