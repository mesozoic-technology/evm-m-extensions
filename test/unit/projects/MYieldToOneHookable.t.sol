// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.26;

import { IERC20 } from "../../../lib/common/src/interfaces/IERC20.sol";
import { IERC20Extended } from "../../../lib/common/src/interfaces/IERC20Extended.sol";

import {
    IAccessControl
} from "../../../lib/common/lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";

import { Upgrades, UnsafeUpgrades } from "../../../lib/openzeppelin-foundry-upgrades/src/Upgrades.sol";

import { MockM } from "../../utils/Mocks.sol";

import { MYieldToOne } from "../../../src/projects/yieldToOne/MYieldToOne.sol";
import { IMYieldToOne } from "../../../src/projects/yieldToOne/IMYieldToOne.sol";

import { MYieldToOneHookable } from "../../../src/projects/yieldToOneHookable/MYieldToOneHookable.sol";
import { IMYieldToOneHookable, IHookLike } from "../../../src/projects/yieldToOneHookable/IMYieldToOneHookable.sol";

import { IFreezable } from "../../../src/components/IFreezable.sol";
import { IMExtension } from "../../../src/interfaces/IMExtension.sol";

import { ISwapFacility } from "../../../src/swap/interfaces/ISwapFacility.sol";

import { MYieldToOneHookableHarness } from "../../harness/MYieldToOneHookableHarness.sol";

import { BaseUnitTest } from "../../utils/BaseUnitTest.sol";

contract HookLikeContract is IHookLike {
    /// @notice Emitted for testing purposes
    /// @param from The from account passed to .hook()
    /// @param to The to account passed to .hook()
    /// @param amount The amount passed to .hook()
    event HookCalled(address from, address to, uint256 amount);

    /// @inheritdoc IHookLike
    function hook(address from, address to, uint256 amount) public {
        emit HookCalled(from, to, amount);
    }
}

