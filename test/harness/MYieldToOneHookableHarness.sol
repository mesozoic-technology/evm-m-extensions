// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.26;

import { MYieldToOneHookable } from "../../src/projects/yieldToOneHookable/MYieldToOneHookable.sol";

contract MYieldToOneHookableHarness is MYieldToOneHookable {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address mToken, address swapFacility) MYieldToOneHookable(mToken, swapFacility) {}

    function initialize(
        string memory name,
        string memory symbol,
        address yieldRecipient,
        address admin,
        address freezeManager,
        address yieldRecipientManager,
        address hookManager
    ) public override initializer {
        super.initialize(name, symbol, yieldRecipient, admin, freezeManager, yieldRecipientManager, hookManager);
    }

    function setBalanceOf(address account, uint256 amount) external {
        _getMYieldToOneStorageLocation().balanceOf[account] = amount;
    }

    function setTotalSupply(uint256 amount) external {
        _getMYieldToOneStorageLocation().totalSupply = amount;
    }
}
