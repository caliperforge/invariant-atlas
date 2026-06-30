// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

// Atlas v4-hooks H3 - flash-accounting integrity under nested hook calls.
//
// This test file is BYTE-IDENTICAL between v4-hooks/clean/ and
// v4-hooks/planted/. Only src/FlashHook.sol differs between the two
// twins; the property surface is the same.
//
// Property asserted:
//
//   H3. flash_accounting_holds_under_nested_hook_calls (counter).
//        For every reachable state,
//          handler.flashViolations() == 0
//      The handler tries every swap through Router.executeSwap and
//      catches reverts. On the clean twin, the hook's nested take is
//      paired with a matching settle; the unlock's end-of-callback
//      net-delta check holds; no revert; flashViolations stays zero.
//      On the planted twin, the hook's nested take has no matching
//      settle; the net delta is -BONUS; MockPoolManager reverts with
//      DeltaNotZero; handler increments flashViolations -> divergence.
//
// AI-proposed invariant surface (Solidity Specialist agent against the
// load-bearing audit-finding category "hook makes nested PoolManager
// calls inside a callback without settling its own delta").

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IHooks, IUnlockCallback} from "../src/IHooks.sol";
import {MockPoolManager} from "../src/MockPoolManager.sol";
import {FlashHook} from "../src/FlashHook.sol";

// -------------------- Router --------------------
contract Router is IUnlockCallback {
    MockPoolManager public immutable manager;

    IHooks.PoolKey internal _key;
    IHooks.SwapParams internal _params;
    bytes internal _hookData;

    constructor(MockPoolManager _m) {
        manager = _m;
    }

    function executeSwap(IHooks.PoolKey calldata key, IHooks.SwapParams calldata params, bytes calldata hookData)
        external
    {
        _key = key;
        _params = params;
        _hookData = hookData;
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager), "Router: not manager");
        (uint256 amountIn, uint256 amountOut) = manager.swap(_key, _params, _hookData);
        manager.settle(amountIn - amountOut);
        return "";
    }
}

// -------------------- Handler --------------------
contract Handler is Test {
    MockPoolManager public immutable manager;
    FlashHook public immutable hook;
    Router public immutable router;

    address[4] internal _actors;

    /// Counter of unlock attempts that reverted with the MockPoolManager
    /// flash-accounting check. Clean: stays zero. Planted: grows once
    /// per fuzz call that triggered the bonus path with hookData[0]==0xBB.
    uint256 public flashViolations;

    address public lastSender;
    bool public lastSuccess;
    int256 public lastNetDeltaSnapshot;

    constructor(MockPoolManager _m, FlashHook _h, Router _r, address[4] memory actorsIn) {
        manager = _m;
        hook = _h;
        router = _r;
        _actors = actorsIn;
    }

    function actor(uint256 i) external view returns (address) {
        return _actors[i];
    }

    function _actor(uint8 idx) internal view returns (address) {
        return _actors[idx % 4];
    }

    function swap(uint8 senderIdx, uint96 amount) public {
        address sender = _actor(senderIdx);
        uint256 bounded = (uint256(amount) % 1_000_000_000) + 1_000;

        IHooks.PoolKey memory key =
            IHooks.PoolKey({currency0: address(0xC0), currency1: address(0xC1), fee: 3000, hooks: address(hook)});
        IHooks.SwapParams memory params = IHooks.SwapParams({zeroForOne: true, amountSpecified: int256(bounded)});
        // Always trigger the bonus path so the bug class is exercised
        // every fuzz step. The fuzzer rotates actors; the bonus path
        // is consistent.
        bytes memory hookData = bytes(hex"BB");

        lastSender = sender;

        vm.prank(sender);
        try router.executeSwap(key, params, hookData) {
            lastSuccess = true;
            lastNetDeltaSnapshot = manager.lastNetDelta();
        } catch {
            lastSuccess = false;
            flashViolations += 1;
        }
    }
}

// -------------------- Invariant test --------------------

contract H3Test is StdInvariant, Test {
    MockPoolManager internal manager;
    FlashHook internal hook;
    Router internal router;
    Handler internal handler;

    address internal constant ACTOR_A = address(0xA1);
    address internal constant ACTOR_B = address(0xA2);
    address internal constant ACTOR_C = address(0xA3);
    address internal constant ACTOR_D = address(0xA4);

    function setUp() public {
        manager = new MockPoolManager();
        hook = new FlashHook(manager);
        router = new Router(manager);

        address[4] memory actorList = [ACTOR_A, ACTOR_B, ACTOR_C, ACTOR_D];
        handler = new Handler(manager, hook, router, actorList);

        targetContract(address(handler));
    }

    // ------------------------------------------------------------------
    // H3 - flash_accounting_holds_under_nested_hook_calls (counter).
    //
    // After every handler step:
    //   handler.flashViolations() == 0
    //
    // Clean: hook self-balances its nested take with a matching settle;
    // every unlock succeeds; the counter stays zero.
    // Planted: hook's nested take has no matching settle; every unlock
    // reverts with DeltaNotZero(-BONUS); the counter grows.
    // ------------------------------------------------------------------
    function invariant_H3_flash_accounting_holds_under_nested_hook_calls() public view {
        require(handler.flashViolations() == 0, "INVARIANT VIOLATED H3_flash_accounting_nested_hook_call");
    }

    // ------------------------------------------------------------------
    // Deterministic attack-sequence test.
    //
    // ACTOR_A executes a single swap with hookData = 0xBB to trigger
    // the bonus rebate path.
    //
    // CLEAN: hook pairs take with settle; unlock succeeds;
    // manager.lastNetDelta() = 0 -> assertion holds.
    // PLANTED: hook takes without settling; manager reverts with
    // DeltaNotZero(-7); router.executeSwap propagates the revert;
    // the .call returns false -> assertion fires the marker.
    // ------------------------------------------------------------------
    function test_attack_H3_flash_accounting_nested_hook_call() public {
        IHooks.PoolKey memory key =
            IHooks.PoolKey({currency0: address(0xC0), currency1: address(0xC1), fee: 3000, hooks: address(hook)});
        IHooks.SwapParams memory params = IHooks.SwapParams({zeroForOne: true, amountSpecified: int256(10_000)});
        bytes memory hookData = bytes(hex"BB");

        vm.prank(ACTOR_A);
        (bool ok,) = address(router).call(abi.encodeWithSelector(Router.executeSwap.selector, key, params, hookData));
        emit log_named_uint("swap_unlock_ok", ok ? 1 : 0);

        // CLEAN: ok = true; manager.lastNetDelta() = 0; assertion holds.
        // PLANTED: ok = false; assertion fires.
        require(ok, "INVARIANT VIOLATED H3_flash_accounting_nested_hook_call");
    }

    // ------------------------------------------------------------------
    // Unit tests
    // ------------------------------------------------------------------

    function test_unit_no_bonus_path_holds_on_both_legs() public {
        // When hookData does NOT trigger the bonus path, the hook's
        // beforeSwap is a no-op. Both legs hold trivially.
        IHooks.PoolKey memory key =
            IHooks.PoolKey({currency0: address(0xC0), currency1: address(0xC1), fee: 3000, hooks: address(hook)});
        IHooks.SwapParams memory params = IHooks.SwapParams({zeroForOne: true, amountSpecified: int256(10_000)});
        bytes memory hookData = bytes(hex"00");

        vm.prank(ACTOR_A);
        router.executeSwap(key, params, hookData);
        assertEq(manager.lastNetDelta(), 0, "net delta zero on no-bonus");
    }
}
