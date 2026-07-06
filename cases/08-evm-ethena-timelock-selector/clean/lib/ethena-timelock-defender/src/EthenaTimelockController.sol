// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TimelockController, Address} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
/**
 * @title EthenaTimelockController
 * @dev A custom timelock contract extending OpenZeppelin's TimelockController.
 * - Allows bypassing the timelock for whitelisted functions.
 * - Functions can be whitelisted or removed from the whitelist by the admin.
 * - Emits events for whitelisting, removing from whitelist, and executing whitelisted functions.
 * - Overrides execute function to check for whitelisted functions.
 */

contract EthenaTimelockController is TimelockController, ReentrancyGuard {
    error NotWhitelisted(address target, bytes4 selector);
    error InvalidTarget(address target);
    error InvalidSelector(bytes data);
    error InvalidRoleGrant(address target, bytes32 role);
    error RenounceRoleNotAllowed(bytes32 role, address callerConfirmation);

    event FunctionWhitelisted(address indexed target, bytes4 indexed selector);
    event FunctionRemovedFromWhitelist(address indexed target, bytes4 indexed selector);
    event WhitelistedFunctionExecuted(address indexed target, bytes4 indexed selector, uint256 value, bytes data);

    // New role for whitelisted function execution
    bytes32 public constant WHITELISTED_EXECUTOR_ROLE = keccak256("WHITELISTED_EXECUTOR_ROLE");

    uint256 private constant SELECTOR_LENGTH = 4;

    /// @notice Mapping of whitelisted functions that can be executed without delay
    mapping(address target => mapping(bytes4 selector => bool allowed)) private _functionWhitelist;

    modifier onlyTimelock() {
        address sender = _msgSender();
        if (sender != address(this)) {
            revert TimelockUnauthorizedCaller(sender);
        }
        _;
    }

    /**
     * @dev Constructor for the CustomTimelock contract.
     * @param minDelay The minimum delay before an operation can be executed.
     * @param proposers The list of addresses that can propose operations.
     * @param executors The list of addresses that can execute operations.
     * @param whitelistedExecutors The list of addresses that can execute whitelisted operations.
     */
    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address[] memory whitelistedExecutors
    ) TimelockController(minDelay, proposers, executors, address(0)) ReentrancyGuard() {
        for (uint256 i = 0; i < proposers.length; ++i) {
            if (proposers[i] == address(0)) {
                revert InvalidRoleGrant(proposers[i], PROPOSER_ROLE);
            }
        }
        // grant whitelisted executor role
        for (uint256 i = 0; i < whitelistedExecutors.length; ++i) {
            if (whitelistedExecutors[i] == address(0)) {
                revert InvalidRoleGrant(whitelistedExecutors[i], WHITELISTED_EXECUTOR_ROLE);
            }
            _grantRole(WHITELISTED_EXECUTOR_ROLE, whitelistedExecutors[i]);
        }
    }

    /**
     * @dev Adds a function selector to the whitelist for a specific address.
     * Can only be called via the timelock mechanism.
     * @param target The address of the contract.
     * @param selector The function selector to whitelist.
     */
    function addToWhitelist(address target, bytes4 selector) external onlyTimelock {
        if (target == address(0) || target == address(this) || target.code.length == 0) {
            revert InvalidTarget(target);
        }
        if (_functionWhitelist[target][selector]) {
            return;
        }
        _functionWhitelist[target][selector] = true;
        emit FunctionWhitelisted(target, selector);
    }

    /**
     * @dev Removes a function selector from the whitelist for a specific address.
     * Can only be called via the timelock mechanism.
     * @param target The address of the contract.
     * @param selector The function selector to remove from the whitelist.
     */
    function removeFromWhitelist(address target, bytes4 selector) external onlyTimelock {
        if (!_functionWhitelist[target][selector]) {
            return;
        }
        _functionWhitelist[target][selector] = false;
        emit FunctionRemovedFromWhitelist(target, selector);
    }

    /**
     * @dev Checks if a function selector is whitelisted for a specific address.
     * @param target The address of the contract.
     * @param selector The function selector to check.
     * @return True if the function selector is whitelisted, false otherwise.
     */
    function isWhitelisted(address target, bytes4 selector) public view returns (bool) {
        return _functionWhitelist[target][selector];
    }

    /**
     * @dev Executes a function, bypassing the timelock if it's whitelisted.
     * @param target The address of the contract to call.
     * @param value The amount of ETH to send along with the call.
     * @param data The calldata to send.
     * @param predecessor The operation that must be executed before this one.
     * @param salt A random value used to differentiate the operation from others.
     */
    function execute(address target, uint256 value, bytes calldata data, bytes32 predecessor, bytes32 salt)
        public
        payable
        override
        nonReentrant
    {
        // Guarded by onlyRoleOrOpenRole(EXECUTOR_ROLE)
        super.execute(target, value, data, predecessor, salt);
    }

    /**
     * @dev Executes a whitelisted function.
     * @param target The address of the contract to call.
     * @param value The amount of ETH to send along with the call.
     * @param data The calldata to send.
     */
    function executeWhitelisted(address target, uint256 value, bytes calldata data)
        public
        payable
        onlyRole(WHITELISTED_EXECUTOR_ROLE)
        nonReentrant
    {
        bytes4 selector = _extractSelector(data);
        if (!isWhitelisted(target, selector)) {
            revert NotWhitelisted(target, selector);
        }
        emit WhitelistedFunctionExecuted(target, selector, value, data);
        Address.functionCallWithValue(target, data, value);
    }

    /**
     * @dev Executes a batch of whitelisted functions.
     * @param targets The addresses of the contracts to call.
     * @param values The amounts of ETH to send along with the calls.
     * @param payloads The calldata to send.
     * @param predecessor The operation that must be executed before this one.
     * @param salt A random value used to differentiate the operation from others.
     */
    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) public payable override nonReentrant {
        super.executeBatch(targets, values, payloads, predecessor, salt);
    }

    /**
     * @dev Executes a batch of whitelisted functions.
     * @param targets The addresses of the contracts to call.
     * @param values The amounts of ETH to send along with the calls.
     * @param payloads The calldata to send.
     */
    function executeWhitelistedBatch(address[] calldata targets, uint256[] calldata values, bytes[] calldata payloads)
        public
        payable
        onlyRole(WHITELISTED_EXECUTOR_ROLE)
        nonReentrant
    {
        if (targets.length != values.length || targets.length != payloads.length) {
            revert TimelockInvalidOperationLength(targets.length, payloads.length, values.length);
        }

        for (uint256 i = 0; i < targets.length; ++i) {
            bytes4 selector = _extractSelector(payloads[i]);
            address target = targets[i];
            if (!_functionWhitelist[target][selector]) {
                revert NotWhitelisted(target, selector);
            }
            emit WhitelistedFunctionExecuted(target, selector, values[i], payloads[i]);
            Address.functionCallWithValue(target, payloads[i], values[i]);
        }
    }

    /**
     * @dev Throws an error when trying to renounce a role.
     * @notice Roles cannot be renounced, only revoked thru timelock mechanism.
     * @param role The role to renounce.
     * @param callerConfirmation The address that is renouncing the role.
     */
    function renounceRole(bytes32 role, address callerConfirmation) public pure override {
        revert RenounceRoleNotAllowed(role, callerConfirmation);
    }

    /**
     * @dev Extracts the function selector from the calldata.
     * @notice Risk of selector collision mitigated by whitelisting being permissioned action and specific to target address.
     * @param data The calldata to extract the selector from.
     * @return selector The function selector.
     */
    function _extractSelector(bytes calldata data) internal pure returns (bytes4 selector) {
        if (data.length == 0) {
            selector = bytes4(0);
        } else if (data.length < SELECTOR_LENGTH) {
            revert InvalidSelector(data);
        } else {
            selector = bytes4(data[:SELECTOR_LENGTH]);
        }
    }
}
