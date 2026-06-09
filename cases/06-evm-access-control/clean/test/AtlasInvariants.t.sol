// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

// Atlas case 6 — EVM access-control class invariants (Trace2Inv bridge).
//
// This test file is BYTE-IDENTICAL between cases/06-evm-access-control/clean/
// and cases/06-evm-access-control/planted/. Only src/AccessControlledForge.sol
// differs between the two twins; the property surface is the same.
//
// Properties asserted (per Trace2Inv's access-control invariant class, arXiv:
// 2404.14580; the clean leg holds them, the planted leg fires within the
// 256-run x depth-50 invariant runner budget plus a deterministic
// attack-sequence test):
//
//   A. admin_only_migrate (per-call temporal).
//        For every state transition,
//          !lastMigrateSucceeded  OR  lastMigrateCaller == owner
//      The clean twin enforces this by requiring `onlyOwner` on
//      `migrate(_)`; non-owner migrate calls revert. The planted twin
//      omits the modifier, so a non-owner migrate succeeds with
//      lastMigrateCaller != owner → violates A.
//
//   B. strategy_in_approved_set (global state).
//        For every reachable state,
//          forge.yieldStrategy() in approvedStrategies
//      The handler seeds approvedStrategies with the constructor-set
//      initial strategy and extends it ONLY when a migrate(_) call
//      succeeds AND the caller was the owner. The clean twin's only-
//      owner gate keeps yieldStrategy in the approved set under all
//      reachable transitions. The planted twin's non-owner migrate
//      points yieldStrategy at an attacker-controlled address that is
//      NOT in approvedStrategies → violates B.
//
// AI-proposed invariant surface (Solidity Specialist agent, model
// claude-opus-4-6), reviewed and accepted by the case author. The
// invariant class (access-control on the privileged migrate / strategy-
// setter) is the load-bearing Trace2Inv-cataloged bug class — not a toy.
//
// Foundry note: the stateful invariant runner is driven by `Handler` (a
// small actor-rotating wrapper) registered via `targetContract`. The
// deterministic attack-sequence test `test_attack_punk_protocol_class`
// scripts the canonical drain end-to-end so the planted leg fires even
// if the fuzzer's random walk does not happen to hit the migrate-by-
// non-owner path within its run budget.

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AccessControlledForge} from "../src/AccessControlledForge.sol";

