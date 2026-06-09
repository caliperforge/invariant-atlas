// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @title AccessControlledForge — PLANTED twin for Atlas case 6 (EVM bridge
///        to Trace2Inv; access-control class).
///
/// Same-source twin of `clean/src/AccessControlledForge.sol` with the
/// access-control bug class planted. The single difference: `migrate(address)`
/// is missing its `onlyOwner` modifier. This is the canonical missing-
/// modifier-on-privileged-function pattern evaluated by Trace2Inv (Chen
/// et al., FSE 2024, arXiv:2404.14580) — the named real-world representative
/// the Atlas case cites is Punk Protocol (Aug 2021, ~$8.9M; PeckShield /
/// Halborn post-mortems).
///
/// A `diff -r ../clean/src ../planted/src` shows the planted hunk as a single
/// localized change to the function declaration:
///
///   -    function migrate(address newStrategy) external onlyOwner {
///   +    function migrate(address newStrategy) external {
///
/// The zero-address defensive check is kept; only the access-control gate is
/// removed. This is the *minimal* bug-class plant: removing the require would
/// be a second bug-class (input validation), and the Atlas case is scoped to
/// the access-control class alone.
///
/// Attack sequence on this twin (drives `test_attack_punk_protocol_class` in
/// test/AtlasInvariants.t.sol):
///
///   victim.deposit{value: 1 ether}()           → forge.balance = 1 ether,
///                                                deposits[victim] = 1 ether
///   attacker.migrate(attacker)                 → yieldStrategy = attacker
///                                                (the bug: no onlyOwner gate)
///   attacker.strategyPull(attacker, 1 ether)   → 1 ether sent to attacker
///                                                (the drain: strategy is now
///                                                attacker-controlled)
///   INVARIANT VIOLATED strategy_in_approved_set    (forge.yieldStrategy() is
///                                                   not in approvedStrategies)
contract AccessControlledForge {
    address public immutable owner;
    address public yieldStrategy;

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
    // migrate — PLANTED: `onlyOwner` modifier OMITTED.
    //
    // The single-line diff vs. clean/. The zero-address check stays;
    // the access-control gate is what's missing. Any caller can now
    // become the strategy.
    // ------------------------------------------------------------------
    function migrate(address newStrategy) external {
        require(newStrategy != address(0), "Forge: zero strategy");
        yieldStrategy = newStrategy;
        emit StrategyMigrated(msg.sender, newStrategy);
    }

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

    function strategyPull(address recipient, uint256 amount) external onlyStrategy {
        require(amount > 0, "Forge: zero pull");
        require(amount <= address(this).balance, "Forge: insufficient balance");
        (bool ok, ) = recipient.call{value: amount}("");
        require(ok, "Forge: strategy transfer failed");
        emit StrategyPull(msg.sender, recipient, amount);
    }
}
