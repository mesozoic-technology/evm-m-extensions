// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { console } from "forge-std/console.sol";

import {
    Initializable
} from "../../lib/common/lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";

import {
    IERC20
} from "../../lib/common/lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { IMYieldToOne } from "../projects/yieldToOne/IMYieldToOne.sol";
import { IHookLike } from "../projects/yieldToOneHookable/IMYieldToOneHookable.sol";
import { IUniswapV3SwapAdapter } from "../swap/interfaces/IUniswapV3SwapAdapter.sol";
import { IV3SwapRouter } from "../swap/interfaces/uniswap/IV3SwapRouter.sol";
import { IHookableAssetAquisition } from "./IHookableAssetAquisition.sol";

abstract contract HookableAssetAquisitionStorageLayout {
    /// @custom:storage-location erc7201:M0.storage.HookableAssetAquisition
    struct HookableAssetAquisitionStorageStruct {
        address targetAsset;
        address hookingAsset;
        uint256 targetAssets;
        uint256 hookingAssets;
        uint256 yieldedAssets;
        address liquidityPool;
        uint256 hodling; // seconds per unit held globally.
        uint256 update;
        mapping(address => User) users;
    }

    struct User {
        uint256 hodl; // seconds per unit held per user.
        uint256 update; // last update timestamp.
        uint256 assets;
    }

    // keccak256(abi.encode(uint256(keccak256("M0.storage.HookableAssetAquisition")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _HOOKABLE_ASSET_AQUISITION_STORAGE_LOCATION =
        0x2fd5767309dce890c526ace85d7fe164825199d7dcd99c33588befc51b32ce00;

    function _getHookableAssetAquisitionStorageLocation()
        internal
        pure
        returns (HookableAssetAquisitionStorageStruct storage $)
    {
        assembly {
            $.slot := _HOOKABLE_ASSET_AQUISITION_STORAGE_LOCATION
        }
    }
}