// -------------------- Handler --------------------
//
// Foundry's stateful invariant runner calls into one or more "target
// contracts" with fuzzed arguments. The Handler wraps the
// AccessControlledForge so the fuzzer's calls rotate across three
// actors (one of whom is the owner) and so the test-side bookkeeping
// (`approvedStrategies`, `lastMigrateCaller`, `lastMigrateSucceeded`)
// is populated for the property checks.
contract Handler is Test {
    AccessControlledForge public immutable forge;
    address public immutable OWNER;

    // Three actors. actors[0] is the OWNER; actors[1] and actors[2] are
    // non-owner. The fuzzer picks an actor index via the `actorIdx`
    // argument on each handler function.
    address[3] internal _actorList;

    // Test-side ledger for property B. Seeded with the constructor's
    // initial strategy; extended only when a migrate succeeds AND the
    // caller was the owner. (The Handler is the source of truth for
    // "what strategies are owner-approved" — the forge contract itself
    // does not track this.)
    mapping(address => bool) public approvedStrategies;

    // Test-side state for property A. The handler records who called
    // the most recent migrate and whether it succeeded; the property
    // checks the join.
    address public lastMigrateCaller;
    bool public lastMigrateSucceeded;
    address public lastMigrateNewStrategy;

    constructor(
        AccessControlledForge _forge,
        address _owner,
        address _initialStrategy,
        address[3] memory actorsIn
    ) {
        forge = _forge;
        OWNER = _owner;
        _actorList = actorsIn;
        // Seed property B's approved set with the constructor-blessed
        // initial strategy.
        approvedStrategies[_initialStrategy] = true;
    }

    function actors(uint256 i) external view returns (address) {
        return _actorList[i];
    }

    function _actor(uint8 idx) internal view returns (address) {
        return _actorList[idx % 3];
    }

    // ------------------------------------------------------------------
    // depositETH — any actor deposits a bounded ETH amount. Funds the
    // contract so the attacker has something to drain on the planted leg.
    // ------------------------------------------------------------------
    function depositETH(uint8 actorIdx, uint96 amount) public {
        address a = _actor(actorIdx);
        uint256 bounded = (uint256(amount) % 100 ether) + 1;
        vm.deal(a, bounded);
        vm.prank(a);
        forge.deposit{value: bounded}();
    }

    // ------------------------------------------------------------------
    // withdrawETH — bounded withdraw by an actor of their own deposit.
    // Safe-dispatched (try/catch) since the fuzzer may pick an actor
    // with no balance.
    // ------------------------------------------------------------------
    function withdrawETH(uint8 actorIdx, uint96 amount) public {
        address a = _actor(actorIdx);
        uint256 owned = forge.deposits(a);
        if (owned == 0) return;
        uint256 bounded = (uint256(amount) % owned) + 1;
        vm.prank(a);
        try forge.withdraw(bounded) {} catch {}
    }

    // ------------------------------------------------------------------
    // migrate — the privileged function under test. Updates the test-
    // side ledger BEFORE the external call so property A can compare
    // (caller, success) regardless of which leg is under test.
    //
    // On CLEAN: only the OWNER actor's migrate succeeds; non-owner
    // calls revert and `lastMigrateSucceeded = false` → property A
    // and B both hold.
    // On PLANTED: any actor's migrate succeeds. If the actor is OWNER
    // the new strategy is added to approvedStrategies (legitimate); if
    // the actor is non-owner, the new strategy is NOT added — property
    // B fires on the next invariant check, and property A's record
    // shows `lastMigrateCaller != OWNER && lastMigrateSucceeded` → A
    // also fires.
    // ------------------------------------------------------------------
    function migrate(uint8 actorIdx, address newStrategy) public {
        address a = _actor(actorIdx);
        lastMigrateCaller = a;
        lastMigrateNewStrategy = newStrategy;
        vm.prank(a);
        try forge.migrate(newStrategy) {
            lastMigrateSucceeded = true;
            if (a == OWNER) {
                // Owner-blessed: this strategy joins the approved set.
                approvedStrategies[newStrategy] = true;
            }
        } catch {
            lastMigrateSucceeded = false;
        }
    }

    // ------------------------------------------------------------------
    // strategyPullToOwner — the privileged outflow path, called from
    // whoever currently is the strategy. Bounded to the contract's
    // current balance. This is not under direct test by property A or
    // B; it is the post-bug drain vector that runs after a successful
    // attacker-migrate on the planted leg. Included in the fuzz so
    // the invariant runner exercises the full attack arc.
    // ------------------------------------------------------------------
    function strategyPullToOwner(uint96 amount) public {
        address currentStrategy = forge.yieldStrategy();
        uint256 bal = address(forge).balance;
        if (bal == 0) return;
        uint256 bounded = (uint256(amount) % bal) + 1;
        vm.prank(currentStrategy);
        try forge.strategyPull(OWNER, bounded) {} catch {}
    }
}

// -------------------- Invariant test contract --------------------