contract MYieldToOneHookableUnitTests is BaseUnitTest {
    MYieldToOneHookableHarness public mYieldToOneHookable;
    HookLikeContract public hookContract;

    string public constant NAME = "HALO USD";
    string public constant SYMBOL = "HALO USD";

    function setUp() public override {
        super.setUp();

        hookContract = new HookLikeContract();

        mYieldToOneHookable = MYieldToOneHookableHarness(
            Upgrades.deployTransparentProxy(
                "MYieldToOneHookableHarness.sol:MYieldToOneHookableHarness",
                admin,
                abi.encodeWithSelector(
                    MYieldToOneHookable.initialize.selector,
                    NAME,
                    SYMBOL,
                    yieldRecipient,
                    admin,
                    freezeManager,
                    yieldRecipientManager,
                    hookManager,
                    address(hookContract)
                ),
                mExtensionDeployOptions
            )
        );

        registrar.setEarner(address(mYieldToOneHookable), true);
    }

    /* ============ initialize ============ */

    function test_initialize() external view {
        assertEq(mYieldToOneHookable.name(), NAME);
        assertEq(mYieldToOneHookable.symbol(), SYMBOL);
        assertEq(mYieldToOneHookable.decimals(), 6);
        assertEq(mYieldToOneHookable.mToken(), address(mToken));
        assertEq(mYieldToOneHookable.swapFacility(), address(swapFacility));
        assertEq(mYieldToOneHookable.yieldRecipient(), yieldRecipient);
        assertEq(mYieldToOneHookable.hook(), address(hookContract));

        assertTrue(IAccessControl(address(mYieldToOneHookable)).hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(IAccessControl(address(mYieldToOneHookable)).hasRole(FREEZE_MANAGER_ROLE, freezeManager));
        assertTrue(
            IAccessControl(address(mYieldToOneHookable)).hasRole(YIELD_RECIPIENT_MANAGER_ROLE, yieldRecipientManager)
        );
        assertTrue(IAccessControl(address(mYieldToOneHookable)).hasRole(HOOK_MANAGER_ROLE, hookManager));
    }

    function test_initialize_zeroHookManager() external {
        address implementation = address(new MYieldToOneHookableHarness(address(mToken), address(swapFacility)));

        vm.expectRevert(IMYieldToOneHookable.ZeroHookManager.selector);
        MYieldToOneHookableHarness(
            UnsafeUpgrades.deployTransparentProxy(
                implementation,
                admin,
                abi.encodeWithSelector(
                    MYieldToOneHookable.initialize.selector,
                    NAME,
                    SYMBOL,
                    address(yieldRecipient),
                    admin,
                    freezeManager,
                    yieldRecipientManager,
                    address(0),
                    address(hookContract)
                )
            )
        );
    }
    function test_initialize_zeroHookContract() external {
        address implementation = address(new MYieldToOneHookableHarness(address(mToken), address(swapFacility)));

        vm.expectRevert(IMYieldToOneHookable.ZeroHookContract.selector);
        MYieldToOneHookableHarness(
            UnsafeUpgrades.deployTransparentProxy(
                implementation,
                admin,
                abi.encodeWithSelector(
                    MYieldToOneHookable.initialize.selector,
                    NAME,
                    SYMBOL,
                    address(yieldRecipient),
                    admin,
                    freezeManager,
                    yieldRecipientManager,
                    hookManager,
                    address(0)
                )
            )
        );
    }

    /* ============ _wrap ============ */

    function test_wrap_x() external {
        uint256 amount = 1_000e6;
        mToken.setBalanceOf(address(swapFacility), amount);

        vm.expectCall(
            address(mToken),
            abi.encodeWithSelector(
                mToken.transferFrom.selector,
                address(swapFacility),
                address(mYieldToOneHookable),
                amount
            )
        );

        vm.expectEmit();
        emit IERC20.Transfer(address(0), alice, amount);

        vm.expectEmit();
        emit HookLikeContract.HookCalled(address(0), alice, amount);

        vm.prank(address(swapFacility));
        mYieldToOneHookable.wrap(alice, amount);
    }

    /* ============ _unwrap ============ */

    function test_unwrap() external {
        uint256 amount = 1_000e6;

        mYieldToOneHookable.setBalanceOf(address(swapFacility), amount);
        mYieldToOneHookable.setBalanceOf(alice, amount);
        mYieldToOneHookable.setTotalSupply(amount);

        mToken.setBalanceOf(address(mYieldToOneHookable), amount);

        vm.expectEmit();
        emit IERC20.Transfer(address(swapFacility), address(0), 1e6);

        vm.expectEmit();
        emit HookLikeContract.HookCalled(address(swapFacility), address(0), 1e6);

        vm.prank(address(swapFacility));
        mYieldToOneHookable.unwrap(alice, 1e6);
    }

    /* ============ _transfer ============ */

    function test_transfer() external {
        uint256 amount = 1_000e6;
        mYieldToOneHookable.setBalanceOf(alice, amount);

        vm.expectEmit();
        emit IERC20.Transfer(alice, bob, amount);

        vm.expectEmit();
        emit HookLikeContract.HookCalled(alice, bob, amount);

        vm.prank(alice);
        mYieldToOneHookable.transfer(bob, amount);
    }

    /* ============ claimYield ============ */

    function test_claimYield_x() external {
        uint256 yield = 500e6;

        mToken.setBalanceOf(address(mYieldToOneHookable), 1_500e6);
        mYieldToOneHookable.setTotalSupply(1_000e6);

        assertEq(mYieldToOneHookable.yield(), yield);

        vm.expectEmit();
        emit IMYieldToOne.YieldClaimed(yield);

        vm.expectEmit();
        emit HookLikeContract.HookCalled(address(0), address(yieldRecipient), yield);

        mYieldToOneHookable.claimYield();
    }
}
