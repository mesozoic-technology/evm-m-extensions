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

// CoW imports
import { GPv2Order } from "../libs/CoWTWAP/GPv2Order.sol";
import { CoWTWAPLib } from "../libs/CoWTWAP/CoWTWAP.sol";
import { IConditionalOrder } from "../libs/CoWTWAP/IConditionalOrder.sol";

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
        // CoW TWAP state
        mapping(bytes32 => CoWTWAPLib.TWAPConfig) twapConfigs;
        mapping(bytes32 => CoWTWAPLib.TWAPState) twapStates;
        bytes32 activeTWAPId;
    }

    struct User {
        uint256 hodl; // seconds per unit held per user.
        uint256 update; // last update timestamp.
        uint256 assets;
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

contract HookableAssetAcquisition is
    IHookableAssetAcquisition,
    HookableAssetAcquisitionStorageLayout,
    Initializable,
    IConditionalOrder
{
    using GPv2Order for GPv2Order.Data;
    using CoWTWAPLib for CoWTWAPLib.TWAPConfig;
    using CoWTWAPLib for CoWTWAPLib.TWAPState;

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

        HookableAssetAcquisitionStorageStruct storage $ = _updateGlobal();

        HookableAssetAcquisitionStorageLayout.User storage user = _updateUser(msg.sender);

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
            HookableAssetAcquisitionStorageLayout.User storage userFromStruct = _updateUser(_from);
            userFromStruct.assets -= _amount;
        }

        if (!_isContract(_to) && _to != address(0)) {
            HookableAssetAcquisitionStorageLayout.User storage userToStruct = _updateUser(_to);
            userToStruct.assets += _amount;
        }

        if (_to == address(this)) {
            HookableAssetAcquisitionStorageStruct storage $ = _getHookableAssetAcquisitionStorageLocation();
            $.yieldedAssets += _amount;
        }

        if (_from == address(this)) {
            HookableAssetAcquisitionStorageStruct storage $ = _getHookableAssetAcquisitionStorageLocation();
            $.yieldedAssets -= _amount;
        }

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

    function getHookingAsset() public view returns (address) {
        return _getHookableAssetAcquisitionStorageLocation().hookingAsset;
    }

    function getTargetAsset() public view returns (address) {
        return _getHookableAssetAcquisitionStorageLocation().targetAsset;
    }

    function getYieldedAssets() public view returns (uint256) {
        return _getHookableAssetAcquisitionStorageLocation().yieldedAssets;
    }

    function getActiveTWAPId() public view returns (bytes32) {
        return _getHookableAssetAcquisitionStorageLocation().activeTWAPId;
    }

    function getActiveTWAPStatus()
        public
        view
        returns (uint256 totalAmount, uint256 numParts, uint256 currentPart, uint256 amountSold, uint256 amountBought)
    {
        HookableAssetAcquisitionStorageStruct storage $ = _getHookableAssetAcquisitionStorageLocation();
        CoWTWAPLib.TWAPState storage state = $.twapStates[$.activeTWAPId];
        CoWTWAPLib.TWAPConfig storage config = $.twapConfigs[$.activeTWAPId];

        totalAmount = config.totalAmount;
        numParts = config.numberOfParts;
        currentPart = state.currentPart;
        amountSold = state.amountSold;
        amountBought = state.amountBought;
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

    function cowSwapTWAP() public {
        _cowSwapTWAP();
    }

    /**
     * @notice Implementation of IConditionalOrder for TWAP orders
     */
    function getTradeableOrder(
        address owner,
        address sender,
        bytes calldata staticInput,
        bytes calldata offchainData
    ) external view returns (GPv2Order.Data memory order) {
        HookableAssetAcquisitionStorageStruct storage $ = _getHookableAssetAcquisitionStorageLocation();

        // Decode TWAP ID from static input
        bytes32 twapId = abi.decode(staticInput, (bytes32));

        CoWTWAPLib.TWAPConfig memory config = $.twapConfigs[twapId];
        CoWTWAPLib.TWAPState memory state = $.twapStates[twapId];

        // Check if next part is ready
        (bool ready, uint256 partNumber) = CoWTWAPLib.isNextPartReady(config, state);
        require(ready, "TWAP part not ready");

        // Create order for this part
        CoWTWAPLib.TWAPOrderParams memory params = CoWTWAPLib.TWAPOrderParams({
            config: config,
            state: state,
            receiver: address(this),
            appData: bytes32(0)
        });

        (order, ) = CoWTWAPLib.createPartOrder(params);
    }

    /**
     * @notice EIP-1271 signature validation for TWAP orders
     */
    function isValidSignature(bytes32 orderHash, bytes memory signature) external view returns (bytes4) {
        HookableAssetAcquisitionStorageStruct storage $ = _getHookableAssetAcquisitionStorageLocation();

        if (signature.length < 32) return bytes4(0);

        bytes32 twapId = abi.decode(signature, (bytes32));

        CoWTWAPLib.TWAPConfig memory config = $.twapConfigs[twapId];
        CoWTWAPLib.TWAPState memory state = $.twapStates[twapId];

        if (!config.isActive) return bytes4(0);

        // Verify this is a valid TWAP part order
        (bool ready, ) = CoWTWAPLib.isNextPartReady(config, state);
        if (!ready) return bytes4(0);

        // Reconstruct expected order
        try this.getTradeableOrder(address(this), msg.sender, abi.encode(twapId), "") returns (
            GPv2Order.Data memory expectedOrder
        ) {
            bytes32 expectedHash = GPv2Order.hash(expectedOrder, CoWTWAPLib.DOMAIN_SEPARATOR);

            if (orderHash == expectedHash) {
                return CoWTWAPLib.EIP1271_MAGIC_VALUE;
            }
        } catch {
            return bytes4(0);
        }

        return bytes4(0);
    }

    /**
     * @notice Called after each TWAP part execution
     * @param twapId The TWAP identifier
     * @param amountSold Amount sold in this part
     * @param amountBought Amount bought (USDC) in this part
     */
    function recordTWAPExecution(bytes32 twapId, uint256 amountSold, uint256 amountBought) external {
        HookableAssetAcquisitionStorageStruct storage $ = _getHookableAssetAcquisitionStorageLocation();

        // Record the execution
        $.twapStates[twapId].recordPartExecution(amountSold, amountBought);

        // Check if TWAP is complete
        if (CoWTWAPLib.isTWAPComplete($.twapConfigs[twapId], $.twapStates[twapId])) {
            $.twapConfigs[twapId].completeTWAP($.twapStates[twapId]);
            // $.activeTWAPId = bytes32(0);
        }
    }

    /**
     * @notice Verify if a given discrete order is valid for TWAP execution
     * @dev Required by IConditionalOrder interface - reverts if order is invalid
     * @param owner The contract that owns the order (should be this contract)
     * @param sender The msg.sender of the transaction
     * @param _hash The hash of the order
     * @param domainSeparator The domain separator used to sign the order
     * @param ctx The context key of the order
     * @param staticInput The TWAP ID encoded as bytes
     * @param offchainInput Dynamic off-chain input (not used for TWAP)
     * @param order The GPv2Order.Data to be verified
     */
    function verify(
        address owner,
        address sender,
        bytes32 _hash,
        bytes32 domainSeparator,
        bytes32 ctx,
        bytes calldata staticInput,
        bytes calldata offchainInput,
        GPv2Order.Data calldata order
    ) external view override {
        // Verify owner is this contract
        require(owner == address(this), "Invalid owner");

        // Verify domain separator matches
        require(domainSeparator == CoWTWAPLib.DOMAIN_SEPARATOR, "Invalid domain separator");

        HookableAssetAcquisitionStorageStruct storage $ = _getHookableAssetAcquisitionStorageLocation();

        // Decode TWAP ID from static input
        bytes32 twapId;
        if (staticInput.length >= 32) {
            twapId = abi.decode(staticInput, (bytes32));
        } else {
            revert("Invalid static input");
        }

        // Verify TWAP exists and is active
        CoWTWAPLib.TWAPConfig memory config = $.twapConfigs[twapId];
        CoWTWAPLib.TWAPState memory state = $.twapStates[twapId];

        require(config.isActive, "TWAP not active");
        require(twapId == $.activeTWAPId, "TWAP not current");

        {
            // Verify timing - next part should be ready
            (bool ready, uint256 expectedPartNumber) = CoWTWAPLib.isNextPartReady(config, state);
            require(ready, "Next TWAP part not ready");
        }

        // Verify we haven't completed all parts
        require(state.currentPart < config.numberOfParts, "TWAP already completed");

        // Verify order parameters match expected TWAP configuration
        require(address(order.sellToken) == config.sellToken, "Sell token mismatch");
        require(address(order.buyToken) == config.buyToken, "Buy token mismatch");
        require(order.receiver == address(this), "Receiver must be this contract");
        require(order.kind == GPv2Order.KIND_SELL, "Must be sell order");

        // Calculate expected sell amount for this part
        uint256 remainingAmount = config.totalAmount - state.amountSold;
        uint256 expectedSellAmount = remainingAmount / (config.numberOfParts - state.currentPart);

        // For last part, sell everything remaining
        if (state.currentPart == config.numberOfParts - 1) {
            expectedSellAmount = remainingAmount;
        }

        // Verify sell amount matches expected
        require(order.sellAmount == expectedSellAmount, "Sell amount mismatch");

        // Verify buy amount meets minimum requirements
        if (config.minPartLimit > 0) {
            require(order.buyAmount >= config.minPartLimit, "Buy amount below minimum");
        }

        // Verify order validity window is reasonable
        require(order.validTo > block.timestamp, "Order already expired");
        require(
            order.validTo <= block.timestamp + 3600, // Max 1 hour validity
            "Order validity too long"
        );

        // Verify order hash matches
        bytes32 expectedHash = order.hash(domainSeparator);
        require(_hash == expectedHash, "Order hash mismatch");

        // Verify token balances are sufficient
        uint256 balance = IERC20(config.sellToken).balanceOf(address(this));
        require(balance >= order.sellAmount, "Insufficient balance");

        // Verify approvals are in place
        uint256 allowance = IERC20(config.sellToken).allowance(address(this), CoWTWAPLib.COW_VAULT_RELAYER);
        require(allowance >= order.sellAmount, "Insufficient approval");

        // Additional sanity checks
        require(order.feeAmount == 0, "Fee should be zero");
        require(!order.partiallyFillable, "Should not be partially fillable");
        require(order.sellTokenBalance == GPv2Order.BALANCE_ERC20, "Invalid sell token balance flag");
        require(order.buyTokenBalance == GPv2Order.BALANCE_ERC20, "Invalid buy token balance flag");

        // If we reach here, order is valid
        // Function will not revert, indicating verification passed
    }

    function _updateUser(
        address _user
    ) internal returns (HookableAssetAcquisitionStorageLayout.User storage userStruct) {
        HookableAssetAcquisitionStorageStruct storage $ = _getHookableAssetAcquisitionStorageLocation();

        userStruct = $.users[_user];

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

    function _cowSwapTWAP() internal {
        HookableAssetAcquisitionStorageStruct storage $ = _getHookableAssetAcquisitionStorageLocation();

        console.log("yielded assets", $.yieldedAssets);

        require($.yieldedAssets > 0, "No yield to swap");
        require($.activeTWAPId == bytes32(0), "TWAP already active");

        uint256 intermediateUSDC = _swapYieldToUSDC();

        console.log("intermediate", intermediateUSDC);

        // Generate unique TWAP ID
        bytes32 twapId = keccak256(abi.encode(address(this), USDC, $.targetAsset, block.timestamp));

        // Create TWAP for hookingAsset -> USDC
        $.twapConfigs[twapId].createTWAP(
            USDC,
            $.targetAsset,
            intermediateUSDC,
            10, // number of parts
            600 // part duration
        );

        // Initialize state
        $.twapStates[twapId] = CoWTWAPLib.TWAPState({
            currentPart: 0,
            lastPartExecuted: 0,
            amountSold: 0,
            amountBought: 0
        });

        $.activeTWAPId = twapId;

        // Register with ComposableCoW
        CoWTWAPLib.registerTWAPWithComposableCoW(address(this), twapId);
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
