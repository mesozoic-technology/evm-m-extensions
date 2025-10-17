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

import { IHooks, Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { HookMiner } from "../utils/HookMiner.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { LiquidityAmounts } from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { IPermit2 } from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import { IV4Router } from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import { IUniversalRouter } from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import { Commands } from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { FixedPointMathLib } from "@uniswap/v4-core/lib/solmate/src/utils/FixedPointMathLib.sol";
import { FixedPoint96 } from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import { TWAMM, ITWAMM } from "../../src/hooks/TWAMM.sol";

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
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address constant UNISWAP_V3_QUOTER = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;

    address constant UNISWAP_V4_UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;

    address constant UNISWAP_V4_POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;

    address constant UNISWAP_V4_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address constant USDC_WBTC_POOL = 0x99ac8cA7087fA4A2A1FB6357269965A2014ABc35;

    address constant UNISWAP_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

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
        _giveM(bob, 1_000_000e6);

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

    function test_twamm() public {
        address poolManager = 0x000000000004444c5dc75cB358380D2e3dE08A90;
        address create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

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

    function test_uniswapHook() public {
        stdstore.target(WBTC).sig("balanceOf(address)").with_key(alice).checked_write(type(uint128).max);
        stdstore.target(USDC).sig("balanceOf(address)").with_key(alice).checked_write(type(uint128).max);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(
            address(UNISWAP_POOL_MANAGER),
            30 minutes, // expirationInterval
            address(this) // owner
        );

        address create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

        (address hookAddress, bytes32 salt) = HookMiner.find(
            create2Deployer,
            flags,
            type(TWAMM).creationCode,
            constructorArgs
        );
        {
            // Prepare the complete init code (creationCode + constructor args)
            bytes memory initCode = abi.encodePacked(type(TWAMM).creationCode, constructorArgs);

            // Arachnid's CREATE2 factory expects calldata: salt (32 bytes) + initCode
            // It will deploy using CREATE2 opcode with that salt
            bytes memory deploymentData = abi.encodePacked(salt, initCode);

            // Deploy using the CREATE2 factory
            (bool success, ) = create2Deployer.call(deploymentData);
            require(success, "CREATE2 deployment failed");
        }

        // Verify deployment at expected address
        require(hookAddress.code.length > 0, "Hook not deployed");

        // Ensure token0 < token1
        (Currency currency0, Currency currency1) = USDC < WBTC
            ? (Currency.wrap(USDC), Currency.wrap(WBTC))
            : (Currency.wrap(WBTC), Currency.wrap(USDC));

        int24 TICK_SPACING = 60;

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddress)
        });

        uint160 sqrtPriceRatio = uint160(
            FixedPointMathLib.sqrt((1e1 * 1e8 * FixedPoint96.Q96 * FixedPoint96.Q96) / (1e6))
        );

        IPoolManager(UNISWAP_POOL_MANAGER).initialize(key, sqrtPriceRatio);

        vm.prank(admin);
        hookableAssetAcquisition.setTWAMMConfig(address(hookAddress), address(UNISWAP_POOL_MANAGER), key);

        vm.prank(alice);
        IPermit2(UNISWAP_V4_PERMIT2).approve(USDC, UNISWAP_V4_POSITION_MANAGER, type(uint160).max, type(uint48).max);
        vm.prank(alice);
        IERC20(USDC).approve(UNISWAP_V4_POSITION_MANAGER, type(uint256).max);
        vm.prank(alice);
        IERC20(USDC).approve(UNISWAP_V4_PERMIT2, type(uint256).max);
        vm.prank(alice);
        IPermit2(UNISWAP_V4_PERMIT2).approve(WBTC, UNISWAP_V4_POSITION_MANAGER, type(uint160).max, type(uint48).max);
        vm.prank(alice);
        IERC20(WBTC).approve(UNISWAP_V4_POSITION_MANAGER, type(uint256).max);
        vm.prank(alice);
        IERC20(WBTC).approve(UNISWAP_V4_PERMIT2, type(uint256).max);

        {
            (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = IPoolManager(UNISWAP_POOL_MANAGER)
                .getSlot0(key.toId());

            uint256 usdcAmount = 10_000_000e6;
            uint256 wbtcAmount = 100e8;

            uint128 liquidityAmount;
            uint256 amount0;
            uint256 amount1;

            // define range
            int24 tickLower = (tick / TICK_SPACING) * TICK_SPACING - (TICK_SPACING * 20);
            int24 tickUpper = tickLower + (TICK_SPACING * 120);

            // calculate liquidity
            liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                wbtcAmount,
                usdcAmount
            );

            // calculate exact amounts
            (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                liquidityAmount
            );

            // mint a new position
            bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
            console.log("amounts", amount0, amount1);

            bytes[] memory params = new bytes[](2);

            // MINT_POSITION params
            params[0] = abi.encode(
                key,
                tickLower,
                tickUpper,
                liquidityAmount,
                type(uint256).max,
                type(uint256).max,
                address(this), // recipient
                "" // hookData
            );

            // SETTLE_PAIR params
            params[1] = abi.encode(key.currency0, key.currency1);

            // execute
            vm.prank(alice);
            IPositionManager(UNISWAP_V4_POSITION_MANAGER).modifyLiquidities(
                abi.encode(actions, params),
                vm.getBlockTimestamp() + 100 days
            );
        }
        {
            _swapOneWBTC(key);
        }

        hookableAssetAcquisition.setTWAMMConfig(UNISWAP_POOL_MANAGER, hookAddress, key);

        mYieldToOneHookable.enableEarning();

        assertEq(mToken.balanceOf(bob), 1_000_000e6);

        vm.prank(bob);
        hookableAssetAcquisition.activateUser();

        vm.prank(bob);
        mToken.approve(address(swapFacility), type(uint256).max);

        vm.expectEmit();
        emit HookableAssetAcquisitionHarness.HookCalled(address(0), bob, 1_000_000e6);

        vm.prank(bob);
        swapFacility.swapInM(address(mYieldToOneHookable), 1_000_000e6, bob);

        assertEq(mYieldToOneHookable.balanceOf(bob), 1_000_000e6, "!");

        vm.warp(vm.getBlockTimestamp() + 31449600);

        mYieldToOneHookable.claimYield();

        uint256 yieldedAssets = hookableAssetAcquisition.getYieldedAssets();

        hookableAssetAcquisition.twammSwap();

        console.log("TIME NOW", vm.getBlockTimestamp());
        console.log("ten days", uint256(10 days));

        ITWAMM.OrderKey memory orderKey = hookableAssetAcquisition.getTWAMMOrderKey(0);

        console.log("order id", orderKey.owner, orderKey.expiration, orderKey.zeroForOne);
        console.log("hookable assets", address(hookableAssetAcquisition));

        uint256 sellRateCurrent;
        uint256 earningsFactorCurrent;
        uint256 owed;
        uint256 tokens0OwedDelta;
        uint256 tokens1OwedDelta;

        (uint160 sqrtPriceBeforeX96, , , ) = IPoolManager(UNISWAP_POOL_MANAGER).getSlot0(key.toId());

        vm.warp(vm.getBlockTimestamp() + 1 days);
        _swapOneWBTC(key);
        (sellRateCurrent, earningsFactorCurrent) = ITWAMM(hookAddress).getOrderPool(key, false); // true for zeroForOne
        console.log("sell rate current", sellRateCurrent);
        console.log("earningsFactorCurrent", earningsFactorCurrent);
        vm.prank(address(hookableAssetAcquisition));
        (tokens0OwedDelta, tokens1OwedDelta) = ITWAMM(hookAddress).sync(ITWAMM.SyncParams(key, orderKey));
        console.log("tokens0OwedDelta", tokens0OwedDelta);
        console.log("tokens1OwedDelta", tokens1OwedDelta);
        owed = ITWAMM(hookAddress).tokensOwed(Currency.wrap(WBTC), address(hookableAssetAcquisition));
        console.log("owed", owed);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        _swapOneWBTC(key);
        (sellRateCurrent, earningsFactorCurrent) = ITWAMM(hookAddress).getOrderPool(key, false); // true for zeroForOne
        console.log("sell rate current", sellRateCurrent);
        console.log("earningsFactorCurrent", earningsFactorCurrent);
        vm.prank(address(hookableAssetAcquisition));
        (tokens0OwedDelta, tokens1OwedDelta) = ITWAMM(hookAddress).sync(ITWAMM.SyncParams(key, orderKey));
        console.log("tokens0OwedDelta", tokens0OwedDelta);
        console.log("tokens1OwedDelta", tokens1OwedDelta);
        owed = ITWAMM(hookAddress).tokensOwed(Currency.wrap(WBTC), address(hookableAssetAcquisition));
        console.log("owed", owed);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        _swapOneWBTC(key);
        (sellRateCurrent, earningsFactorCurrent) = ITWAMM(hookAddress).getOrderPool(key, false); // true for zeroForOne
        console.log("sell rate current", sellRateCurrent);
        console.log("earningsFactorCurrent", earningsFactorCurrent);
        vm.prank(address(hookableAssetAcquisition));
        (tokens0OwedDelta, tokens1OwedDelta) = ITWAMM(hookAddress).sync(ITWAMM.SyncParams(key, orderKey));
        console.log("tokens0OwedDelta", tokens0OwedDelta);
        console.log("tokens1OwedDelta", tokens1OwedDelta);
        owed = ITWAMM(hookAddress).tokensOwed(Currency.wrap(WBTC), address(hookableAssetAcquisition));
        console.log("owed", owed);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        _swapOneWBTC(key);
        (sellRateCurrent, earningsFactorCurrent) = ITWAMM(hookAddress).getOrderPool(key, false); // true for zeroForOne
        console.log("sell rate current", sellRateCurrent);
        console.log("earningsFactorCurrent", earningsFactorCurrent);
        vm.prank(address(hookableAssetAcquisition));
        (tokens0OwedDelta, tokens1OwedDelta) = ITWAMM(hookAddress).sync(ITWAMM.SyncParams(key, orderKey));
        console.log("tokens0OwedDelta", tokens0OwedDelta);
        console.log("tokens1OwedDelta", tokens1OwedDelta);
        owed = ITWAMM(hookAddress).tokensOwed(Currency.wrap(WBTC), address(hookableAssetAcquisition));
        console.log("owed", owed);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        _swapOneWBTC(key);
        (sellRateCurrent, earningsFactorCurrent) = ITWAMM(hookAddress).getOrderPool(key, false); // true for zeroForOne
        console.log("sell rate current", sellRateCurrent);
        console.log("earningsFactorCurrent", earningsFactorCurrent);
        vm.prank(address(hookableAssetAcquisition));
        (tokens0OwedDelta, tokens1OwedDelta) = ITWAMM(hookAddress).sync(ITWAMM.SyncParams(key, orderKey));
        console.log("tokens0OwedDelta", tokens0OwedDelta);
        console.log("tokens1OwedDelta", tokens1OwedDelta);
        owed = ITWAMM(hookAddress).tokensOwed(Currency.wrap(WBTC), address(hookableAssetAcquisition));
        console.log("owed", owed);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        _swapOneWBTC(key);
        (sellRateCurrent, earningsFactorCurrent) = ITWAMM(hookAddress).getOrderPool(key, false); // true for zeroForOne
        console.log("sell rate current", sellRateCurrent);
        console.log("earningsFactorCurrent", earningsFactorCurrent);
        vm.prank(address(hookableAssetAcquisition));
        (tokens0OwedDelta, tokens1OwedDelta) = ITWAMM(hookAddress).sync(ITWAMM.SyncParams(key, orderKey));
        console.log("tokens0OwedDelta", tokens0OwedDelta);
        console.log("tokens1OwedDelta", tokens1OwedDelta);
        owed = ITWAMM(hookAddress).tokensOwed(Currency.wrap(WBTC), address(hookableAssetAcquisition));
        console.log("owed", owed);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        _swapOneWBTC(key);
        (sellRateCurrent, earningsFactorCurrent) = ITWAMM(hookAddress).getOrderPool(key, false); // true for zeroForOne
        console.log("sell rate current", sellRateCurrent);
        console.log("earningsFactorCurrent", earningsFactorCurrent);
        vm.prank(address(hookableAssetAcquisition));
        (tokens0OwedDelta, tokens1OwedDelta) = ITWAMM(hookAddress).sync(ITWAMM.SyncParams(key, orderKey));
        console.log("tokens0OwedDelta", tokens0OwedDelta);
        console.log("tokens1OwedDelta", tokens1OwedDelta);
        owed = ITWAMM(hookAddress).tokensOwed(Currency.wrap(WBTC), address(hookableAssetAcquisition));
        console.log("owed", owed);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        _swapOneWBTC(key);
        (sellRateCurrent, earningsFactorCurrent) = ITWAMM(hookAddress).getOrderPool(key, false); // true for zeroForOne
        console.log("sell rate current", sellRateCurrent);
        console.log("earningsFactorCurrent", earningsFactorCurrent);
        vm.prank(address(hookableAssetAcquisition));
        (tokens0OwedDelta, tokens1OwedDelta) = ITWAMM(hookAddress).sync(ITWAMM.SyncParams(key, orderKey));
        console.log("tokens0OwedDelta", tokens0OwedDelta);
        console.log("tokens1OwedDelta", tokens1OwedDelta);
        owed = ITWAMM(hookAddress).tokensOwed(Currency.wrap(WBTC), address(hookableAssetAcquisition));
        console.log("owed", owed);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        _swapOneWBTC(key);
        (sellRateCurrent, earningsFactorCurrent) = ITWAMM(hookAddress).getOrderPool(key, false); // true for zeroForOne
        console.log("sell rate current", sellRateCurrent);
        console.log("earningsFactorCurrent", earningsFactorCurrent);
        vm.prank(address(hookableAssetAcquisition));
        (tokens0OwedDelta, tokens1OwedDelta) = ITWAMM(hookAddress).sync(ITWAMM.SyncParams(key, orderKey));
        console.log("tokens0OwedDelta", tokens0OwedDelta);
        console.log("tokens1OwedDelta", tokens1OwedDelta);
        owed = ITWAMM(hookAddress).tokensOwed(Currency.wrap(WBTC), address(hookableAssetAcquisition));
        console.log("owed", owed);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        _swapOneWBTC(key);
        (sellRateCurrent, earningsFactorCurrent) = ITWAMM(hookAddress).getOrderPool(key, false); // true for zeroForOne
        console.log("sell rate current", sellRateCurrent);
        console.log("earningsFactorCurrent", earningsFactorCurrent);
        vm.prank(address(hookableAssetAcquisition));
        (tokens0OwedDelta, tokens1OwedDelta) = ITWAMM(hookAddress).sync(ITWAMM.SyncParams(key, orderKey));
        console.log("tokens0OwedDelta", tokens0OwedDelta);
        console.log("tokens1OwedDelta", tokens1OwedDelta);
        owed = ITWAMM(hookAddress).tokensOwed(Currency.wrap(WBTC), address(hookableAssetAcquisition));
        console.log("owed", owed);

        (uint160 sqrtPriceAfterX96, , , ) = IPoolManager(UNISWAP_POOL_MANAGER).getSlot0(key.toId());

        hookableAssetAcquisition.twammClaim();

        uint256 targetAssets = hookableAssetAcquisition.getTargetAssets();

        uint256 priceBefore = _getToken0PriceFromSqrtPrice(sqrtPriceBeforeX96, 1e8);
        uint256 priceAfter = _getToken0PriceFromSqrtPrice(sqrtPriceAfterX96, 1e8);
        uint256 avg = (priceBefore + priceAfter) / 2;
    }

    // Helper function to convert sqrtPriceX96 to human-readable USDC per WBTC
    function _getToken0PriceFromSqrtPrice(uint160 sqrtPriceX96, uint256 baseDecimals) internal pure returns (uint256) {
        return FullMath.mulDiv(uint256(sqrtPriceX96) * uint256(sqrtPriceX96), baseDecimals, 1 << 192);
    }

    // Helper function to convert sqrtPriceX96 to human-readable USDC per WBTC
    function _getToken1PriceFromSqrtPrice(uint160 sqrtPriceX96, uint256 baseDecimals) internal pure returns (uint256) {
        return FullMath.mulDiv(1 << 192, baseDecimals, uint256(sqrtPriceX96) * uint256(sqrtPriceX96));
    }

    function _swapOneWBTC(PoolKey memory key) internal {
        console.log("SWAPPING!!!!");

        vm.prank(alice);
        IERC20(USDC).approve(address(UNISWAP_V4_PERMIT2), type(uint256).max);
        vm.prank(alice);
        IPermit2(UNISWAP_V4_PERMIT2).approve(
            USDC,
            address(UNISWAP_V4_UNIVERSAL_ROUTER),
            type(uint160).max,
            type(uint48).max
        );
        vm.prank(alice);
        IERC20(WBTC).approve(address(UNISWAP_V4_PERMIT2), type(uint256).max);
        vm.prank(alice);
        IPermit2(UNISWAP_V4_PERMIT2).approve(
            WBTC,
            address(UNISWAP_V4_UNIVERSAL_ROUTER),
            type(uint160).max,
            type(uint48).max
        );

        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));

        // encode V4Router actions
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        bytes[] memory params = new bytes[](3);

        uint128 amountIn = 1e8;
        uint128 minAmountOut = 0;

        // first parameter: swap configuration
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn, // amount of tokens we're swapping
                amountOutMinimum: minAmountOut, // minimum amount we expect to receive
                hookData: bytes("") // no hook data needed
            })
        );

        // second parameter: specify input tokens for the swap
        // encode SETTLE_ALL parameters
        params[1] = abi.encode(key.currency0, amountIn);

        // third parameter: specify output tokens from the swap
        params[2] = abi.encode(key.currency1, minAmountOut);

        bytes[] memory inputs = new bytes[](1);

        // combine actions and params into inputs
        inputs[0] = abi.encode(actions, params);

        uint256 wbtcBefore = IERC20(WBTC).balanceOf(alice);
        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);

        // execute the swap
        uint256 deadline = block.timestamp + 20;
        vm.prank(alice);
        IUniversalRouter(UNISWAP_V4_UNIVERSAL_ROUTER).execute(commands, inputs, deadline);

        uint256 wbtcAfter = IERC20(WBTC).balanceOf(alice);
        uint256 usdcAfter = IERC20(USDC).balanceOf(alice);

        console.log("swapped", wbtcBefore - wbtcAfter, usdcAfter - usdcBefore);
    }
}
