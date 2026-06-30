// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

// Atlas v4-hooks H2 - before/afterSwap fee-evasion invariant.
//
// This test file is BYTE-IDENTICAL between v4-hooks/clean/ and
// v4-hooks/planted/. Only src/FeeSwitchHook.sol differs between the two
// twins; the property surface is the same.
//
// Property asserted:
//
//   H2. fees_match_expected_accrual (global state).
//        For every reachable state,
//          hook.accruedFees() == handler.expectedFees()
//      handler.expectedFees extends ONLY against the admin-controlled
//      exempt set keyed by the swap caller (router): if
//      isExempt[router] then 0, else amountIn * FEE_BPS / 10000. The
//      clean twin keeps the hook's accruedFees in lockstep with this.
//      The planted twin's caller-controlled hookData waiver lets
//      non-exempt routers evade the fee; accruedFees no longer tracks
//      expectedFees -> divergence.
//
// AI-proposed invariant surface (Solidity Specialist agent against the
// load-bearing audit-finding category "hook honors caller-supplied fee
// waiver without authentication").

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IHooks, IUnlockCallback} from "../src/IHooks.sol";
import {MockPoolManager} from "../src/MockPoolManager.sol";
import {FeeSwitchHook} from "../src/FeeSwitchHook.sol";

// -------------------- HookRouter --------------------
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
        manager.settle(amountIn - amountOut);
        return "";
    }
}

// -------------------- Handler --------------------
contract Handler is Test {
    MockPoolManager public immutable manager;
    FeeSwitchHook public immutable hook;

    address[4] internal _routers;

    // Test-side expected-fee ledger. Extended on every successful swap
    // by the SAME formula the clean twin uses (admin-exempt by router
    // address only).
    uint256 public expectedFees;

    address public lastRouter;
    uint256 public lastAmountIn;
    bool public lastWaiveAttempt;
    bool public lastSuccess;

    constructor(MockPoolManager _m, FeeSwitchHook _h, address[4] memory routersIn) {
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

    function swap(uint8 routerIdx, uint8 waiveFlag, uint96 amount) public {
        address routerAddr = _router(routerIdx);
        bool waive = (waiveFlag % 2) == 1;
        // Bound amountIn so amount * FEE_BPS fits cleanly.
        uint256 bounded = (uint256(amount) % 1_000_000_000) + 10_000;

        IHooks.PoolKey memory key =
            IHooks.PoolKey({currency0: address(0xC0), currency1: address(0xC1), fee: 3000, hooks: address(hook)});
        IHooks.SwapParams memory params = IHooks.SwapParams({zeroForOne: true, amountSpecified: int256(bounded)});
        // hookData is one byte: 0x01 = attempt waiver, 0x00 = no claim.
        bytes memory hookData = waive ? bytes(hex"01") : bytes(hex"00");

        lastRouter = routerAddr;
        lastAmountIn = bounded;
        lastWaiveAttempt = waive;

        try HookRouter(routerAddr).executeSwap(key, params, hookData) {
            lastSuccess = true;
            // Handler extends expectedFees by the SAME rule the clean
            // twin uses: admin-exempt routers pay zero; everyone else
            // pays amountIn * FEE_BPS / 10000. hookData is ignored
            // for this ledger -> on the planted twin, when a non-exempt
            // router passes the waiver flag and the hook accrues zero,
            // the handler still extends expectedFees -> divergence.
            if (!hook.isExempt(routerAddr)) {
                expectedFees += (bounded * hook.FEE_BPS()) / 10000;
            }
        } catch {
            lastSuccess = false;
        }
    }
}

// -------------------- Invariant test --------------------

contract H2Test is StdInvariant, Test {
    MockPoolManager internal manager;
    FeeSwitchHook internal hook;
    HookRouter internal exemptRouter;
    HookRouter internal routerA;
    HookRouter internal routerB;
    HookRouter internal routerC;
    Handler internal handler;

    address internal constant ADMIN = address(0xAD);

    function setUp() public {
        manager = new MockPoolManager();
        hook = new FeeSwitchHook(ADMIN);

        exemptRouter = new HookRouter(manager);
        routerA = new HookRouter(manager);
        routerB = new HookRouter(manager);
        routerC = new HookRouter(manager);

        // Admin grants exemption to one router only.
        vm.prank(ADMIN);
        hook.setExempt(address(exemptRouter), true);

        address[4] memory routerList = [address(exemptRouter), address(routerA), address(routerB), address(routerC)];
        handler = new Handler(manager, hook, routerList);

        targetContract(address(handler));
    }

    // ------------------------------------------------------------------
    // H2 - fees_match_expected_accrual (global state).
    //
    // After every handler step:
    //   hook.accruedFees() == handler.expectedFees()
    //
    // Clean: hookData is not consulted for the waiver; the hook's
    // accruedFees moves identically to the handler's expectedFees.
    // Planted: a non-exempt router passing the waiver byte in hookData
    // bypasses the fee accrual; expectedFees still extends -> divergence.
    // ------------------------------------------------------------------
    function invariant_H2_fees_match_expected_accrual() public view {
        require(hook.accruedFees() == handler.expectedFees(), "INVARIANT VIOLATED H2_fee_evasion_via_hookdata_waiver");
    }

    // ------------------------------------------------------------------
    // Deterministic attack-sequence test.
    //
    // routerA is NOT in the admin's exempt set. It pastes 0x01 into
    // hookData and executes a swap of 1,000,000 input units.
    //
    // CLEAN: hookData is ignored for the fee decision. routerA is not
    // exempt; the hook accrues 1,000,000 * 30 / 10,000 = 3,000 fee.
    // hook.accruedFees == 3000 -> assertion holds.
    // PLANTED: hookData[0] == 0x01 short-circuits the accrual. The hook
    // accrues zero. hook.accruedFees == 0 -> assertion fires the marker.
    // ------------------------------------------------------------------
    function test_attack_H2_fee_evasion() public {
        IHooks.PoolKey memory key =
            IHooks.PoolKey({currency0: address(0xC0), currency1: address(0xC1), fee: 3000, hooks: address(hook)});
        IHooks.SwapParams memory params = IHooks.SwapParams({zeroForOne: true, amountSpecified: int256(1_000_000)});
        bytes memory hookData = bytes(hex"01");

        routerA.executeSwap(key, params, hookData);

        uint256 expected = (1_000_000 * hook.FEE_BPS()) / 10000;
        emit log_named_uint("expected_fee", expected);
        emit log_named_uint("accrued_fee", hook.accruedFees());

        require(hook.accruedFees() == expected, "INVARIANT VIOLATED H2_fee_evasion_via_hookdata_waiver");
    }

    // ------------------------------------------------------------------
    // Unit tests
    // ------------------------------------------------------------------

    function test_unit_exempt_router_pays_zero() public {
        // The exempt router pays zero on either twin (the admin set IS
        // honored on both legs; the planted twin adds an extra evasion
        // path on top, not in place of, the admin exempt set).
        IHooks.PoolKey memory key =
            IHooks.PoolKey({currency0: address(0xC0), currency1: address(0xC1), fee: 3000, hooks: address(hook)});
        IHooks.SwapParams memory params = IHooks.SwapParams({zeroForOne: true, amountSpecified: int256(1_000_000)});
        exemptRouter.executeSwap(key, params, bytes(hex"00"));
        assertEq(hook.accruedFees(), 0, "exempt router pays zero");
    }
}
