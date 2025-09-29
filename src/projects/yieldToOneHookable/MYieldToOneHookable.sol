// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.26;

import { IMYieldToOne } from "../yieldToOne/IMYieldToOne.sol";
import { MYieldToOne } from "../yieldToOne/MYieldToOne.sol";
import { IMYieldToOneHookable, IHookLike } from "./IMYieldToOneHookable.sol";

abstract contract MYieldToOneHookableStorageLayout {
    /// @custom:storage-location erc7201:M0.storage.MYieldToOneHookable
    struct MYieldToOneHookableStorageStruct {
        address hook;
    }

    // keccak256(abi.encode(uint256(keccak256("M0.storage.MYieldToOneHookable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _M_YIELD_TO_ONE_HOOKABLE_STORAGE_LOCATION =
        0x2fd5767309dce890c526ace85d7fe164825199d7dcd99c33588befc51b32ce00;

    function _getMYieldToOneHookableStorageLocation()
        internal
        pure
        returns (MYieldToOneHookableStorageStruct storage $)
    {
        assembly {
            $.slot := _M_YIELD_TO_ONE_HOOKABLE_STORAGE_LOCATION
        }
    }
}

/**
 * @title  MYieldToOne
 * @notice Upgradeable ERC20 Token contract for wrapping M into a non-rebasing token
 *         with yield claimable by a single recipient.
 * @author M0 Labs
 */
contract MYieldToOneHookable is IMYieldToOneHookable, MYieldToOneHookableStorageLayout, MYieldToOne {
    /* ============ Variables ============ */

    /// @inheritdoc IMYieldToOneHookable
    bytes32 public constant HOOK_MANAGER_ROLE = keccak256("HOOK_MANAGER_ROLE");

    /**
     * @custom:oz-upgrades-unsafe-allow constructor
     * @notice Constructs MYieldToOne Implementation contract
     * @dev    Sets immutable storage.
     * @param  mToken       The address of $M token.
     * @param  swapFacility The address of Swap Facility.
     */
    constructor(address mToken, address swapFacility) MYieldToOne(mToken, swapFacility) {
        _disableInitializers();
    }

    function initialize(
        string memory name,
        string memory symbol,
        address yieldRecipient,
        address admin,
        address freezeManager,
        address yieldRecipientManager,
        address hookManager,
        address hookContract
    ) public virtual initializer {
        __MYieldToOneHookable_init(
            name,
            symbol,
            yieldRecipient,
            admin,
            freezeManager,
            yieldRecipientManager,
            hookManager,
            hookContract
        );
    }

    /* ============ Initializer ============ */

    function __MYieldToOneHookable_init(
        string memory name,
        string memory symbol,
        address yieldRecipient,
        address admin,
        address freezeManager,
        address yieldRecipientManager,
        address hookManager,
        address hookContract
    ) internal {
        if (hookManager == address(0)) revert ZeroHookManager();
        if (hookContract == address(0)) revert ZeroHookContract();
        __MYieldToOne_init(name, symbol, yieldRecipient, admin, freezeManager, yieldRecipientManager);
        _grantRole(HOOK_MANAGER_ROLE, hookManager);
        _setHook(hookContract);
    }

    /* ============ Interactive Functions ============ */

    function setHook(address hookContract) public onlyRole(HOOK_MANAGER_ROLE) {
        _setHook(hookContract);
    }

    /* ============ View/Pure Functions ============ */

    /// @inheritdoc IMYieldToOneHookable
    function hook() public view returns (address) {
        return _getMYieldToOneHookableStorageLocation().hook;
    }

    /* ============ Internal Interactive Functions ============ */

    function _setHook(address hookContract) internal {
        MYieldToOneHookableStorageStruct storage $ = _getMYieldToOneHookableStorageLocation();
        $.hook = hookContract;
        emit Hooked(hookContract);
    }

    function _update(address from, address to, uint256 amount) internal override(MYieldToOne) {
        super._update(from, to, amount);
        _callHook(from, to, amount);
    }

    function _mint(address recipient, uint256 amount) internal override(MYieldToOne) {
        super._mint(recipient, amount);
        _callHook(address(0), recipient, amount);
    }

    function _burn(address account, uint256 amount) internal override(MYieldToOne) {
        super._burn(account, amount);
        _callHook(account, address(0), amount);
    }

    function _callHook(address from, address to, uint256 amount) internal {
        MYieldToOneHookableStorageStruct storage $ = _getMYieldToOneHookableStorageLocation();

        if ($.hook != address(0)) IHookLike($.hook).hook(from, to, amount);
    }
}
