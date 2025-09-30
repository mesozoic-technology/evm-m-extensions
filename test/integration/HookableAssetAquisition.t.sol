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
import { HookableAssetAquisitionHarness } from "../harness/HookableAssetAquisitionHarness.sol";

import { BaseIntegrationTest } from "../utils/BaseIntegrationTest.sol";

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

contract HookableAssetAquisitionIntegrationTest is BaseIntegrationTest {
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

    Options public hookableAssetAquisitionDeployOptions;

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

        hookableAssetAquisitionDeployOptions.constructorData = abi.encode(
            address(swapAdapter),
            address(UNISWAP_V3_ROUTER)
        );

        hookableAssetAquisition = HookableAssetAquisitionHarness(
            Upgrades.deployTransparentProxy(
                "HookableAssetAquisitionHarness.sol:HookableAssetAquisitionHarness",
                admin,
                abi.encodeWithSelector(
                    HookableAssetAquisitionHarness.initialize.selector,
                    address(mYieldToOneHookable),
                    WBTC
                ),
                hookableAssetAquisitionDeployOptions
            )
        );

        _addToList(EARNERS_LIST, address(mYieldToOneHookable));

        vm.prank(hookManager);

        mYieldToOneHookable.setHook(address(hookableAssetAquisition));

        vm.prank(yieldRecipientManager);
        mYieldToOneHookable.setYieldRecipient(address(hookableAssetAquisition));

        vm.prank(admin);
        swapFacility.grantRole(M_SWAPPER_ROLE, USER);
    }

    function test_spotSwap() public {
        mYieldToOneHookable.enableEarning();

        assertEq(mToken.balanceOf(alice), 100_000e6);

        vm.prank(alice);
        mToken.approve(address(swapFacility), type(uint256).max);

        vm.expectEmit();
        emit HookableAssetAquisitionHarness.HookCalled(address(0), alice, 100_000e6);

        vm.prank(alice);
        swapFacility.swapInM(address(mYieldToOneHookable), 100_000e6, alice);

        assertEq(mYieldToOneHookable.balanceOf(alice), 100_000e6);

        (uint256 userAssets, uint256 userUpdate, uint256 userHodl) = hookableAssetAquisition.getUser(alice);

        uint256 yield = mYieldToOneHookable.yield();
        uint256 totalSupply = mYieldToOneHookable.totalSupply();

        vm.warp(vm.getBlockTimestamp() + 31449600);

        yield = mYieldToOneHookable.yield();

        totalSupply = mYieldToOneHookable.totalSupply();

        mYieldToOneHookable.claimYield();

        uint256 hookingAssets = hookableAssetAquisition.getHookingAssets();

        hookableAssetAquisition.spotSwap();

        uint256 balanceOfHookableAssetAquisition = mYieldToOneHookable.balanceOf(address(hookableAssetAquisition));

        totalSupply = mYieldToOneHookable.totalSupply();

        uint256 yieldedBalance = hookableAssetAquisition.getYieldedAssets();
        uint256 targetBalance = hookableAssetAquisition.getTargetAssets();
        uint256 wbtcBalance = IERC20(WBTC).balanceOf(address(hookableAssetAquisition));

        assertEq(
            balanceOfHookableAssetAquisition,
            0,
            "HookableAssetAquisition should have zero mYieldToOneHookable balance"
        );
        assertEq(yieldedBalance, 0, "yielded balance should be entirely swapped into target");
        assertTrue(0 < targetBalance, "target balance should have been received by the aquisition contract");
        assertTrue(0 < wbtcBalance, "wbtc should be acquired by HookableAssetAquisition");
    }

    function test_claim_x() public {
        mYieldToOneHookable.enableEarning();

        assertEq(mToken.balanceOf(alice), 100_000e6);

        vm.prank(alice);
        mToken.approve(address(swapFacility), type(uint256).max);

        vm.expectEmit();
        emit HookableAssetAquisitionHarness.HookCalled(address(0), alice, 100_000e6);

        vm.prank(alice);
        swapFacility.swapInM(address(mYieldToOneHookable), 100_000e6, alice);

        assertEq(mYieldToOneHookable.balanceOf(alice), 100_000e6);

        vm.warp(vm.getBlockTimestamp() + 31449600);

        mYieldToOneHookable.claimYield();

        hookableAssetAquisition.spotSwap();

        uint256 targetAssets = hookableAssetAquisition.getTargetAssets();

        vm.prank(alice);
        hookableAssetAquisition.claim();

        assertEq(IERC20(WBTC).balanceOf(alice), targetAssets, "alice should hold all of the target assets");
        assertEq(
            hookableAssetAquisition.getTargetAssets(),
            0,
            "HookableAssetAquisition should not have any remaining target assets"
        );
        assertEq(hookableAssetAquisition.getHodling(), 0, "HookableAssetAquisition should have 0 hodling");

        (uint256 aliceAssets, uint256 aliceUpdate, uint256 aliceHodl) = hookableAssetAquisition.getUser(alice);

        assertEq(aliceHodl, 0, "alice should have 0 hodl");
        assertEq(aliceUpdate, vm.getBlockTimestamp(), "alice should be updated to the current timestamp");
        assertEq(aliceAssets, 100_000e6, "alice should have original 100_000e6 balance");
    }

    function test_claimTwoUsers() public {
        mYieldToOneHookable.enableEarning();

        assertEq(mToken.balanceOf(alice), 100_000e6);

        vm.prank(alice);
        mToken.approve(address(swapFacility), type(uint256).max);

        vm.expectEmit();
        emit HookableAssetAquisitionHarness.HookCalled(address(0), alice, 50_000e6);

        vm.prank(alice);
        swapFacility.swapInM(address(mYieldToOneHookable), 50_000e6, alice);

        vm.prank(bob);
        mToken.approve(address(swapFacility), type(uint256).max);

        vm.expectEmit();
        emit HookableAssetAquisitionHarness.HookCalled(address(0), bob, 50_000e6);

        vm.prank(bob);
        swapFacility.swapInM(address(mYieldToOneHookable), 50_000e6, bob);

        assertEq(mYieldToOneHookable.balanceOf(bob), 50_000e6);

        assertEq(mYieldToOneHookable.totalSupply(), 100_000e6);

        vm.warp(vm.getBlockTimestamp() + 31449600);

        mYieldToOneHookable.claimYield();

        hookableAssetAquisition.spotSwap();

        uint256 targetAssets = hookableAssetAquisition.getTargetAssets();

        vm.prank(alice);
        hookableAssetAquisition.claim();

        vm.prank(bob);
        hookableAssetAquisition.claim();

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
            hookableAssetAquisition.getTargetAssets(),
            0,
            "HookableAssetAquisition should not have any remaining target assets"
        );
        assertEq(hookableAssetAquisition.getHodling(), 0, "HookableAssetAquisition should have 0 hodling");

        (uint256 aliceAssets, uint256 aliceUpdate, uint256 aliceHodl) = hookableAssetAquisition.getUser(alice);

        assertEq(aliceHodl, 0, "alice should have 0 hodl");
        assertEq(aliceUpdate, vm.getBlockTimestamp(), "alice should be updated to the current timestamp");
        assertEq(aliceAssets, 50_000e6, "alice should have original 50_000e6 balance");

        (uint256 bobAssets, uint256 bobUpdate, uint256 bobHodl) = hookableAssetAquisition.getUser(bob);

        assertEq(bobHodl, 0, "bob should have 0 hodl");
        assertEq(bobUpdate, vm.getBlockTimestamp(), "bob should be updated to the current timestamp");
        assertEq(bobAssets, 50_000e6, "bob should have original 50_000e6 balance");
    }
}
