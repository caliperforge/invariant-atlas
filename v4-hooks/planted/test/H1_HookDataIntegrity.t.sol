// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

// Atlas v4-hooks H1 - hookData identity-binding invariant.
//
// This test file is BYTE-IDENTICAL between v4-hooks/clean/ and
// v4-hooks/planted/. Only src/RewardsHook.sol differs between the two
// twins; the property surface is the same.
//
// Property asserted:
//
//   H1. rewards_match_swap_initiator (global state).
//        For every tracked router R,
//          hook.rewardsTo(R) == handler.swapsByRouter(R)
//      The clean twin enforces the binding `recipient == sender` inside
//      afterSwap, so the only path to extending rewardsTo[R] is for R
//      itself to call swap with hookData encoding R.
//      The planted twin omits the binding; a swap initiated by router
//      X with hookData encoding router Y credits Y's reward ledger but
//      extends the handler's swapsByRouter[X] counter, not
//      swapsByRouter[Y] -> divergence.
//
// AI-proposed invariant surface (Solidity Specialist agent against the
// load-bearing audit-finding category "hook treats caller-supplied
// hookData as authenticated identity claim").

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IHooks, IUnlockCallback} from "../src/IHooks.sol";
import {MockPoolManager} from "../src/MockPoolManager.sol";
import {RewardsHook} from "../src/RewardsHook.sol";

// -------------------- HookRouter --------------------
//
// Minimal contract that implements IUnlockCallback so swaps can run
// inside MockPoolManager.unlock(). Each Atlas test deploys a fleet of
// these so the property tests can distinguish "who called swap" at the
// hook callback. In production v4 this is the role the Universal
// Router plays.
contract HookRouter is IUnlockCallback {
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
        // Router owes (amountIn - amountOut) net. Settle to zero out.
        manager.settle(amountIn - amountOut);
        return "";
    }
}

// -------------------- Handler --------------------
//
// Foundry's stateful invariant runner calls into the handler with
// fuzzed (swapperIdx, recipientIdx, amount). The handler picks two
// routers from a fixed fleet, builds the swap with hookData encoding
// the chosen recipient router, and runs swapperRouter.executeSwap.
contract Handler is Test {
    MockPoolManager public immutable manager;
    RewardsHook public immutable hook;

    address[4] internal _routers;

    // Test-side ledger. swapsByRouter[R] extends each time router R
    // successfully calls swap. The clean twin keeps this in lockstep
    // with hook.rewardsTo(R); the planted twin lets them diverge
    // whenever the hookData recipient encoded into the swap is some
    // OTHER router.
    mapping(address => uint256) public swapsByRouter;

    // Set-but-unread fields below seed Foundry's invariant-fuzzer storage dictionary.
    address public lastSwapper;
    address public lastRecipient;
    bool public lastSuccess;

    constructor(MockPoolManager _m, RewardsHook _h, address[4] memory routersIn) {
        manager = _m;
        hook = _h;
        _routers = routersIn;
    }

    function router(uint256 i) external view returns (address) {
        return _routers[i];
    }

    function _router(uint8 idx) internal view returns (address) {
        return _routers[idx % 4];
    }

    function swap(uint8 swapperIdx, uint8 recipientIdx, uint96 amount) public {
        address swapperAddr = _router(swapperIdx);
        address recipientAddr = _router(recipientIdx);
        uint256 bounded = (uint256(amount) % 1_000_000_000) + 1;

        IHooks.PoolKey memory key =
            IHooks.PoolKey({currency0: address(0xC0), currency1: address(0xC1), fee: 3000, hooks: address(hook)});
        IHooks.SwapParams memory params = IHooks.SwapParams({zeroForOne: true, amountSpecified: int256(bounded)});
        bytes memory hookData = abi.encodePacked(bytes20(uint160(recipientAddr)));

        lastSwapper = swapperAddr;
        lastRecipient = recipientAddr;

        try HookRouter(swapperAddr).executeSwap(key, params, hookData) {
            lastSuccess = true;
            // Handler extends its ledger keyed by the swap caller (the
            // router that actually invoked swap), regardless of what
            // hookData claimed as recipient. The hook's own rewardsTo
            // extends by the recipient encoded in hookData. Clean:
            // bound equal. Planted: can diverge.
            swapsByRouter[swapperAddr] += 1;
        } catch {
            lastSuccess = false;
        }
    }
}

