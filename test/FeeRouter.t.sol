// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { FeeRouter, FeeRouterFactory } from "../src/FeeRouter.sol";
import { NVNMStaking } from "../src/NVNMStaking.sol";
import { MockERC20 } from "./support/MockERC20.sol";
import { MockSwapPool } from "./support/MockSwapPool.sol";
import { Test } from "forge-std/Test.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { LibClone } from "solady/utils/LibClone.sol";

/// @dev A swapper that always rejects — stands in for `GuardedSwapper` hitting its price floor.
contract RevertingSwapper {
    error MarketRejected();

    function swap(address, address, uint256, uint256) external pure returns (uint256) {
        revert MarketRejected();
    }
}

contract FeeRouterTest is Test {
    NVNMStaking staking;
    FeeRouterFactory factory;
    FeeRouter router;
    MockERC20 nvnm;
    MockERC20 usd;

    address owner = makeAddr("safe");
    address validator = makeAddr("validator");
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");
    address treasury = makeAddr("devshare");
    address buybacks = makeAddr("buybacks");

    function setUp() public {
        nvnm = new MockERC20("NVNM", "NVNM");
        usd = new MockERC20("nvmnUSD", "nvmnUSD");
        staking = NVNMStaking(LibClone.deployERC1967(address(new NVNMStaking())));
        staking.initialize(owner, address(nvnm), address(usd));
        factory = new FeeRouterFactory(address(staking), owner, 10_000);
        router = FeeRouter(factory.create(validator, operator, 1000)); // 10% of validator remainder

        nvnm.mint(alice, 1000 ether);
        vm.prank(alice);
        nvnm.approve(address(staking), type(uint256).max);
    }

    function _stake(uint256 amount) internal {
        vm.prank(alice);
        staking.stake(validator, amount);
    }

    function _phase1Split() internal {
        vm.prank(owner);
        factory.setProtocolSplit(treasury, buybacks, 2500, 2500);
    }

    function test_flush_splitsCommissionAndDeposits() public {
        _stake(100 ether);
        usd.mint(address(router), 100 ether);

        vm.prank(makeAddr("keeper"));
        assertEq(router.flush(), 90 ether);
        assertEq(usd.balanceOf(operator), 10 ether);
        assertEq(staking.earned(validator, alice), 90 ether);
        assertEq(usd.balanceOf(address(router)), 0);
    }

    function test_flush_paysOperatorWhenPoolEmpty() public {
        // Validators are paid from block one, no holder staking required.
        usd.mint(address(router), 100 ether);
        assertEq(router.flush(), 0);
        assertEq(usd.balanceOf(operator), 100 ether);
        assertEq(usd.balanceOf(address(router)), 0);
    }

    function test_flush_phase1_threeWayWithNoStakers() public {
        _phase1Split();
        FeeRouter r = FeeRouter(factory.create(validator, operator, 10_000)); // whole validator remainder
        usd.mint(address(r), 100 ether);

        assertEq(r.flush(), 0);
        assertEq(usd.balanceOf(treasury), 25 ether);
        assertEq(usd.balanceOf(buybacks), 25 ether);
        assertEq(usd.balanceOf(operator), 50 ether);
    }

    function test_flush_phase5_fourWayFromValidatorAllocation() public {
        _phase1Split();
        _stake(100 ether);
        // 20% commission of the 50% validator remainder = 10% of gross.
        FeeRouter r = FeeRouter(factory.create(validator, operator, 2000));
        usd.mint(address(r), 100 ether);

        assertEq(r.flush(), 40 ether);
        assertEq(usd.balanceOf(treasury), 25 ether);
        assertEq(usd.balanceOf(buybacks), 25 ether);
        assertEq(usd.balanceOf(operator), 10 ether);
        assertEq(staking.earned(validator, alice), 40 ether);
    }

    function test_flush_zeroBalanceIsNoop() public {
        _stake(1 ether);
        assertEq(router.flush(), 0);
    }

    function test_flush_commissionExtremes() public {
        _stake(1 ether);
        FeeRouter zero = FeeRouter(factory.create(validator, operator, 0));
        usd.mint(address(zero), 50 ether);
        assertEq(zero.flush(), 50 ether);

        FeeRouter all = new FeeRouter(validator, operator, address(staking), address(0), 10_000);
        usd.mint(address(all), 50 ether);
        assertEq(all.flush(), 0);
        assertEq(usd.balanceOf(operator), 50 ether);
    }

    function test_factory_enforcesCommissionCap() public {
        vm.prank(owner);
        factory.setMaxCommission(2000);

        vm.expectRevert(FeeRouterFactory.CommissionTooHigh.selector);
        factory.create(validator, operator, 2001);

        factory.create(validator, operator, 2000);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.setMaxCommission(500);

        vm.prank(owner);
        factory.setMaxCommission(500);
        vm.expectRevert(FeeRouterFactory.CommissionTooHigh.selector);
        factory.create(validator, operator, 501);
    }

    function test_flush_buybackSwapsToSink() public {
        _phase1Split();
        MockSwapPool pool = new MockSwapPool(address(usd), address(nvnm));
        usd.mint(address(pool), 1000 ether);
        nvnm.mint(address(pool), 1000 ether);
        vm.prank(owner);
        factory.setSwapper(address(pool));

        FeeRouter r = FeeRouter(factory.create(validator, operator, 10_000));
        usd.mint(address(r), 100 ether);

        uint256 expectedOut = (uint256(1000 ether) * 25 ether) / uint256(1025 ether);
        assertEq(r.flush(), 0);
        assertEq(usd.balanceOf(treasury), 25 ether);
        assertEq(usd.balanceOf(operator), 50 ether);
        assertEq(nvnm.balanceOf(buybacks), expectedOut);
        assertEq(staking.stakedOf(validator, alice), 0, "buyback does not compound into a pool");
    }

    function test_flush_survivesARejectingSwapper() public {
        // If a rejected market took the whole flush down with it, one bad pool would stop
        // devshare, commission and delegator payouts on every router at once.
        _phase1Split();
        address swapper = address(new RevertingSwapper());
        vm.prank(owner);
        factory.setSwapper(swapper);

        FeeRouter r = FeeRouter(factory.create(validator, operator, 10_000));
        usd.mint(address(r), 100 ether);

        vm.expectEmit(true, false, false, true, address(r));
        emit FeeRouter.BuybackSwapFailed(factory.swapper(), 25 ether);
        r.flush();

        assertEq(usd.balanceOf(treasury), 25 ether, "devshare still paid");
        assertEq(usd.balanceOf(operator), 50 ether, "operator still paid");
        assertEq(usd.balanceOf(buybacks), 25 ether, "buyback cut forwarded as stablecoin");
        assertEq(usd.balanceOf(address(r)), 0, "nothing stranded on the router");
        assertEq(usd.allowance(address(r), factory.swapper()), 0, "approval cleared");
    }

    function test_flush_withoutSwapper_forwardsStablesToBuyback() public {
        _phase1Split();
        FeeRouter r = FeeRouter(factory.create(validator, operator, 10_000));
        usd.mint(address(r), 100 ether);
        r.flush();
        assertEq(usd.balanceOf(buybacks), 25 ether);
    }

    function test_flush_appliesProtocolCutsToASecondFeeToken() public {
        // FeeManager swaps each payer's fee into the recipient's preferred token, so a router
        // normally holds one. This is the case where that preference points somewhere other
        // than the pool's reward token: the cuts are still owed, and flushing only
        // `rewardToken` would leave them unpaid.
        _phase1Split();
        MockERC20 other = new MockERC20("otherUSD", "otherUSD");
        FeeRouter r = FeeRouter(factory.create(validator, operator, 10_000));
        other.mint(address(r), 100 ether);

        r.flush(address(other));

        assertEq(other.balanceOf(treasury), 25 ether, "devshare paid in the second token");
        assertEq(other.balanceOf(buybacks), 25 ether, "buyback cut forwarded as-is");
        assertEq(other.balanceOf(operator), 50 ether, "operator paid the validator remainder");
        assertEq(other.balanceOf(address(r)), 0);
    }

    function test_flush_holdsTheDelegatorShareOfAnUnpoolableToken() public {
        // The pool only accounts in `rewardToken`. Paying the delegators' share to the operator
        // instead would fund the validator out of its delegators' allocation.
        _phase1Split();
        _stake(100 ether);
        MockERC20 other = new MockERC20("otherUSD", "otherUSD");
        other.mint(address(router), 100 ether); // setUp's router: 10% commission

        vm.expectEmit(true, false, false, true, address(router));
        emit FeeRouter.DelegatorShareUnrouted(address(other), 45 ether);
        assertEq(router.flush(address(other)), 0, "nothing deposited: the pool cannot hold it");

        assertEq(other.balanceOf(treasury), 25 ether, "protocol cuts still pay");
        assertEq(other.balanceOf(buybacks), 25 ether);
        assertEq(other.balanceOf(operator), 5 ether, "operator gets commission only");
        assertEq(other.balanceOf(address(router)), 45 ether, "delegators' share stays put");
        assertEq(staking.earned(validator, alice), 0);
    }

    function test_flush_doesNotRecutTheHeldDelegatorShare() public {
        // flush is permissionless. If the held share stayed in the flushable balance, anyone
        // could call flush repeatedly and grind the delegators' funds into devshare, buybacks
        // and the operator a quarter at a time.
        _phase1Split();
        _stake(100 ether);
        MockERC20 other = new MockERC20("otherUSD", "otherUSD");
        other.mint(address(router), 100 ether);

        router.flush(address(other));
        assertEq(other.balanceOf(address(router)), 45 ether);
        assertEq(router.heldForDelegators(address(other)), 45 ether);

        uint256 devBefore = other.balanceOf(treasury);
        uint256 opBefore = other.balanceOf(operator);
        assertEq(router.flush(address(other)), 0, "second flush finds nothing new");

        assertEq(other.balanceOf(treasury), devBefore, "devshare not taken twice");
        assertEq(other.balanceOf(operator), opBefore, "commission not taken twice");
        assertEq(other.balanceOf(address(router)), 45 ether, "delegators' share intact");
    }

    function test_sweep_clearsTheHeldDelegatorShare() public {
        _phase1Split();
        _stake(100 ether);
        MockERC20 other = new MockERC20("otherUSD", "otherUSD");
        other.mint(address(router), 100 ether);
        router.flush(address(other));

        vm.prank(owner);
        assertEq(router.sweep(address(other), treasury), 45 ether);
        assertEq(router.heldForDelegators(address(other)), 0, "escrow follows the tokens out");

        // Fresh fees in that token flush normally again.
        other.mint(address(router), 100 ether);
        router.flush(address(other));
        assertEq(other.balanceOf(address(router)), 45 ether);
    }

    function test_flush_swapsOnlyTheRewardToken() public {
        // The swapper is bound to one pair, so a second fee token must not be routed into it.
        _phase1Split();
        address swapper = address(new RevertingSwapper());
        vm.prank(owner);
        factory.setSwapper(swapper);

        MockERC20 other = new MockERC20("otherUSD", "otherUSD");
        FeeRouter r = FeeRouter(factory.create(validator, operator, 10_000));
        other.mint(address(r), 100 ether);
        r.flush(address(other)); // would emit BuybackSwapFailed if it had tried to swap

        assertEq(other.balanceOf(buybacks), 25 ether, "forwarded without touching the swapper");
        assertEq(other.allowance(address(r), swapper), 0, "never approved");
    }

    function test_flush_defaultsToTheRewardToken() public {
        _phase1Split();
        FeeRouter r = FeeRouter(factory.create(validator, operator, 10_000));
        usd.mint(address(r), 100 ether);
        r.flush();
        assertEq(usd.balanceOf(treasury), 25 ether);
        assertEq(usd.balanceOf(address(r)), 0);
    }

    function test_constructor_validation() public {
        vm.expectRevert(FeeRouter.ZeroAddress.selector);
        new FeeRouter(address(0), operator, address(staking), address(0), 0);
        vm.expectRevert(FeeRouter.InvalidBps.selector);
        new FeeRouter(validator, operator, address(staking), address(0), 10_001);
    }

    function test_sweep_rescuesStrayBalance() public {
        usd.mint(address(router), 100 ether);
        // flush routes fee tokens, including ones the pool cannot hold; sweep is for what it
        // is not meant to route — a held delegator share, or stray non-fee tokens like these.
        nvnm.mint(address(router), 5 ether);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(FeeRouter.NotFactoryOwner.selector);
        router.sweep(address(nvnm), operator);

        vm.prank(owner);
        assertEq(router.sweep(address(nvnm), operator), 5 ether);
        assertEq(nvnm.balanceOf(operator), 5 ether);
    }

    function test_sweep_unreachableForFactorylessRouter() public {
        FeeRouter r = new FeeRouter(validator, operator, address(staking), address(0), 0);
        usd.mint(address(r), 1 ether);
        vm.prank(owner);
        vm.expectRevert(FeeRouter.NotFactoryOwner.selector);
        r.sweep(address(usd), operator);
    }

    function test_flush_dustBuybackDoesNotRevert() public {
        _phase1Split();
        MockSwapPool pool = new MockSwapPool(address(usd), address(nvnm));
        usd.mint(address(pool), 1000 ether);
        nvnm.mint(address(pool), 1000 ether);
        vm.prank(owner);
        factory.setSwapper(address(pool));

        FeeRouter r = FeeRouter(factory.create(validator, operator, 10_000));
        usd.mint(address(r), 2); // 25% of 2 = 0 after truncation
        assertEq(r.flush(), 0);
        assertEq(usd.balanceOf(operator), 2);
    }

    function test_factory_constructorValidation() public {
        vm.expectRevert(FeeRouterFactory.ZeroAddress.selector);
        new FeeRouterFactory(address(0), owner, 2000);
        vm.expectRevert(FeeRouterFactory.CommissionTooHigh.selector);
        new FeeRouterFactory(address(staking), owner, 10_001);
    }

    function test_factory_isDeterministicPerParams() public {
        vm.expectRevert();
        factory.create(validator, operator, 1000);
        address other = factory.create(validator, operator, 2000);
        assertTrue(other != address(router));
        assertEq(FeeRouter(other).commissionBps(), 2000);
        assertEq(FeeRouter(other).rewardToken(), address(usd));
    }

    function test_setProtocolSplit_rejectsMissingRecipients() public {
        vm.startPrank(owner);
        vm.expectRevert(FeeRouterFactory.ZeroAddress.selector);
        factory.setProtocolSplit(address(0), buybacks, 2500, 2500);
        vm.expectRevert(FeeRouterFactory.InvalidBps.selector);
        factory.setProtocolSplit(treasury, buybacks, 6000, 5000);
        vm.stopPrank();
    }
}
