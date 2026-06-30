// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IHooks} from "./IHooks.sol";

/// @title RewardsHook (H1 PLANTED twin) - hookData identity binding.
///
/// Hook mints reward tokens to a recipient address encoded in the
/// caller-supplied `hookData` on every swap. The bug class lives in
/// whether the hook binds that decoded recipient to the swap caller
/// (the `sender` argument the pool manager forwards: msg.sender of the
/// `swap` call, which in production v4 is a router contract) or trusts
/// the hookData blob as an authenticated identity claim.
///
/// CLEAN: requires `address(bytes20(hookData[0:20])) == sender`. The
/// hook will only credit rewards to the router contract that initiated
/// the swap. Off-chain authorization (e.g., the Universal Router's
/// permit/sig flow) determines whose EOA the router pays out to; the
/// hook only trusts a router's own identity claim of itself.
///
/// PLANTED (see ../../../planted/src/RewardsHook.sol): omits the
/// binding. Any router can paste an arbitrary recipient address into
/// hookData and divert rewards to a router that did not initiate the
/// swap.
///
/// Audit-finding category: "Hook treats caller-supplied hookData as an
/// authenticated identity claim." Documented across multiple v4-hook
/// audit reports as a recurring shape; OpenZeppelin's and Spearbit's
/// public v4-hook audit corpus flags this repeatedly.
///
/// What this is NOT:
///   - NOT a fork of a production v4 rewards-hook contract. The shape
///     is the minimal "decode recipient from hookData, mint rewards"
///     loop the bug class requires.
///   - NOT a runtime guard. The property in test/H1_HookDataIntegrity.t.sol
///     is a pre-deploy stateful invariant test.
contract RewardsHook is IHooks {
    /// Reward balance accrued to each address via this hook.
    mapping(address => uint256) public rewardsTo;

    /// Fixed reward per swap. The bug-class signal does not depend on
    /// the magnitude; one unit per swap keeps the ledger easy to read.
    uint256 public constant REWARD_PER_SWAP = 1;

    event RewardsMinted(address indexed sender, address indexed recipient, uint256 amount);

    error HookDataTooShort();
    error RecipientNotSender();

    function beforeSwap(address, IHooks.PoolKey calldata, IHooks.SwapParams calldata, bytes calldata) external pure {
        // No-op on this hook. The reward logic lives in afterSwap so the
        // swap path settles before the credit is applied.
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
        // hook trusts hookData as an authenticated identity claim; any
        // router can paste any recipient address into hookData.
        (sender);

        rewardsTo[recipient] += REWARD_PER_SWAP;
        emit RewardsMinted(sender, recipient, REWARD_PER_SWAP);
    }
}