contract AtlasInvariantsTest is StdInvariant, Test {
    AccessControlledForge internal forge;
    Handler internal handler;

    address internal constant OWNER = address(0x4001);
    address internal constant INITIAL_STRATEGY = address(0x5001);
    address internal constant ATTACKER = address(0xA77ACC);
    address internal constant VICTIM = address(0xB1C1);
    address internal constant ACTOR_A = address(0xB1);
    address internal constant ACTOR_B = address(0xB2);

    function setUp() public {
        vm.prank(OWNER);
        forge = new AccessControlledForge(INITIAL_STRATEGY);

        address[3] memory actorList = [OWNER, ACTOR_A, ACTOR_B];
        handler = new Handler(forge, OWNER, INITIAL_STRATEGY, actorList);

        // Only the handler's functions are fuzzable. (forge's public
        // surface is exercised THROUGH the handler so the property's
        // test-side bookkeeping stays consistent with the on-chain
        // state.)
        targetContract(address(handler));
    }

    // ------------------------------------------------------------------
    // Property A — admin_only_migrate (per-call temporal)
    //
    // After every handler step, if the most recent migrate succeeded,
    // the caller MUST have been the owner. Vacuously holds when no
    // migrate has been attempted.
    // ------------------------------------------------------------------
    function invariant_admin_only_migrate() public view {
        require(
            !handler.lastMigrateSucceeded() || handler.lastMigrateCaller() == handler.OWNER(),
            "INVARIANT VIOLATED admin_only_migrate"
        );
    }

    // ------------------------------------------------------------------
    // Property B — strategy_in_approved_set (global state)
    //
    // After every handler step, the contract's current yieldStrategy
    // MUST be in the handler's approvedStrategies ledger (which is
    // extended ONLY when migrate succeeds AND caller was owner).
    // ------------------------------------------------------------------
    function invariant_strategy_in_approved_set() public view {
        require(
            handler.approvedStrategies(forge.yieldStrategy()),
            "INVARIANT VIOLATED strategy_in_approved_set"
        );
    }

    // ------------------------------------------------------------------
    // Deterministic attack-sequence test
    //
    // Scripts the canonical missing-access-control drain end-to-end so
    // the planted leg fires deterministically (not dependent on the
    // fuzzer's random walk hitting the migrate-by-non-owner path).
    //
    // CLEAN: step 2 reverts; step 3 reverts. Final assertion holds
    // because yieldStrategy is still INITIAL_STRATEGY → test passes.
    // PLANTED: step 2 succeeds; step 3 succeeds; final assertion fails
    // with `INVARIANT VIOLATED strategy_in_approved_set` → test fails.
    // ------------------------------------------------------------------
    function test_attack_punk_protocol_class() public {
        // Step 1: victim deposits 1 ether.
        vm.deal(VICTIM, 1 ether);
        vm.prank(VICTIM);
        forge.deposit{value: 1 ether}();
        assertEq(forge.totalDeposits(), 1 ether, "step1: deposit recorded");

        // Step 2: attacker calls migrate(attacker). CLEAN reverts on
        // "Forge: not owner"; PLANTED accepts.
        vm.prank(ATTACKER);
        (bool migrateOk, ) = address(forge).call(
            abi.encodeWithSelector(AccessControlledForge.migrate.selector, ATTACKER)
        );
        emit log_named_uint("attacker_migrate_ok", migrateOk ? 1 : 0);

        // Step 3: attacker calls strategyPull(attacker, 1 ether). CLEAN
        // reverts on "Forge: not strategy" (yieldStrategy is still
        // INITIAL_STRATEGY); PLANTED accepts and drains.
        vm.prank(ATTACKER);
        (bool pullOk, ) = address(forge).call(
            abi.encodeWithSelector(
                AccessControlledForge.strategyPull.selector,
                ATTACKER,
                uint256(1 ether)
            )
        );
        emit log_named_uint("attacker_strategy_pull_ok", pullOk ? 1 : 0);

        // Property check. CLEAN: yieldStrategy is still INITIAL_STRATEGY
        // → holds. PLANTED: yieldStrategy is ATTACKER (not in
        // approvedStrategies) → fires marker.
        require(
            forge.yieldStrategy() == INITIAL_STRATEGY,
            "INVARIANT VIOLATED strategy_in_approved_set"
        );
    }

    // ------------------------------------------------------------------
    // Unit tests — entrypoint coverage
    // ------------------------------------------------------------------

    function test_unit_constructor_state() public view {
        assertEq(forge.owner(), OWNER, "ctor: owner");
        assertEq(forge.yieldStrategy(), INITIAL_STRATEGY, "ctor: yieldStrategy");
        assertEq(forge.totalDeposits(), 0, "ctor: totalDeposits");
    }

    function test_unit_deposit_then_withdraw_legitimate() public {
        // Legitimate flow: a single user deposits 1 ether and then
        // withdraws their full balance. Holds on both clean and planted
        // — the bug class is access-control on migrate, not the user-
        // facing deposit / withdraw path.
        vm.deal(VICTIM, 1 ether);
        vm.startPrank(VICTIM);
        forge.deposit{value: 1 ether}();
        assertEq(forge.deposits(VICTIM), 1 ether, "deposit recorded");
        forge.withdraw(1 ether);
        assertEq(forge.deposits(VICTIM), 0, "withdraw recorded");
        vm.stopPrank();
        assertEq(VICTIM.balance, 1 ether, "round-trip returns");
    }

    function test_unit_owner_can_migrate() public {
        // Sanity: the owner CAN migrate on both clean and planted. The
        // clean leg's bug class is "non-owner cannot migrate"; this
        // unit confirms the owner's legitimate path still works.
        address newStrategy = address(0x5002);
        vm.prank(OWNER);
        forge.migrate(newStrategy);
        assertEq(forge.yieldStrategy(), newStrategy, "owner migrate");
    }
}