contract HookableAssetAquisition is IHookableAssetAquisition, HookableAssetAquisitionStorageLayout, Initializable {
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable swapAdapter;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable uniswapV3SwapRouter;

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /**
     * @custom:oz-upgrades-unsafe-allow constructor
     * @notice Constructs SwapFacility Implementation contract
     * @dev    Sets immutable storage.
     * @param  swapAdapter_      The address of the M swap adapter.
     * @param  uniswapV3SwapRouter_   The address of the Uniswap swap router.
     */
    constructor(address swapAdapter_, address uniswapV3SwapRouter_) {
        swapAdapter = swapAdapter_;
        uniswapV3SwapRouter = uniswapV3SwapRouter_;
    }

    function initialize(address _hookingAsset, address _targetAsset) public virtual {
        __HookableAssetAquisition_init(_hookingAsset, _targetAsset);
    }

    function __HookableAssetAquisition_init(address _hookingAsset, address _targetAsset) public {
        if (_hookingAsset == address(0)) revert ZeroHookingAsset();
        if (_targetAsset == address(0)) revert ZeroTargetAsset();

        _setHookingAsset(_hookingAsset);
        _setTargetAsset(_targetAsset);
    }

    modifier onlyHookingContract() {
        if (msg.sender != getHookingAsset()) revert OnlyHookingContract();
        _;
    }

    function claim() public {
        _scrapeYield();

        HookableAssetAquisitionStorageStruct storage $ = _updateGlobal();

        HookableAssetAquisitionStorageLayout.User storage user = _updateUser(msg.sender);

        uint256 targetClaim = (user.hodl * $.targetAssets) / $.hodling;

        $.hodling -= user.hodl;

        user.hodl = 0;

        $.targetAssets -= targetClaim;

        IERC20($.targetAsset).transfer(msg.sender, targetClaim);
    }

    function hook(address _from, address _to, uint256 _amount) public virtual onlyHookingContract {
        // TODO: address intrcacies of transfers to and from smart contract where
        // 1) they may be a smart contract wallet holding the asset
        // 2) a liquidity pool or lending market into which various
        //    users contribute assets thereby comingle rewards
        // 3) operational smart contracts that are a part of the
        //    m liquidity network
        if (!_isContract(_from) && _from != address(0)) {
            HookableAssetAquisitionStorageLayout.User storage userFromStruct = _updateUser(_from);
            userFromStruct.assets -= _amount;
        }

        if (!_isContract(_to) && _to != address(0)) {
            HookableAssetAquisitionStorageLayout.User storage userToStruct = _updateUser(_to);
            userToStruct.assets += _amount;
        }

        if (_to == address(this)) {
            HookableAssetAquisitionStorageStruct storage $ = _getHookableAssetAquisitionStorageLocation();
            $.yieldedAssets += _amount;
        }

        if (_from == address(this)) {
            HookableAssetAquisitionStorageStruct storage $ = _getHookableAssetAquisitionStorageLocation();
            $.yieldedAssets -= _amount;
        }

        // NOTE: minting, increment hooking assets
        if (_from == address(0) && _to != address(this)) {
            HookableAssetAquisitionStorageStruct storage $ = _getHookableAssetAquisitionStorageLocation();
            $.hookingAssets += _amount;
        }

        // NOTE: burning, decrement hooking assets
        if (_to == address(0) && _from != address(this)) {
            HookableAssetAquisitionStorageStruct storage $ = _getHookableAssetAquisitionStorageLocation();
            $.hookingAssets += _amount;
        }

        _updateGlobal();

        // NOTE: only call scrape yield if update is not a burn
        // due to unwrap mechanics in the swap facility which
        // burn the mYieldToOne token before transferring out
        // underlying M, which would falsely extra yield due to
        // how mYieldToOne calcultes its yield given the delta
        // of its own total supply versus its underlying M balance
        if (_to != address(0)) {
            _scrapeYield();
        }
    }

    function getHookingAsset() public view returns (address) {
        return _getHookableAssetAquisitionStorageLocation().hookingAsset;
    }

    function getTargetAsset() public view returns (address) {
        return _getHookableAssetAquisitionStorageLocation().targetAsset;
    }

    function getYieldedAssets() public view returns (uint256) {
        return _getHookableAssetAquisitionStorageLocation().yieldedAssets;
    }

    function getHookingAssets() public view returns (uint256) {
        return _getHookableAssetAquisitionStorageLocation().hookingAssets;
    }

    function getTargetAssets() public view returns (uint256) {
        return _getHookableAssetAquisitionStorageLocation().targetAssets;
    }

    function getUser(address user) public view returns (uint256 assets, uint256 update, uint256 hodl) {
        HookableAssetAquisitionStorageLayout.User storage $ = _getHookableAssetAquisitionStorageLocation().users[user];
        return ($.assets, $.update, $.hodl);
    }

    function getHodling() public view returns (uint256 hodling) {
        return _getHookableAssetAquisitionStorageLocation().hodling;
    }

    function spotSwap() public {
        _spotSwap();
    }

    function _updateUser(
        address _user
    ) internal returns (HookableAssetAquisitionStorageLayout.User storage userStruct) {
        HookableAssetAquisitionStorageStruct storage $ = _getHookableAssetAquisitionStorageLocation();

        userStruct = $.users[_user];

        if (userStruct.update != 0) {
            uint256 secondsSince = block.timestamp - userStruct.update;
            uint256 secondsPerHodl = secondsSince * userStruct.assets;

            userStruct.hodl += secondsPerHodl;
        }

        userStruct.update = block.timestamp;
    }

    function _updateGlobal() internal returns (HookableAssetAquisitionStorageStruct storage $) {
        $ = _getHookableAssetAquisitionStorageLocation();

        if ($.update != 0) {
            uint256 secondsSince = block.timestamp - $.update;
            uint256 secondsPerHodl = secondsSince * $.hookingAssets;

            $.hodling += secondsPerHodl;
        }

        $.update = block.timestamp;
    }

    function _getUser(address user) internal view returns (HookableAssetAquisitionStorageLayout.User storage) {
        HookableAssetAquisitionStorageStruct storage $ = _getHookableAssetAquisitionStorageLocation();

        return $.users[user];
    }

    function _scrapeYield() internal {
        HookableAssetAquisitionStorageStruct storage $ = _getHookableAssetAquisitionStorageLocation();

        uint256 yield = IMYieldToOne($.hookingAsset).claimYield();
    }

    function _spotSwap() internal {
        HookableAssetAquisitionStorageStruct storage $ = _getHookableAssetAquisitionStorageLocation();

        IERC20($.hookingAsset).approve(swapAdapter, $.yieldedAssets);

        IUniswapV3SwapAdapter(swapAdapter).swapOut($.hookingAsset, $.yieldedAssets, USDC, 0, address(this), "");

        uint256 intermediateUSDC = IERC20(USDC).balanceOf(address(this));

        IERC20(USDC).approve(uniswapV3SwapRouter, intermediateUSDC);

        uint256 targetAmountOut = IV3SwapRouter(uniswapV3SwapRouter).exactInput(
            IV3SwapRouter.ExactInputParams({
                path: abi.encodePacked(USDC, uint24(3000), $.targetAsset),
                recipient: address(this),
                amountIn: intermediateUSDC,
                amountOutMinimum: 0
            })
        );

        $.targetAssets += targetAmountOut;

        $.yieldedAssets = 0;

        // TODO: transform any excess wM back into yieldable asset.
    }

    function _setHookingAsset(address _hookingAsset) internal {
        HookableAssetAquisitionStorageStruct storage $ = _getHookableAssetAquisitionStorageLocation();
        $.hookingAsset = _hookingAsset;
    }

    function _setTargetAsset(address _targetAsset) internal {
        HookableAssetAquisitionStorageStruct storage $ = _getHookableAssetAquisitionStorageLocation();
        $.targetAsset = _targetAsset;
    }

    function _isContract(address _addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }
}
