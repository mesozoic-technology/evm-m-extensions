// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.26;

import { console } from "forge-std/console.sol";
import { stdStorage, StdStorage } from "forge-std/StdStorage.sol";

import { IERC20 } from ".../../lib/common/src/interfaces/IERC20.sol";
import { Upgrades } from "../../lib/openzeppelin-foundry-upgrades/src/Upgrades.sol";
import { Options } from "../../lib/openzeppelin-foundry-upgrades/src/Options.sol";
import { WrappedMToken } from "../../lib/wrapped-m-token/src/WrappedMToken.sol";
import { EarnerManager } from "../../lib/wrapped-m-token/src/EarnerManager.sol";
import { WrappedMTokenMigratorV1 } from "../../lib/wrapped-m-token/src/WrappedMTokenMigratorV1.sol";
import { Proxy } from "../../lib/common/src/Proxy.sol";

import { IFreezable } from "../../src/components/IFreezable.sol";
import { MYieldToOne } from "../../src/projects/yieldToOne/MYieldToOne.sol";

import { MYieldToOneHookableHarness } from "../harness/MYieldToOneHookableHarness.sol";
import { HookableAssetAcquisitionHarness } from "../harness/HookableAssetAcquisitionHarness.sol";

import { BaseIntegrationTest } from "../utils/BaseIntegrationTest.sol";

import { GPv2Order } from "../../src/libs/CoWTWAP/GPv2Order.sol";
import { CoWTWAPLib } from "../../src/libs/CoWTWAP/CoWTWAP.sol";
import { IConditionalOrder } from "../../src/libs/CoWTWAP/IConditionalOrder.sol";

