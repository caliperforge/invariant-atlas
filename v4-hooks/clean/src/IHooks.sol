// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @title IHooks (minimal v4-style hook interface)
///
/// Minimal stand-in for Uniswap v4's IHooks surface. The Atlas does NOT
/// vendor Uniswap v4 source. Hook callbacks are reduced to the two
/// entry-points that carry the three planted bug classes (beforeSwap +
/// afterSwap). PoolKey, SwapParams, and BalanceDelta are reduced to the
/// minimum field set needed by the property surface.
///
/// Byte-identical between v4-hooks/clean/ and v4-hooks/planted/.
interface IHooks {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        address hooks;
    }

    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
    }

    /// @dev Called by the pool manager before the swap is executed.
    /// `sender` is the address that invoked `PoolManager.swap()`
    /// (typically a router or a contract acting in `unlock`). `hookData`
    /// is the caller-supplied opaque bytes blob passed through the swap
    /// entry-point. The hook MUST treat `hookData` as untrusted unless
    /// it binds it to `sender` or to a signed attestation.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external;

    /// @dev Called by the pool manager after the swap is executed.
    /// Same trust model as beforeSwap. `amountIn` and `amountOut` are
    /// the absolute magnitudes the pool manager observed.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        uint256 amountIn,
        uint256 amountOut,
        bytes calldata hookData
    ) external;
}

/// @title IUnlockCallback (minimal v4-style unlock callback)
interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}
