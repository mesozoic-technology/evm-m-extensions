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
import { IHookableAssetAcquisition } from "./IHookableAssetAcquisition.sol";

// Uniswap imports
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";

// Uniswap TWAMM Hook imports
import { ITWAMM } from "../hooks/ITWAMM.sol";

abstract contract HookableAssetAcquisitionStorageLayout {
    /// @custom:storage-location erc7201:M0.storage.HookableAssetAcquisition
    struct HookableAssetAcquisitionStorageStruct {
        address targetAsset;
        address hookingAsset;
        uint256 targetAssets;
        uint256 hookingAssets;
        uint256 yieldedAssets;
        address liquidityPool;
        uint256 hodling; // seconds per unit held globally.
        uint256 update;
        mapping(address => User) users;
        // Uniswap TWAMM state
        address uniswapPoolManager;
        address uniswapTWAMMHook;
        PoolKey uniswapPoolKey;
        bytes32[] uniswapTWAMMOrderIds;
        ITWAMM.OrderKey[] uniswapTWAMMOrderKeys;
    }

    struct User {
        uint256 hodl; // seconds per unit held per user.
        uint256 update; // last update timestamp.
        uint256 assets;
        bool activated;
    }

    // keccak256(abi.encode(uint256(keccak256("M0.storage.HookableAssetAcquisition")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _HOOKABLE_ASSET_Acquisition_STORAGE_LOCATION =
        0x2fd5767309dce890c526ace85d7fe164825199d7dcd99c33588befc51b32ce00;

    function _getHookableAssetAcquisitionStorageLocation()
        internal
        pure
        returns (HookableAssetAcquisitionStorageStruct storage $)
    {
        assembly {
            $.slot := _HOOKABLE_ASSET_Acquisition_STORAGE_LOCATION
        }
    }
}

