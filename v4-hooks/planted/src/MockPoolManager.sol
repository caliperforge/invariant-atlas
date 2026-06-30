// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IHooks, IUnlockCallback} from "./IHooks.sol";

/// @title MockPoolManager (minimal v4-style PoolManager stand-in)
///
/// Byte-identical between v4-hooks/clean/ and v4-hooks/planted/. The
/// minimal subset of the Uniswap v4 PoolManager surface needed to
/// exercise the three planted-twin bug classes:
///
///   1. Forwards beforeSwap/afterSwap callbacks to the hook attached to
///      a PoolKey. Bug class H1 (hookData tampering) and H2 (fee
///      evasion) ride on these callbacks.
///   2. Implements the flash-accounting `unlock` flow: a single caller
///      enters `unlock(data)`, which calls back into the caller via
///      `unlockCallback`, during which the caller can call `swap()` and
///      adjust deltas via `take()` and `settle()`. At end of unlock the
///      manager asserts the net delta across all tracked actors sums
///      to zero. Bug class H3 (flash-accounting integrity under nested
///      hook calls) rides on this assertion.
///
/// What this is NOT:
///   - NOT a fork of Uniswap v4 PoolManager. The real manager handles
///     concentrated-liquidity ticks, fee math, currency reserves, and a
///     transient-storage delta map. This mock compresses to the surface
///     the property tests need.
///   - NOT a runtime guard. The flash-accounting net-zero assertion in
///     this mock IS the runtime check the real PoolManager does. We are
///     replicating it so the planted hook can be observed to violate it.
contract MockPoolManager {
    // Per-actor signed delta during the active unlock. Positive means
    // the actor is owed by the manager (credit). Negative means the
    // actor owes the manager (debit). End-of-unlock invariant: sum
    // across all tracked actors == 0.
    mapping(address => int256) public deltaOf;

    // Actors that ever held a non-zero delta during the active unlock.
    // Cleared at end of unlock.
    address[] internal _trackedActors;
    mapping(address => bool) internal _trackedActorSeen;

    bool public unlocked;
    address public activeCaller;

    // Last computed net delta from the most recent unlock. Exposed for
    // the property tests so they can read it after the unlockCallback
    // returns (the on-chain assertion in `unlock` reverts the whole tx
    // if net != 0; the test contract catches the revert and inspects
    // this value).
    int256 public lastNetDelta;

    event Unlocked(address indexed caller);
    event Swapped(address indexed sender, address indexed hook, uint256 amountIn, uint256 amountOut);
    event Settled(address indexed actor, int256 newDelta);

    error NotUnlocked();
    error AlreadyUnlocked();
    error DeltaNotZero(int256 net);

    modifier onlyUnlocked() {
        if (!unlocked) revert NotUnlocked();
        _;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        if (unlocked) revert AlreadyUnlocked();
        unlocked = true;
        activeCaller = msg.sender;
        emit Unlocked(msg.sender);

        bytes memory ret = IUnlockCallback(msg.sender).unlockCallback(data);

        int256 net = 0;
        uint256 len = _trackedActors.length;
        for (uint256 i = 0; i < len; i++) {
            net += deltaOf[_trackedActors[i]];
        }
        lastNetDelta = net;

        // Clear delta and tracking before exit so subsequent unlocks
        // start from a clean slate. The check fires AFTER the read so
        // the test contract can inspect `lastNetDelta` on the revert
        // path via a cheatcode-driven try/catch.
        for (uint256 i = 0; i < len; i++) {
            delete deltaOf[_trackedActors[i]];
            delete _trackedActorSeen[_trackedActors[i]];
        }
        delete _trackedActors;
        unlocked = false;
        activeCaller = address(0);

        if (net != 0) revert DeltaNotZero(net);
        return ret;
    }

    /// @dev `swap` enters the hook's beforeSwap, applies the swap's
    /// gross deltas to the caller (out is a credit, in is a debit), and
    /// then enters afterSwap. The caller is the actor whose delta moves
    /// (i.e., the swap-routing contract running inside unlockCallback).
    function swap(IHooks.PoolKey calldata key, IHooks.SwapParams calldata params, bytes calldata hookData)
        external
        onlyUnlocked
        returns (uint256 amountIn, uint256 amountOut)
    {
        // The swap path is a fixed-rate exchange for this mock: amountIn
        // is |amountSpecified|; amountOut is 99.5% of amountIn. The fee
        // bps the hook may charge is layered on top by H2; this mock's
        // 50bps spread plays the role of the AMM's swap fee.
        require(params.amountSpecified > 0, "MockPoolManager: amount");
        amountIn = uint256(params.amountSpecified);
        amountOut = (amountIn * 9950) / 10000;

        if (key.hooks != address(0)) {
            IHooks(key.hooks).beforeSwap(msg.sender, key, params, hookData);
        }

        _track(msg.sender);
        // The swap settles gross: caller owes amountIn, is owed amountOut.
        deltaOf[msg.sender] -= int256(amountIn);
        deltaOf[msg.sender] += int256(amountOut);

        if (key.hooks != address(0)) {
            IHooks(key.hooks).afterSwap(msg.sender, key, params, amountIn, amountOut, hookData);
        }

        emit Swapped(msg.sender, key.hooks, amountIn, amountOut);
    }

    /// @dev Settle a delta by paying ETH-units worth into the manager
    /// (credits caller by `amount`). The mock collapses currency
    /// accounting to a single signed scalar; real v4 has per-currency
    /// deltas. Both legs use this same surface.
    function settle(uint256 amount) external onlyUnlocked {
        _track(msg.sender);
        deltaOf[msg.sender] += int256(amount);
        emit Settled(msg.sender, deltaOf[msg.sender]);
    }

    /// @dev Take `amount` worth out (debits caller by `amount`). The
    /// flash-accounting class H3 fires when a nested hook call invokes
    /// `take` on the hook's own behalf and forgets to record the
    /// matching debit.
    function take(address recipient, uint256 amount) external onlyUnlocked {
        _track(msg.sender);
        deltaOf[msg.sender] -= int256(amount);
        emit Settled(msg.sender, deltaOf[msg.sender]);
        // The recipient is conceptual: this mock does not transfer ERC20.
        // The accounting is the load-bearing piece.
        (recipient); // silence unused-param warning while keeping the signature
    }

    function _track(address actor) internal {
        if (!_trackedActorSeen[actor]) {
            _trackedActorSeen[actor] = true;
            _trackedActors.push(actor);
        }
    }

    function trackedActorCount() external view returns (uint256) {
        return _trackedActors.length;
    }

    function trackedActor(uint256 i) external view returns (address) {
        return _trackedActors[i];
    }
}
