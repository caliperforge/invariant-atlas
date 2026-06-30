// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IHooks} from "./IHooks.sol";
import {MockPoolManager} from "./MockPoolManager.sol";

/// @title FlashHook (H3 PLANTED twin) - nested-call flash accounting.
///
/// Same-source twin of ../../../clean/src/FlashHook.sol with the
/// matching `manager.settle(BONUS)` call removed. The hook still pays
/// the user via `manager.take(sender, BONUS)`, but never settles its
/// own resulting debit. End-of-unlock net delta sums to `-BONUS`; the
/// pool manager reverts with `DeltaNotZero(-BONUS)` and the unlock
/// cannot complete.
///
/// A `diff` against ../../../clean/src/FlashHook.sol shows the planted
/// hunk as a single localized change: the `manager.settle(BONUS);`
/// line is removed.
contract FlashHook is IHooks {
    MockPoolManager public immutable manager;

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
            // Pay sender BONUS from the manager. This debits this hook
            // in the manager's delta ledger by BONUS.
            manager.take(sender, BONUS);

            // PLANTED: the matching `manager.settle(BONUS)` call is
            // removed. The hook's debit is never offset. End-of-unlock
            // net delta is -BONUS; the manager reverts.

            emit BonusPaid(sender, BONUS);
        }
    }

    function afterSwap(address, IHooks.PoolKey calldata, IHooks.SwapParams calldata, uint256, uint256, bytes calldata)
        external
        pure {
        // No-op.
    }
}