contract HookableAssetAcquisition is IHookableAssetAcquisition, HookableAssetAcquisitionStorageLayout, Initializable {
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
        __HookableAssetAcquisition_init(_hookingAsset, _targetAsset);
    }

    function __HookableAssetAcquisition_init(address _hookingAsset, address _targetAsset) public {
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

        HookableAssetAcquisitionStorageStruct storage $ = _getHookableAssetAcquisitionStorageLocation();

        HookableAssetAcquisitionStorageLayout.User storage user = $.users[msg.sender];

        _updateUser(user);

        uint256 targetClaim = (user.hodl * $.targetAssets) / $.hodling;

        $.hodling -= user.hodl;

        user.hodl = 0;

        $.targetAssets -= targetClaim;

        IERC20($.targetAsset).transfer(msg.sender, targetClaim);
    }

    function hook(address _from, address _to, uint256 _amount) public virtual onlyHookingContract {
        HookableAssetAcquisitionStorageStruct storage $ = _getHookableAssetAcquisitionStorageLocation();

        HookableAssetAcquisitionStorageLayout.User storage userFromStruct = $.users[_from];

        if (userFromStruct.activated) {
            userFromStruct.assets -= _amount;
            _updateUser(userFromStruct);
        }

        HookableAssetAcquisitionStorageLayout.User storage userToStruct = $.users[_to];

        if (userToStruct.activated) {
            userToStruct.assets += _amount;
            _updateUser(userToStruct);
        }

        // NOTE: yield comes in
        if (_to == address(this)) $.yieldedAssets += _amount;

        // NOTE: yield goes out
        if (_from == address(this)) $.yieldedAssets -= _amount;

        // NOTE: minting, increment hooking assets
        if (_from == address(0) && _to != address(this)) {
            HookableAssetAcquisitionStorageStruct storage $ = _getHookableAssetAcquisitionStorageLocation();
            $.hookingAssets += _amount;
        }

        // NOTE: burning, decrement hooking assets
        if (_to == address(0) && _from != address(this)) {
            HookableAssetAcquisitionStorageStruct storage $ = _getHookableAssetAcquisitionStorageLocation();
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

    function activateUser() public {
        _activateUser(msg.sender);
    }

    function getHookingAsset() public view returns (address) {
        return _getHookableAssetAcquisitionStorageLocation().hookingAsset;
    }

    function getTargetAsset() public view returns (address) {
        return _getHookableAssetAcquisitionStorageLocation().targetAsset;
    }

    function getYieldedAssets() public view returns (uint256) {
        return _getHookableAssetAcquisitionStorageLocation().yieldedAssets;
    }

    function getTWAMMOrderId(uint256 index) public view returns (bytes32) {
        return _getHookableAssetAcquisitionStorageLocation().uniswapTWAMMOrderIds[index];
    }

    function getTWAMMOrderKey(uint256 index) public view returns (ITWAMM.OrderKey memory) {
        return _getHookableAssetAcquisitionStorageLocation().uniswapTWAMMOrderKeys[index];
    }

    function getHookingAssets() public view returns (uint256) {
        return _getHookableAssetAcquisitionStorageLocation().hookingAssets;
    }

    function getTargetAssets() public view returns (uint256) {
        return _getHookableAssetAcquisitionStorageLocation().targetAssets;
    }

    function getUser(address user) public view returns (uint256 assets, uint256 update, uint256 hodl) {
        HookableAssetAcquisitionStorageLayout.User storage $ = _getHookableAssetAcquisitionStorageLocation().users[
            user
        ];
        return ($.assets, $.update, $.hodl);
    }

    function getHodling() public view returns (uint256 hodling) {
        return _getHookableAssetAcquisitionStorageLocation().hodling;
    }

    function spotSwap() public {
        _spotSwap();
    }

    function twammSwap() public {
        _twammSwap();
    }

    function twammClaim() public {
        _twammClaim();
    }

    function setTWAMMConfig(
        address _uniswapPoolManager,
        address _uniswapTWAMMHook,
        PoolKey memory _uniswapPoolKey
    ) public {
        HookableAssetAcquisitionStorageStruct storage $ = _getHookableAssetAcquisitionStorageLocation();

        $.uniswapPoolManager = _uniswapPoolManager;
        $.uniswapTWAMMHook = _uniswapTWAMMHook;
        $.uniswapPoolKey = _uniswapPoolKey;
    }

    function _activateUser(address _user) internal {
        HookableAssetAcquisitionStorageStruct storage $ = _getHookableAssetAcquisitionStorageLocation();

        HookableAssetAcquisitionStorageLayout.User storage userStruct = $.users[_user];

        if (userStruct.activated) revert("Already Activated");

        userStruct.activated = true;

        uint256 _balance = IERC20($.hookingAsset).balanceOf(_user);

        if (0 < _balance) {
            _updateUser(userStruct);
            userStruct.assets += _balance;
        }
    }

    function _updateUser(HookableAssetAcquisitionStorageLayout.User storage userStruct) internal {
        if (userStruct.update != 0) {
            uint256 secondsSince = block.timestamp - userStruct.update;
            uint256 secondsPerHodl = secondsSince * userStruct.assets;

            userStruct.hodl += secondsPerHodl;
        }

        userStruct.update = block.timestamp;
    }

    function _updateGlobal() internal returns (HookableAssetAcquisitionStorageStruct storage $) {
        $ = _getHookableAssetAcquisitionStorageLocation();

        if ($.update != 0) {
            uint256 secondsSince = block.timestamp - $.update;
            uint256 secondsPerHodl = secondsSince * $.hookingAssets;

            $.hodling += secondsPerHodl;
        }

        $.update = block.timestamp;
    }

    function _getUser(address user) internal view returns (HookableAssetAcquisitionStorageLayout.User storage) {
        HookableAssetAcquisitionStorageStruct storage $ = _getHookableAssetAcquisitionStorageLocation();

        return $.users[user];
    }

    function _scrapeYield() internal {
        HookableAssetAcquisitionStorageStruct storage $ = _getHookableAssetAcquisitionStorageLocation();

        uint256 yield = IMYieldToOne($.hookingAsset).claimYield();
    }

    function _spotSwap() internal {
        HookableAssetAcquisitionStorageStruct storage $ = _getHookableAssetAcquisitionStorageLocation();

        uint256 intermediateUSDC = _swapYieldToUSDC();

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
    }

    function _twammSwap() internal {
        HookableAssetAcquisitionStorageStruct storage $ = _getHookableAssetAcquisitionStorageLocation();

        uint256 intermediateUSDC = _swapYieldToUSDC();

        IERC20(USDC).approve($.uniswapTWAMMHook, intermediateUSDC);

        ITWAMM.SubmitOrderParams memory orderParams = ITWAMM.SubmitOrderParams({
            key: $.uniswapPoolKey,
            zeroForOne: Currency.unwrap($.uniswapPoolKey.currency0) == $.targetAsset ? false : true,
            amountIn: intermediateUSDC,
            duration: 10 days
        });

        (bytes32 orderId, ITWAMM.OrderKey memory orderKey) = ITWAMM($.uniswapTWAMMHook).submitOrder(orderParams);

        $.uniswapTWAMMOrderIds.push(orderId);
        $.uniswapTWAMMOrderKeys.push(orderKey);
    }

    function _twammClaim() internal {
        HookableAssetAcquisitionStorageStruct storage $ = _getHookableAssetAcquisitionStorageLocation();

        (uint256 _claimed0, uint256 _claimed1) = ITWAMM($.uniswapTWAMMHook).claimTokensByPoolKey($.uniswapPoolKey);

        if (Currency.unwrap($.uniswapPoolKey.currency0) == $.targetAsset) {
            $.targetAssets += _claimed0;
            $.yieldedAssets += _claimed1;
        } else {
            $.targetAssets += _claimed1;
            $.yieldedAssets += _claimed0;
        }
    }

    function _swapYieldToUSDC() internal returns (uint256 usdcAmount) {
        HookableAssetAcquisitionStorageStruct storage $ = _getHookableAssetAcquisitionStorageLocation();

        IERC20($.hookingAsset).approve(swapAdapter, $.yieldedAssets);

        IUniswapV3SwapAdapter(swapAdapter).swapOut($.hookingAsset, $.yieldedAssets, USDC, 0, address(this), "");

        // TODO: transform any excess wM back into yieldable asset.

        return IERC20(USDC).balanceOf(address(this));
    }

    function _setHookingAsset(address _hookingAsset) internal {
        HookableAssetAcquisitionStorageStruct storage $ = _getHookableAssetAcquisitionStorageLocation();
        $.hookingAsset = _hookingAsset;
    }

    function _setTargetAsset(address _targetAsset) internal {
        HookableAssetAcquisitionStorageStruct storage $ = _getHookableAssetAcquisitionStorageLocation();
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
