// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.26;

import { HookableAssetAquisition } from "../../src/vaults/HookableAssetAquisition.sol";

contract HookableAssetAquisitionHarness is HookableAssetAquisition {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _swapAdapter,
        address _uniswapV3SwapRouter
    ) HookableAssetAquisition(_swapAdapter, _uniswapV3SwapRouter) {}

    function initialize(address hookingAsset, address targetAsset) public override initializer {
        super.initialize(hookingAsset, targetAsset);
    }
}
