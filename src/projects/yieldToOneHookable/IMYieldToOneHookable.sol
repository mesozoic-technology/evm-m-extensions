// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.26;

/**
 * @title Hookable interface.
 * @author Mesozoic
 */
interface IMYieldToOneHookable {
    /* ============ Events ============ */

    /**
     * @notice Emitted when the hook contract is updated
     * @param hook The address of the hook contract.
     */
    event Hooked(address indexed hook);

    /* ============ Errors ============ */

    /// @notice Emitted if no hook manager is set.
    error ZeroHookManager();

    /// @notice Emitted if no hook contract is set.
    error ZeroHookContract();

    /* ============ Interactive Functions ============ */

    /// @notice Allows user to set the address of the hook contract.
    /// @param hook The address of the hook contract.
    function setHook(address hook) external;

    /* ============ View/Pure Functions ============ */

    /// @notice The role that can manage the freezelist.
    function HOOK_MANAGER_ROLE() external view returns (bytes32);

    /// @notice The address of the hook contract.
    function hook() external view returns (address);
}

/**
 * @title IHookLike interface.
 * @author Mesozoic
 */
interface IHookLike {
    /* ============ Interactive Functions ============ */

    /// @notice Allows user to set the address of the hook contract.
    /// @param from Account being transferred from.
    /// @param to Account being transferred to.
    /// @param amount Amount being transferred.
    function hook(address from, address to, uint256 amount) external;
}
