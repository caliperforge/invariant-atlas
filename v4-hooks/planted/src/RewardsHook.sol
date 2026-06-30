// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IHooks} from "./IHooks.sol";

/// @title RewardsHook (H1 PLANTED twin) - hookData identity binding.
///
/// Same-source twin of ../../../clean/src/RewardsHook.sol with the
/// `recipient == sender` binding removed. The hook blindly trusts the
/// caller-supplied hookData as a recipient identity claim. Any caller
/// can paste an arbitrary recipient address and divert rewards.
///
/// A `diff` against ../../../clean/src/RewardsHook.sol shows the planted
/// hunk as a single localized change: the `if (recipient != sender)
/// revert RecipientNotSender();` line is removed. Every other line in
/// this file matches the clean twin (modulo the CLEAN/PLANTED comment
/// markers).
contract RewardsHook is IHooks {
    /// Reward balance accrued to each address via this hook.
    mapping(address => uint256) public rewardsTo;

    /// Fixed reward per swap.
    uint256 public constant REWARD_PER_SWAP = 1;

    event RewardsMinted(address indexed sender, address indexed recipient, uint256 amount);

    error HookDataTooShort();
    error RecipientNotSender();

    function beforeSwap(address, IHooks.PoolKey calldata, IHooks.SwapParams calldata, bytes calldata) external pure {
        // No-op on this hook.
    }

    function afterSwap(
        address sender,
        IHooks.PoolKey calldata,
        IHooks.SwapParams calldata,
        uint256,
        uint256,
        bytes calldata hookData
    ) external {
        if (hookData.length < 20) revert HookDataTooShort();
        address recipient = address(bytes20(hookData[0:20]));

        // PLANTED: the `recipient == sender` binding is removed. The
        // hook trusts hookData as an authenticated identity claim.
        (sender);

        rewardsTo[recipient] += REWARD_PER_SWAP;
        emit RewardsMinted(sender, recipient, REWARD_PER_SWAP);
    }
}
