// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IHooks} from "./IHooks.sol";

/// @title FeeSwitchHook (H2 PLANTED twin) - beforeSwap/afterSwap fee path.
///
/// Same-source twin of ../../../clean/src/FeeSwitchHook.sol with the
/// waiver decision rewired to a caller-controlled flag in hookData.
/// The admin's exempt mapping is still consulted as defense-in-depth,
/// but the hookData waiver bypasses it. Any caller can paste `0x01` as
/// the first byte of hookData and evade the fee.
///
/// A `diff` against ../../../clean/src/FeeSwitchHook.sol shows the
/// planted hunk localized to `afterSwap`: a `waive` variable is read
/// from `hookData[0]` and the fee accrual is short-circuited on it.
contract FeeSwitchHook is IHooks {
    address public immutable admin;
    mapping(address => bool) public isExempt;
    uint256 public accruedFees;
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
        // No-op.
    }

    function afterSwap(
        address sender,
        IHooks.PoolKey calldata,
        IHooks.SwapParams calldata,
        uint256 amountIn,
        uint256,
        bytes calldata hookData
    ) external {
        // PLANTED: the waiver decision consults a caller-controlled
        // flag in hookData. The admin's exempt mapping is still
        // checked, but EITHER condition short-circuits the fee
        // accrual, so any caller can paste 0x01 and pay zero.
        bool waive = hookData.length >= 1 && hookData[0] == 0x01;
        if (!isExempt[sender] && !waive) {
            uint256 fee = (amountIn * FEE_BPS) / 10000;
            accruedFees += fee;
            emit FeeAccrued(sender, amountIn, fee);
        }
    }
}