// -------------------- Invariant test --------------------

contract H1Test is StdInvariant, Test {
    MockPoolManager internal manager;
    RewardsHook internal hook;
    HookRouter internal router0;
    HookRouter internal router1;
    HookRouter internal router2;
    HookRouter internal router3;
    Handler internal handler;

    function setUp() public {
        manager = new MockPoolManager();
        hook = new RewardsHook();
        router0 = new HookRouter(manager);
        router1 = new HookRouter(manager);
        router2 = new HookRouter(manager);
        router3 = new HookRouter(manager);

        address[4] memory routerList = [address(router0), address(router1), address(router2), address(router3)];
        handler = new Handler(manager, hook, routerList);

        targetContract(address(handler));
    }

    // ------------------------------------------------------------------
    // H1 - rewards_match_swap_initiator (global state).
    //
    // For every tracked router R:
    //   hook.rewardsTo(R) == handler.swapsByRouter(R)
    //
    // Clean: the hook's `recipient == sender` binding ensures rewardsTo
    // only ever extends in lockstep with handler.swapsByRouter for that
    // same R.
    // Planted: a router X initiating a swap with hookData encoding
    // recipient Y extends rewardsTo[Y] but not handler.swapsByRouter[Y]
    // (the handler keys on the swap caller, X). The two ledgers
    // diverge -> marker fires.
    // ------------------------------------------------------------------
    function invariant_H1_rewards_match_swap_initiator() public view {
        for (uint256 i = 0; i < 4; i++) {
            address r = handler.router(i);
            require(hook.rewardsTo(r) == handler.swapsByRouter(r), "INVARIANT VIOLATED H1_hookdata_identity_binding");
        }
    }

    // ------------------------------------------------------------------
    // Deterministic attack-sequence test.
    //
    // Scripts the canonical hookData-tampering attack end-to-end so the
    // planted twin fires deterministically even if the fuzzer's random
    // walk does not hit the swapper != recipient path within its run
    // budget.
    //
    // CLEAN: router0 calls swap with hookData encoding router1. The
    // hook reverts on `recipient != sender`; rewards never move.
    // PLANTED: the swap succeeds; rewards are credited to router1
    // though router0 initiated. The assertion fires the marker.
    // ------------------------------------------------------------------
    function test_attack_H1_hookdata_tampering() public {
        IHooks.PoolKey memory key =
            IHooks.PoolKey({currency0: address(0xC0), currency1: address(0xC1), fee: 3000, hooks: address(hook)});
        IHooks.SwapParams memory params = IHooks.SwapParams({zeroForOne: true, amountSpecified: int256(1000)});
        // Attacker router0 initiates the swap but pastes router1's
        // address into hookData, attempting to divert the reward to
        // router1.
        bytes memory hookData = abi.encodePacked(bytes20(uint160(address(router1))));

        (bool ok,) =
            address(router0).call(abi.encodeWithSelector(HookRouter.executeSwap.selector, key, params, hookData));
        emit log_named_uint("attacker_swap_ok", ok ? 1 : 0);

        // CLEAN: ok = false (reverted on recipient != sender);
        // hook.rewardsTo(router1) = 0 -> assertion holds.
        // PLANTED: ok = true; hook.rewardsTo(router1) = 1 -> fires.
        require(!ok || hook.rewardsTo(address(router1)) == 0, "INVARIANT VIOLATED H1_hookdata_identity_binding");
    }

    // ------------------------------------------------------------------
    // Unit tests
    // ------------------------------------------------------------------

    function test_unit_self_swap_credits_self() public {
        // Legitimate flow: router0 swaps with hookData encoding
        // router0. Holds on both clean and planted (the bug class is
        // the absence of the binding, not its presence).
        IHooks.PoolKey memory key =
            IHooks.PoolKey({currency0: address(0xC0), currency1: address(0xC1), fee: 3000, hooks: address(hook)});
        IHooks.SwapParams memory params = IHooks.SwapParams({zeroForOne: true, amountSpecified: int256(1000)});
        bytes memory hookData = abi.encodePacked(bytes20(uint160(address(router0))));

        router0.executeSwap(key, params, hookData);
        assertEq(hook.rewardsTo(address(router0)), 1, "self-credit");
    }
}
