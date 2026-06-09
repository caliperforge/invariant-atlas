// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @title AccessControlledForge — CLEAN twin for Atlas case 6 (EVM bridge to
///        Trace2Inv; access-control class).
///
/// Same-source twin of a privileged-function-bearing yield-deposit contract
/// with the access-control class fix applied. The single difference between
/// this file and `planted/src/AccessControlledForge.sol` is the `onlyOwner`
/// modifier on `migrate(address)` — the minimal single-line diff for the
/// canonical missing-modifier bug class evaluated by Trace2Inv (Chen et al.,
/// FSE 2024, arXiv:2404.14580).
///
/// A `diff -r ../clean/src ../planted/src` shows the planted hunk as exactly
/// that change to the function declaration. The require-non-zero defensive
/// check is kept on both twins — only the access-control gate differs.
///
/// Bug class reconstructed (per the Trace2Inv-cataloged access-control class;
/// the named real-world representative cited in the case README is Punk
/// Protocol, Aug 2021, ~$8.9M — PeckShield / Halborn post-mortems):
///
///   A privileged setter (`migrate`) swaps the yield-strategy address — the
///   address authorized to pull contract balance via `strategyPull`. The
///   intended invariant is that only the owner can change the strategy. On
///   the planted twin the `onlyOwner` modifier is absent, so any caller can
///   set the strategy to an address they control; they then call
///   `strategyPull(attacker, contractBalance)` to drain user deposits.
///
/// Two properties detect this bug class on the planted twin and hold on this
/// clean twin (driven by test/AtlasInvariants.t.sol):
///
///   A. admin_only_migrate (per-call temporal). Every successful migrate(_)
///      call must have been made by `owner`. CLEAN: `onlyOwner` reverts
///      non-owner calls. PLANTED: non-owner migrate succeeds → fires.
///   B. strategy_in_approved_set (global state). At every reachable state,
///      `yieldStrategy()` is in the test-maintained `approvedStrategies`
///      ledger (seeded with the constructor-set initial strategy; extended
///      only when migrate succeeds AND caller was owner). PLANTED: attacker
///      migrate sets yieldStrategy to an address NOT in the ledger → fires.
///
/// What this file is NOT:
///   - NOT a fork of any production protocol's source. The contract is the
///     minimal access-controlled-deposit primitive needed to exercise the
///     bug class.
///   - NOT a runtime guard. The properties live in test/AtlasInvariants.t.sol
///     as pre-deploy Foundry stateful-invariant tests — the §1.1 "pre-deploy
///     CI gate, not runtime guard" differentiator made concrete.
///   - NOT a complete yield-strategy implementation. `strategyPull` is the
///     single privileged outflow path; production yield-strategy contracts
///     have many more surfaces. The Atlas's twin is scoped to the access-
///     control failure class only.
contract AccessControlledForge {
    // The contract deployer. Immutable: set once at construction, never
    // rotated. A production protocol would replace this with a multisig
    // or a two-step `proposeOwner` / `acceptOwner` pattern; the Atlas
    // twin uses immutable because the bug class is *missing access
    // control*, not *flawed ownership-transfer flow*.
    address public immutable owner;

    // The address authorized to call `strategyPull`. Settable via
    // `migrate(_)`. On CLEAN, `migrate` is `onlyOwner`-gated; on PLANTED
    // the modifier is omitted — the bug.
    address public yieldStrategy;

    // Per-user deposit ledger. Drives the unit test's round-trip check
    // and is read by the stateful fuzzer's handler.
    mapping(address => uint256) public deposits;
    uint256 public totalDeposits;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event StrategyMigrated(address indexed by, address indexed newStrategy);
    event StrategyPull(address indexed strategy, address indexed recipient, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Forge: not owner");
        _;
    }

    modifier onlyStrategy() {
        require(msg.sender == yieldStrategy, "Forge: not strategy");
        _;
    }

    constructor(address _initialStrategy) {
        require(_initialStrategy != address(0), "Forge: zero strategy");
        owner = msg.sender;
        yieldStrategy = _initialStrategy;
    }

    // ------------------------------------------------------------------
    // migrate — the privileged function.
    //
    // CLEAN: external onlyOwner.
    // PLANTED: external (no modifier).
    //
    // The single-line diff between the two twins. The defensive
    // zero-address check is kept on both — only the `onlyOwner` gate
    // is what closes the bug class.
    // ------------------------------------------------------------------
    function migrate(address newStrategy) external onlyOwner {
        require(newStrategy != address(0), "Forge: zero strategy");
        yieldStrategy = newStrategy;
        emit StrategyMigrated(msg.sender, newStrategy);
    }

    // ------------------------------------------------------------------
    // User-facing deposit / withdraw. Standard checks-effects-
    // interactions; not under test for this case (the bug class is
    // access-control on migrate, not reentrancy / accounting drift).
    // ------------------------------------------------------------------
    function deposit() external payable {
        require(msg.value > 0, "Forge: zero deposit");
        deposits[msg.sender] += msg.value;
        totalDeposits += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        require(amount > 0, "Forge: zero withdraw");
        require(deposits[msg.sender] >= amount, "Forge: insufficient deposit");
        deposits[msg.sender] -= amount;
        totalDeposits -= amount;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "Forge: withdraw transfer failed");
        emit Withdraw(msg.sender, amount);
    }

    // ------------------------------------------------------------------
    // strategyPull — the privileged outflow path the access-control gate
    // is supposed to protect. Only the configured strategy can call.
    //
    // If `migrate` is properly gated (CLEAN), strategy is always the
    // owner-blessed address. If `migrate` is ungated (PLANTED), an
    // attacker can become strategy and call this to drain the contract.
    // ------------------------------------------------------------------
    function strategyPull(address recipient, uint256 amount) external onlyStrategy {
        require(amount > 0, "Forge: zero pull");
        require(amount <= address(this).balance, "Forge: insufficient balance");
        (bool ok, ) = recipient.call{value: amount}("");
        require(ok, "Forge: strategy transfer failed");
        emit StrategyPull(msg.sender, recipient, amount);
    }
}