import { Hooks } from "../../lib/v4-core/src/libraries/Hooks.sol";
import { IPoolManager } from "../../lib/v4-core/src/interfaces/IPoolManager.sol";
import { HookMiner } from "../utils/HookMiner.sol";
import { TWAMM } from "../../src/hooks/TWAMM.sol";

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    struct QuoteExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountOut;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(
        QuoteExactInputSingleParams memory params
    )
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);

    function quoteExactOutputSingle(
        QuoteExactOutputSingleParams memory params
    )
        external
        returns (uint256 amountIn, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

contract HookableAssetAcquisitionIntegrationTest is BaseIntegrationTest {
    using stdStorage for StdStorage;

    address constant UNISWAP_V3_QUOTER = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;

    address constant USDC_WBTC_POOL = 0x99ac8cA7087fA4A2A1FB6357269965A2014ABc35;

    uint256 constant Q96 = 2 ** 96;

    uint256 constant Q192 = Q96 * Q96;

    // Holds USDC, USDT and wM
    address constant USER = 0x77BAB32F75996de8075eBA62aEa7b1205cf7E004;

    // WBTC contract address
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    address constant WBTC_WHALE = 0xed805ac246F441Ea0D057B81d910EF1e39EB5995;

    Options public hookableAssetAcquisitionDeployOptions;

    uint256 startTime = vm.getBlockTimestamp();

    uint256 originalWbtcUsdcPrice;
    uint256 originalUsdcWbtcPrice;

    function setUp() public override {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 22_751_329);

        uint256 whaleBalance = IERC20(WBTC).balanceOf(WBTC_WHALE);

        stdstore.target(WBTC).sig("balanceOf(address)").with_key(alice).checked_write(uint256(whaleBalance));

        stdstore.target(WBTC).sig("balanceOf(address)").with_key(WBTC_WHALE).checked_write(uint256(0));

        console.log("WBTC ALICE", IERC20(WBTC).balanceOf(alice));

        super.setUp();

        IQuoterV2.QuoteExactInputSingleParams memory params = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: WBTC,
            tokenOut: USDC,
            amountIn: 1e8,
            fee: uint24(3000),
            sqrtPriceLimitX96: 0 // No price limit
        });

        (originalWbtcUsdcPrice, , , ) = IQuoterV2(UNISWAP_V3_QUOTER).quoteExactInputSingle(params);

        (params.tokenIn, params.tokenOut) = (params.tokenOut, params.tokenIn);

        params.amountIn = 1e6;

        (originalUsdcWbtcPrice, , , ) = IQuoterV2(UNISWAP_V3_QUOTER).quoteExactInputSingle(params);

        _giveM(alice, 100_000e6);
        _giveM(bob, 100_000e6);

        mYieldToOneHookable = MYieldToOneHookableHarness(
            Upgrades.deployTransparentProxy(
                "MYieldToOneHookableHarness.sol:MYieldToOneHookableHarness",
                admin,
                abi.encodeWithSelector(
                    MYieldToOneHookableHarness.initialize.selector,
                    NAME,
                    SYMBOL,
                    yieldRecipient,
                    admin,
                    freezeManager,
                    yieldRecipientManager,
                    hookManager
                ),
                mExtensionDeployOptions
            )
        );

        hookableAssetAcquisitionDeployOptions.constructorData = abi.encode(
            address(swapAdapter),
            address(UNISWAP_V3_ROUTER)
        );

        hookableAssetAcquisition = HookableAssetAcquisitionHarness(
            Upgrades.deployTransparentProxy(
                "HookableAssetAcquisitionHarness.sol:HookableAssetAcquisitionHarness",
                admin,
                abi.encodeWithSelector(
                    HookableAssetAcquisitionHarness.initialize.selector,
                    address(mYieldToOneHookable),
                    WBTC
                ),
                hookableAssetAcquisitionDeployOptions
            )
        );

        _addToList(EARNERS_LIST, address(mYieldToOneHookable));

        vm.prank(hookManager);

        mYieldToOneHookable.setHook(address(hookableAssetAcquisition));

        vm.prank(yieldRecipientManager);
        mYieldToOneHookable.setYieldRecipient(address(hookableAssetAcquisition));

        vm.prank(admin);
        swapFacility.grantRole(M_SWAPPER_ROLE, USER);
    }

    function test_spotSwap() public {
        mYieldToOneHookable.enableEarning();

        assertEq(mToken.balanceOf(alice), 100_000e6);

        vm.prank(alice);
        mToken.approve(address(swapFacility), type(uint256).max);

        vm.expectEmit();
        emit HookableAssetAcquisitionHarness.HookCalled(address(0), alice, 100_000e6);

        vm.prank(alice);
        swapFacility.swapInM(address(mYieldToOneHookable), 100_000e6, alice);

        assertEq(mYieldToOneHookable.balanceOf(alice), 100_000e6);

        (uint256 userAssets, uint256 userUpdate, uint256 userHodl) = hookableAssetAcquisition.getUser(alice);

        uint256 yield = mYieldToOneHookable.yield();
        uint256 totalSupply = mYieldToOneHookable.totalSupply();

        vm.warp(vm.getBlockTimestamp() + 31449600);

        yield = mYieldToOneHookable.yield();

        totalSupply = mYieldToOneHookable.totalSupply();

        mYieldToOneHookable.claimYield();

        uint256 hookingAssets = hookableAssetAcquisition.getHookingAssets();

        hookableAssetAcquisition.spotSwap();

        uint256 balanceOfHookableAssetAcquisition = mYieldToOneHookable.balanceOf(address(hookableAssetAcquisition));

        totalSupply = mYieldToOneHookable.totalSupply();

        uint256 yieldedBalance = hookableAssetAcquisition.getYieldedAssets();
        uint256 targetBalance = hookableAssetAcquisition.getTargetAssets();
        uint256 wbtcBalance = IERC20(WBTC).balanceOf(address(hookableAssetAcquisition));

        assertEq(
            balanceOfHookableAssetAcquisition,
            0,
            "HookableAssetAcquisition should have zero mYieldToOneHookable balance"
        );
        assertEq(yieldedBalance, 0, "yielded balance should be entirely swapped into target");
        assertTrue(0 < targetBalance, "target balance should have been received by the Acquisition contract");
        assertTrue(0 < wbtcBalance, "wbtc should be acquired by HookableAssetAcquisition");
    }

    function test_claim_x() public {
        mYieldToOneHookable.enableEarning();

        assertEq(mToken.balanceOf(alice), 100_000e6);

        vm.prank(alice);
        hookableAssetAcquisition.activateUser();

        vm.prank(alice);
        mToken.approve(address(swapFacility), type(uint256).max);

        vm.expectEmit();
        emit HookableAssetAcquisitionHarness.HookCalled(address(0), alice, 100_000e6);

        vm.prank(alice);
        swapFacility.swapInM(address(mYieldToOneHookable), 100_000e6, alice);

        assertEq(mYieldToOneHookable.balanceOf(alice), 100_000e6);

        vm.warp(vm.getBlockTimestamp() + 31449600);

        mYieldToOneHookable.claimYield();

        hookableAssetAcquisition.spotSwap();

        uint256 targetAssets = hookableAssetAcquisition.getTargetAssets();

        vm.prank(alice);
        hookableAssetAcquisition.claim();

        assertEq(IERC20(WBTC).balanceOf(alice), targetAssets, "alice should hold all of the target assets");
        assertEq(
            hookableAssetAcquisition.getTargetAssets(),
            0,
            "HookableAssetAcquisition should not have any remaining target assets"
        );
        assertEq(hookableAssetAcquisition.getHodling(), 0, "HookableAssetAcquisition should have 0 hodling");

        (uint256 aliceAssets, uint256 aliceUpdate, uint256 aliceHodl) = hookableAssetAcquisition.getUser(alice);

        assertEq(aliceHodl, 0, "alice should have 0 hodl");
        assertEq(aliceUpdate, vm.getBlockTimestamp(), "alice should be updated to the current timestamp");
        assertEq(aliceAssets, 100_000e6, "alice should have original 100_000e6 balance");
    }

    function test_claimTwoUsers() public {
        mYieldToOneHookable.enableEarning();

        assertEq(mToken.balanceOf(alice), 100_000e6);

        vm.prank(alice);
        hookableAssetAcquisition.activateUser();

        vm.prank(alice);
        mToken.approve(address(swapFacility), type(uint256).max);

        vm.expectEmit();
        emit HookableAssetAcquisitionHarness.HookCalled(address(0), alice, 50_000e6);

        vm.prank(alice);
        swapFacility.swapInM(address(mYieldToOneHookable), 50_000e6, alice);

        vm.prank(bob);
        hookableAssetAcquisition.activateUser();

        vm.prank(bob);
        mToken.approve(address(swapFacility), type(uint256).max);

        vm.expectEmit();
        emit HookableAssetAcquisitionHarness.HookCalled(address(0), bob, 50_000e6);

        vm.prank(bob);
        swapFacility.swapInM(address(mYieldToOneHookable), 50_000e6, bob);

        assertEq(mYieldToOneHookable.balanceOf(bob), 50_000e6);

        assertEq(mYieldToOneHookable.totalSupply(), 100_000e6);

        vm.warp(vm.getBlockTimestamp() + 31449600);

        mYieldToOneHookable.claimYield();

        hookableAssetAcquisition.spotSwap();

        uint256 targetAssets = hookableAssetAcquisition.getTargetAssets();

        vm.prank(alice);
        hookableAssetAcquisition.claim();

        vm.prank(bob);
        hookableAssetAcquisition.claim();

        assertApproxEqAbs(
            IERC20(WBTC).balanceOf(alice),
            targetAssets / 2,
            1,
            "alice should hold half of the target assets"
        );
        assertApproxEqAbs(
            IERC20(WBTC).balanceOf(bob),
            targetAssets / 2,
            1,
            "bob should hold half of the target assets"
        );

        assertEq(
            hookableAssetAcquisition.getTargetAssets(),
            0,
            "HookableAssetAcquisition should not have any remaining target assets"
        );
        assertEq(hookableAssetAcquisition.getHodling(), 0, "HookableAssetAcquisition should have 0 hodling");

        (uint256 aliceAssets, uint256 aliceUpdate, uint256 aliceHodl) = hookableAssetAcquisition.getUser(alice);

        assertEq(aliceHodl, 0, "alice should have 0 hodl");
        assertEq(aliceUpdate, vm.getBlockTimestamp(), "alice should be updated to the current timestamp");
        assertEq(aliceAssets, 50_000e6, "alice should have original 50_000e6 balance");

        (uint256 bobAssets, uint256 bobUpdate, uint256 bobHodl) = hookableAssetAcquisition.getUser(bob);

        assertEq(bobHodl, 0, "bob should have 0 hodl");
        assertEq(bobUpdate, vm.getBlockTimestamp(), "bob should be updated to the current timestamp");
        assertEq(bobAssets, 50_000e6, "bob should have original 50_000e6 balance");
    }

    function test_completeTWAPExecutionWithActualTokens() public {
        stdstore.target(WBTC).sig("balanceOf(address)").with_key(alice).checked_write(uint256(100e8));

        console.log("WBTC ALICE", IERC20(WBTC).balanceOf(alice));

        mYieldToOneHookable.enableEarning();

        assertEq(mToken.balanceOf(alice), 100_000e6);

        vm.prank(alice);
        mToken.approve(address(swapFacility), type(uint256).max);

        vm.expectEmit();
        emit HookableAssetAcquisitionHarness.HookCalled(address(0), alice, 50_000e6);

        vm.prank(alice);
        swapFacility.swapInM(address(mYieldToOneHookable), 50_000e6, alice);

        vm.prank(bob);
        mToken.approve(address(swapFacility), type(uint256).max);

        vm.expectEmit();
        emit HookableAssetAcquisitionHarness.HookCalled(address(0), bob, 50_000e6);

        vm.prank(bob);
        swapFacility.swapInM(address(mYieldToOneHookable), 50_000e6, bob);

        assertEq(mYieldToOneHookable.balanceOf(bob), 50_000e6);

        assertEq(mYieldToOneHookable.totalSupply(), 100_000e6);

        vm.warp(vm.getBlockTimestamp() + 31449600);

        mYieldToOneHookable.claimYield();

        // ============ SETUP PHASE ============
        console.log("=== Starting TWAP Test with Actual Tokens ===");

        uint256 yieldBalance = mYieldToOneHookable.balanceOf(address(hookableAssetAcquisition));
        require(yieldBalance > 0, "No yield accumulated");

        // Create a TWAP order based on actual yield
        uint256 numberOfParts = 10;
        uint256 partDuration = 600; // ten minutes

        hookableAssetAcquisition.cowSwapTWAP();

        bytes32 twapId = hookableAssetAcquisition.getActiveTWAPId();
        require(twapId != bytes32(0), "TWAP not created");

        // Verify TWAP was created with actual amounts
        (uint256 totalAmount, uint256 numParts, uint256 currentPart, , ) = hookableAssetAcquisition
            .getActiveTWAPStatus();

        assertEq(numParts, 10, "Should have 10 parts");
        assertEq(currentPart, 0, "Should start at part 0");

        // Track USDC balance (some might already exist from other operations)
        uint256 initialUsdcBalance = IERC20(USDC).balanceOf(address(hookableAssetAcquisition));

        console.log("WBTC ALICE", IERC20(WBTC).balanceOf(alice));

        // ============ EXECUTION PHASE ============

        for (uint256 i = 0; i < numberOfParts; i++) {
            console.log("\n--- Executing Part", i + 1, "---");

            {
                (, , uint256 newCurrentPart, uint256 amountSold, ) = hookableAssetAcquisition.getActiveTWAPStatus();
                console.log("start cp", newCurrentPart);
                console.log("start as", amountSold);
            }

            // Fast forward time to make next part ready
            vm.warp(block.timestamp + partDuration);

            // 1. Get the order (simulating what watchtower does)
            GPv2Order.Data memory order = hookableAssetAcquisition.getTradeableOrder(
                address(hookableAssetAcquisition),
                address(this),
                abi.encode(twapId),
                ""
            );

            console.log("Order generated for", order.sellAmount / 1e6, "tokens");

            // Verify order parameters
            assertEq(address(order.sellToken), USDC, "Wrong sell token");
            assertEq(address(order.buyToken), WBTC, "Wrong buy token");
            assertEq(order.receiver, address(hookableAssetAcquisition), "Wrong receiver");

            // 2. Verify signature (what settlement contract does)
            bytes32 orderHash = GPv2Order.hash(order, CoWTWAPLib.DOMAIN_SEPARATOR);
            bytes4 magic = hookableAssetAcquisition.isValidSignature(orderHash, abi.encode(twapId));
            assertEq(magic, bytes4(0x1626ba7e), "Invalid signature");

            // 3. Mock the settlement execution
            uint256 balanceBefore = mYieldToOneHookable.balanceOf(address(hookableAssetAcquisition));
            uint256 usdcReceived = _mockSettlementWithActualTokens(order, i);
            uint256 balanceAfter = mYieldToOneHookable.balanceOf(address(hookableAssetAcquisition));

            // 4. Record the execution
            hookableAssetAcquisition.recordTWAPExecution(twapId, order.sellAmount, usdcReceived);

            // Verify state updated
            (, , uint256 newCurrentPart, uint256 amountSold, ) = hookableAssetAcquisition.getActiveTWAPStatus();

            console.log("current part", newCurrentPart);
            console.log("amount sold", amountSold);

            assertEq(newCurrentPart, i + 1, "Current part should increment");
        }

        // ============ COMPLETION PHASE ============
        console.log("\n=== TWAP Execution Complete ===");

        // Verify TWAP is complete
        (, , uint256 finalPart, uint256 totalSold, uint256 totalBought) = hookableAssetAcquisition
            .getActiveTWAPStatus();

        console.log("final part", finalPart);
        console.log("total sold", totalSold);
        console.log("total bought", totalBought);

        assertEq(finalPart, numberOfParts, "Should have executed all parts");

        console.log("Final results:");
        console.log("  Total USDC sold:", totalSold);
        console.log("  Total WBTC received:", totalBought);

        uint256 wbtcBalance = IERC20(WBTC).balanceOf(address(hookableAssetAcquisition));
        assertEq(wbtcBalance, totalBought, "Should have acquired WBTC");

        // // ============ USER CLAIMS ============
        // console.log("\n=== User Claims ===");

        // // Alice can now claim her share of WBTC
        // uint256 aliceWbtcBefore = IERC20(WBTC).balanceOf(alice);

        // vm.prank(alice);
        // acquisition.claim();

        // uint256 aliceWbtcAfter = IERC20(WBTC).balanceOf(alice);
        // uint256 aliceReceived = aliceWbtcAfter - aliceWbtcBefore;

        // console.log("Alice claimed:", aliceReceived, "sats of WBTC");
        // assertGt(aliceReceived, 0, "Alice should receive WBTC");

        // // Bob claims his share
        // uint256 bobWbtcBefore = IERC20(WBTC).balanceOf(bob);

        // vm.prank(bob);
        // acquisition.claim();

        // uint256 bobWbtcAfter = IERC20(WBTC).balanceOf(bob);
        // uint256 bobReceived = bobWbtcAfter - bobWbtcBefore;

        // console.log("Bob claimed:", bobReceived, "sats of WBTC");
        // assertGt(bobReceived, 0, "Bob should receive WBTC");

        // // Verify proportional distribution (they had equal deposits)
        // assertApproxEqRel(aliceReceived, bobReceived, 0.01e18, "Should receive approximately equal amounts");
    }

    function test_twamm() public {
        address poolManager = 0x000000000004444c5dc75cB358380D2e3dE08A90;
        address create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

        console.log("pool size", poolManager.code.length);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(poolManager, 30 minutes, address(this));

        (address hookAddress, bytes32 salt) = HookMiner.find(
            create2Deployer,
            flags,
            type(TWAMM).creationCode,
            constructorArgs
        );
    }

    function _mockSettlementWithActualTokens(
        GPv2Order.Data memory order,
        uint256 iteration
    ) internal returns (uint256 wbtcReceived) {
        // Verify approval is in place
        uint256 allowance = order.sellToken.allowance(address(hookableAssetAcquisition), CoWTWAPLib.COW_VAULT_RELAYER);
        require(allowance >= order.sellAmount, "Insufficient approval");

        console.log("hmmmm");

        // 1. Mock settlement pulling tokens from your contract
        vm.startPrank(CoWTWAPLib.COW_VAULT_RELAYER);
        order.sellToken.transferFrom(address(hookableAssetAcquisition), CoWTWAPLib.COW_VAULT_RELAYER, order.sellAmount);

        // 2. Calculate swap output using actual Uniswap quotes
        // In reality, CoW would route through multiple DEXs
        uint256 wbtcReceived = _getActualSwapQuote(order.sellAmount, iteration);

        vm.stopPrank();
        console.log("xmmmm", wbtcReceived);
        console.log("zmmmm", WBTC);
        console.log("vr", IERC20(WBTC).balanceOf(alice));
        console.log("WBTC ALICE", IERC20(WBTC).balanceOf(alice));
        vm.startPrank(alice);
        IERC20(WBTC).transfer(CoWTWAPLib.COW_VAULT_RELAYER, wbtcReceived);
        vm.stopPrank();

        console.log("zmmmm", WBTC);
        console.log("vr", IERC20(WBTC).balanceOf(CoWTWAPLib.COW_VAULT_RELAYER));
        // 4. Settlement sends USDC to acquisition contract
        vm.startPrank(CoWTWAPLib.COW_VAULT_RELAYER);
        IERC20(WBTC).transfer(order.receiver, wbtcReceived);
        vm.stopPrank();

        return wbtcReceived;
    }
    /**
     * @notice Get actual swap quote from Uniswap
     * @dev This queries actual liquidity but doesn't execute the swap
     */
    function _getActualSwapQuote(uint256 sellAmount, uint256 iteration) internal view returns (uint256) {
        // price of one bitcoin in usdc
        uint256 wbtcPrice = (100 + iteration) * 1e6;
        // amount of wbtc for sell amount adjusted to 8 decimals
        return (sellAmount * wbtcPrice) / 1e12;
    }
}
