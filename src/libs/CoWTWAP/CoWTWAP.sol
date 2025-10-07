// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { console } from "forge-std/console.sol";

import {
    IERC20
} from "../../../lib/common/lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IConditionalOrder } from "./IConditionalOrder.sol";
import { GPv2Order } from "./GPv2Order.sol";

/**
 * @title CoWTWAPLib
 * @notice Library for creating TWAP orders on CoW Protocol
 * @dev Splits large trades into smaller time-weighted chunks for better execution
 */
library CoWTWAPLib {
    using GPv2Order for GPv2Order.Data;

    // ===== Constants =====
    address public constant COW_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address public constant COW_VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;
    address public constant COMPOSABLE_COW = 0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74;
    bytes32 public constant DOMAIN_SEPARATOR = 0xc078f884a2676e1345748b1feace7b0abee5d00ecadb6e574dcdd109a63e8943;
    bytes4 public constant EIP1271_MAGIC_VALUE = 0x1626ba7e;

    // ===== Structs =====

    /**
     * @notice Configuration for a TWAP order
     * @param sellToken Token to sell
     * @param buyToken Token to buy
     * @param totalAmount Total amount to sell over all intervals
     * @param numberOfParts Number of parts to split the order into
     * @param partDuration Duration of each part in seconds
     * @param startTime When the TWAP should start (0 for immediate)
     * @param minPartLimit Minimum buy amount per part (slippage protection)
     * @param isActive Whether this TWAP is currently active
     */
    struct TWAPConfig {
        address sellToken;
        address buyToken;
        uint256 totalAmount;
        uint256 numberOfParts;
        uint256 partDuration;
        uint256 startTime;
        uint256 minPartLimit;
        bool isActive;
    }

    /**
     * @notice Current state of TWAP execution
     * @param currentPart Which part we're currently on (0-indexed)
     * @param lastPartExecuted Timestamp when last part was executed
     * @param amountSold Total amount sold so far
     * @param amountBought Total amount bought so far
     */
    struct TWAPState {
        uint256 currentPart;
        uint256 lastPartExecuted;
        uint256 amountSold;
        uint256 amountBought;
    }

    /**
     * @notice Parameters for creating a single TWAP part order
     */
    struct TWAPOrderParams {
        TWAPConfig config;
        TWAPState state;
        address receiver;
        bytes32 appData;
    }

    // ===== Events =====
    event TWAPCreated(
        address indexed sellToken,
        address indexed buyToken,
        uint256 totalAmount,
        uint256 numberOfParts,
        uint256 partDuration
    );

    event TWAPPartExecuted(uint256 indexed partNumber, uint256 amountSold, uint256 amountBought);

    event TWAPCompleted(uint256 totalSold, uint256 totalBought, uint256 numberOfParts);

    // ===== Main Functions =====

    /**
     * @notice Initialize a new TWAP configuration
     * @param config Storage pointer to TWAPConfig
     * @param sellToken Token to sell
     * @param buyToken Token to buy
     * @param totalAmount Total amount to sell
     * @param numberOfParts Number of intervals
     * @param partDuration Time between parts in seconds
     */
    function createTWAP(
        TWAPConfig storage config,
        address sellToken,
        address buyToken,
        uint256 totalAmount,
        uint256 numberOfParts,
        uint256 partDuration
    ) internal {
        require(numberOfParts > 0, "TWAP: Invalid parts");
        require(totalAmount > 0, "TWAP: Invalid amount");
        require(partDuration > 0, "TWAP: Invalid duration");

        config.sellToken = sellToken;
        config.buyToken = buyToken;
        config.totalAmount = totalAmount;
        config.numberOfParts = numberOfParts;
        config.partDuration = partDuration;
        config.startTime = block.timestamp;
        config.minPartLimit = 0; // Can be set separately
        config.isActive = true;

        // Approve CoW vault for selling
        IERC20(sellToken).approve(COW_VAULT_RELAYER, totalAmount);

        emit TWAPCreated(sellToken, buyToken, totalAmount, numberOfParts, partDuration);
    }

    /**
     * @notice Check if the next TWAP part should be executed
     * @param config The TWAP configuration
     * @param state Current TWAP state
     * @return ready Whether next part is ready
     * @return partNumber Which part number would execute
     */
    function isNextPartReady(
        TWAPConfig memory config,
        TWAPState memory state
    ) internal view returns (bool ready, uint256 partNumber) {
        if (!config.isActive) return (false, 0);
        if (state.currentPart >= config.numberOfParts) return (false, 0);

        uint256 timeSinceStart = block.timestamp - config.startTime;
        uint256 expectedPart = timeSinceStart / config.partDuration;

        if (expectedPart > state.currentPart) {
            // Cap at the total number of parts
            partNumber = expectedPart >= config.numberOfParts ? config.numberOfParts - 1 : expectedPart;
            ready = true;
        } else {
            ready = false;
            partNumber = state.currentPart;
        }
    }

    /**
     * @notice Create a CoW order for the next TWAP part
     * @param params TWAP order parameters
     * @return order The GPv2 order for this part
     * @return partAmount Amount to sell in this part
     */
    function createPartOrder(
        TWAPOrderParams memory params
    ) internal view returns (GPv2Order.Data memory order, uint256 partAmount) {
        require(params.config.isActive, "TWAP: Not active");
        require(params.state.currentPart < params.config.numberOfParts, "TWAP: Completed");

        // Calculate amount for this part
        uint256 remainingAmount = params.config.totalAmount - params.state.amountSold;
        uint256 remainingParts = params.config.numberOfParts - params.state.currentPart;

        // Divide remaining amount equally among remaining parts
        partAmount = remainingAmount / remainingParts;

        // For the last part, sell everything remaining
        if (params.state.currentPart == params.config.numberOfParts - 1) {
            partAmount = remainingAmount;
        }

        // Create the order
        order = GPv2Order.Data({
            sellToken: IERC20(params.config.sellToken),
            buyToken: IERC20(params.config.buyToken),
            receiver: params.receiver,
            sellAmount: partAmount,
            buyAmount: params.config.minPartLimit,
            validTo: uint32(block.timestamp + 600), // 10 minute validity
            appData: params.appData,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }

    /**
     * @notice Update state after a TWAP part is executed
     * @param state Storage pointer to TWAPState
     * @param amountSold Amount sold in this part
     * @param amountBought Amount bought in this part
     */
    function recordPartExecution(TWAPState storage state, uint256 amountSold, uint256 amountBought) internal {
        state.currentPart++;
        state.lastPartExecuted = block.timestamp;
        state.amountSold += amountSold;
        state.amountBought += amountBought;

        emit TWAPPartExecuted(state.currentPart, amountSold, amountBought);
    }

    /**
     * @notice Check if TWAP is complete
     * @param config The TWAP configuration
     * @param state Current TWAP state
     * @return complete Whether all parts have executed
     */
    function isTWAPComplete(TWAPConfig memory config, TWAPState memory state) internal pure returns (bool complete) {
        return state.currentPart >= config.numberOfParts || state.amountSold >= config.totalAmount;
    }

    /**
     * @notice Complete a TWAP and clean up
     * @param config Storage pointer to TWAPConfig
     * @param state The final TWAP state
     */
    function completeTWAP(TWAPConfig storage config, TWAPState memory state) internal {
        config.isActive = false;

        // Revoke any remaining approval
        if (state.amountSold < config.totalAmount) {
            IERC20(config.sellToken).approve(COW_VAULT_RELAYER, 0);
        }

        emit TWAPCompleted(state.amountSold, state.amountBought, state.currentPart);
    }

    /**
     * @notice Calculate minimum buy amount for a part based on oracle price
     * @param sellAmount Amount being sold in this part
     * @param spotPrice Current spot price (buyToken per sellToken, scaled by 1e18)
     * @param maxSlippageBps Maximum slippage in basis points
     * @return minBuyAmount Minimum acceptable buy amount
     */
    function calculateMinBuyAmount(
        uint256 sellAmount,
        uint256 spotPrice,
        uint256 maxSlippageBps
    ) internal pure returns (uint256 minBuyAmount) {
        uint256 expectedBuyAmount = (sellAmount * spotPrice) / 1e18;
        minBuyAmount = (expectedBuyAmount * (10000 - maxSlippageBps)) / 10000;
    }

    /**
     * @notice Register TWAP handler with ComposableCoW
     * @param handler Address of the handler contract
     * @param twapId Unique identifier for this TWAP
     */
    function registerTWAPWithComposableCoW(address handler, bytes32 twapId) internal {
        IComposableCoW(COMPOSABLE_COW).create(
            IComposableCoW.ConditionalOrderParams(
                IConditionalOrder(handler),
                twapId, // Use TWAP ID as salt
                abi.encode(twapId) // Pass TWAP ID as static input
            ),
            true
        );
    }
}

// Interface for ComposableCoW
interface IComposableCoW {
    struct ConditionalOrderParams {
        IConditionalOrder handler; // Your contract address
        bytes32 salt; // Unique identifier
        bytes staticInput; // Your TWAP config
    }
    function create(ConditionalOrderParams memory params, bool dipatch) external;
}
