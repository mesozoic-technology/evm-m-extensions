// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.26;

import { HookableAssetAcquisition } from "../../src/vaults/HookableAssetAcquisition.sol";

contract HookableAssetAcquisitionHarness is HookableAssetAcquisition {
    event HookCalled(address from, address to, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _swapAdapter,
        address _uniswapV3SwapRouter
    ) HookableAssetAcquisition(_swapAdapter, _uniswapV3SwapRouter) {}

    function initialize(address hookingAsset, address targetAsset) public override initializer {
        super.initialize(hookingAsset, targetAsset);
    }

    function hook(address from, address to, uint256 amount) public override {
        emit HookCalled(from, to, amount);
        super.hook(from, to, amount);
    }
}
