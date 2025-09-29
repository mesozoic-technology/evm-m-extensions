// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.26;

import { IHookLike } from "../projects/yieldToOneHookable/IMYieldToOneHookable.sol";

/**
 * @title HookableAssetAquisition interface.
 * @author Mesozoic
 */
interface IHookableAssetAquisition is IHookLike {
    error ZeroHookingAsset();
    error ZeroTargetAsset();
    error OnlyHookingContract();
}
