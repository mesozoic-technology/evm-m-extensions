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

contract HookableAssetAquisitionIntegrationTest is BaseIntegrationTest {
    using stdStorage for StdStorage;

    // Holds USDC, USDT and wM
    address constant USER = 0x77BAB32F75996de8075eBA62aEa7b1205cf7E004;

    // WBTC contract address
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    address constant WBTC_WHALE = 0xed805ac246F441Ea0D057B81d910EF1e39EB5995;

    Options public hookableAssetAquisitionDeployOptions;

    function setUp() public override {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 22_751_329);

        uint256 whaleBalance = IERC20(WBTC).balanceOf(WBTC_WHALE);

        stdstore.target(WBTC).sig("balanceOf(address)").with_key(alice).checked_write(uint256(whaleBalance));

        stdstore.target(WBTC).sig("balanceOf(address)").with_key(WBTC_WHALE).checked_write(uint256(0));

        uint256 whaleBalanceAfter = IERC20(WBTC).balanceOf(WBTC_WHALE);

        uint256 aliceBalanceAfter = IERC20(WBTC).balanceOf(alice);

        super.setUp();

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

        vm.prank(admin);
        swapFacility.grantRole(M_SWAPPER_ROLE, USER);
    }

    function test() public {}
}
