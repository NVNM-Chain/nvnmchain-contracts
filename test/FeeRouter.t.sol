// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {FeeLockbox} from "../src/FeeLockbox.sol";
import {FeeRouter, FeeRouterFactory} from "../src/FeeRouter.sol";
import {NVNMStaking} from "../src/NVNMStaking.sol";
import {MockERC20} from "./support/MockERC20.sol";
import {MockSwapPool} from "./support/MockSwapPool.sol";
import {MockValidatorConfig} from "./support/MockValidatorConfig.sol";
import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {LibClone} from "solady/utils/LibClone.sol";

/// @dev A swapper that always rejects — stands in for `GuardedSwapper` hitting its price floor.
contract RevertingSwapper {
    error MarketRejected();

    function swap(address, address, uint256, uint256) external pure returns (uint256) {
        revert MarketRejected();
    }
}

/// @dev A swapper that burns whatever gas it is given.
contract GasBurningSwapper {
    function swap(address, address, uint256, uint256) external pure returns (uint256) {
        while (true) {}
        return 0;
    }
}

/// @dev Records the gas each swap arrives with, and buys nothing.
contract BudgetRecordingSwapper {
    uint256 public received;

    function swap(address, address, uint256, uint256) external returns (uint256) {
        received = gasleft();
        return 0;
    }
}

/// @dev Records each caller's fee token, as Tempo's FeeManager does.
contract MockFeeManager {
    mapping(address => address) public validatorTokens;

    function setValidatorToken(address token) external {
        validatorTokens[msg.sender] = token;
    }
}

/// @dev Sells 1:1 by minting, within a per-swap cap, like `GuardedSwapper`'s `maxAmountIn`.
contract CappedSwapper {
    uint256 public immutable maxAmountIn;

    constructor(uint256 cap) {
        maxAmountIn = cap;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256) external returns (uint256) {
        require(amountIn <= maxAmountIn, "over cap");
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(tokenOut).mint(msg.sender, amountIn);
        return amountIn;
    }
}

contract FeeRouterTest is Test {
    uint256 constant SWAP_GAS = 1_000_000;

    NVNMStaking staking;
    FeeLockbox lockbox;
    FeeRouterFactory factory;
    FeeRouter router;
    MockERC20 nvnm;
    MockERC20 usd;

    address owner = makeAddr("safe");
    address validator = makeAddr("validator");
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");
    address treasury = makeAddr("devshare");
    address sink;
    address constant FEE_MANAGER = 0xfeEC000000000000000000000000000000000000;

    function setUp() public {
        vm.etch(FEE_MANAGER, address(new MockFeeManager()).code);
        nvnm = new MockERC20("NVNM", "NVNM");
        usd = new MockERC20("nUSD", "nUSD");
        staking = NVNMStaking(LibClone.deployERC1967(address(new NVNMStaking())));
        staking.initialize(owner, address(nvnm), address(usd));
        lockbox = new FeeLockbox(owner, 2500, 2500, 1 days);
        factory = new FeeRouterFactory(address(staking), address(lockbox), owner, 10_000, treasury);
        sink = factory.BUYBACK_SINK();
        router = FeeRouter(factory.create(validator, operator, 1000)); // 10% of validator remainder

        nvnm.mint(alice, 1000 ether);
        vm.prank(alice);
        nvnm.approve(address(staking), type(uint256).max);
    }

    function _stake(uint256 amount) internal {
        vm.prank(alice);
        staking.stake(validator, amount);
    }

    /// @dev `validator` as the registry's whole active set: a majority of one.
    function _seatValidator() internal {
        vm.etch(address(lockbox.REGISTRY()), address(new MockValidatorConfig()).code);
        address[] memory set = new address[](1);
        set[0] = validator;
        MockValidatorConfig(address(lockbox.REGISTRY())).setActive(set);
    }

    /// @dev Distribution commenced, so flushes split by commission.
    function _commence() internal {
        _seatValidator();
        vm.prank(owner);
        lockbox.setAffiliated(validator, false);
        vm.prank(validator);
        lockbox.vote(true);
        lockbox.commence();
    }

    function test_flush_splitsCommissionAndDeposits() public {
        _commence();
        _stake(100 ether);
        usd.mint(address(router), 100 ether);

        // 25/25 cuts, then 10% commission of the 50 left.
        vm.prank(makeAddr("keeper"));
        assertEq(router.flush(), 45 ether);
        assertEq(usd.balanceOf(operator), 5 ether);
        vm.warp(vm.getBlockTimestamp() + staking.rewardDuration());
        assertApproxEqAbs(staking.earned(validator, alice), 45 ether, 1);
        assertEq(usd.balanceOf(address(router)), 25 ether, "only the buyback cut, held unswapped");
    }

    function test_flush_defersTheOperatorShare() public {
        // No operator is paid before distribution commences; the lockbox holds its share.
        usd.mint(address(router), 100 ether);
        assertEq(router.flush(), 0);
        assertEq(lockbox.owed(address(usd), operator), 50 ether);
        assertEq(usd.balanceOf(address(lockbox)), 50 ether);
        assertEq(usd.balanceOf(operator), 0);
        assertEq(usd.balanceOf(address(router)), 25 ether, "only the buyback cut, held unswapped");
    }

    function test_flush_defersTheDelegatorShareToo() public {
        // A 0% router over a pool its operator staked would otherwise pay out before commencement.
        _stake(100 ether);
        FeeRouter zero = FeeRouter(factory.create(validator, operator, 0));
        usd.mint(address(zero), 100 ether);

        assertEq(zero.flush(), 0, "nothing reaches the pool");
        assertEq(lockbox.owed(address(usd), operator), 50 ether);
        vm.warp(vm.getBlockTimestamp() + staking.rewardDuration());
        assertEq(staking.earned(validator, alice), 0);
    }

    function test_flush_phase1_threeWayWithNoStakers() public {
        FeeRouter r = FeeRouter(factory.create(validator, operator, 10_000)); // whole validator remainder
        usd.mint(address(r), 100 ether);

        assertEq(r.flush(), 0);
        assertEq(usd.balanceOf(treasury), 25 ether);
        assertEq(r.heldForBuyback(address(usd)), 25 ether);
        assertEq(lockbox.owed(address(usd), operator), 50 ether);
    }

    function test_flush_phase5_fourWayFromValidatorAllocation() public {
        _commence();
        _stake(100 ether);
        // 20% commission of the 50% validator remainder = 10% of gross.
        FeeRouter r = FeeRouter(factory.create(validator, operator, 2000));
        usd.mint(address(r), 100 ether);

        assertEq(r.flush(), 40 ether);
        assertEq(usd.balanceOf(treasury), 25 ether);
        assertEq(r.heldForBuyback(address(usd)), 25 ether);
        assertEq(usd.balanceOf(operator), 10 ether);
        vm.warp(vm.getBlockTimestamp() + staking.rewardDuration());
        assertApproxEqAbs(staking.earned(validator, alice), 40 ether, 1);
    }

    function test_create_asksForFeesInTheRewardToken() public view {
        assertEq(address(router.FEE_MANAGER()), FEE_MANAGER);
        assertEq(MockFeeManager(FEE_MANAGER).validatorTokens(address(router)), address(usd));
    }

    function test_setValidatorToken_isPermissionless() public {
        vm.prank(address(router));
        MockFeeManager(FEE_MANAGER).setValidatorToken(address(0)); // as if the reward token had moved
        vm.prank(makeAddr("keeper"));
        router.setValidatorToken();
        assertEq(MockFeeManager(FEE_MANAGER).validatorTokens(address(router)), address(usd));
    }

    function test_flush_zeroBalanceIsNoop() public {
        _stake(1 ether);
        assertEq(router.flush(), 0);
    }

    function test_flush_commissionExtremes() public {
        _commence();
        _stake(1 ether);
        FeeRouter zero = FeeRouter(factory.create(validator, operator, 0));
        usd.mint(address(zero), 50 ether);
        assertEq(zero.flush(), 25 ether);

        FeeRouter all = FeeRouter(factory.create(validator, operator, 10_000));
        usd.mint(address(all), 50 ether);
        assertEq(all.flush(), 0);
        assertEq(usd.balanceOf(operator), 25 ether, "the whole remainder after the cuts");
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

    /// @dev The registry precompile reads `routerOf` straight from slot 4.
    function test_factory_recordsEachValidatorsLatestRouter() public {
        assertEq(factory.routerOf(validator), address(router));
        address again = factory.create(validator, operator, 2000);
        assertEq(factory.routerOf(validator), again, "the latest one");
        assertTrue(factory.isRouter(address(router)), "the earlier one stays a router");
        bytes32 slot = keccak256(abi.encode(validator, uint256(4)));
        assertEq(address(uint160(uint256(vm.load(address(factory), slot)))), again);
    }

    function test_flush_buybackSwapsToSink() public {
        MockSwapPool pool = new MockSwapPool(address(usd), address(nvnm));
        usd.mint(address(pool), 1000 ether);
        nvnm.mint(address(pool), 1000 ether);
        vm.prank(owner);
        factory.setSwapper(address(pool), SWAP_GAS);

        FeeRouter r = FeeRouter(factory.create(validator, operator, 10_000));
        usd.mint(address(r), 100 ether);

        uint256 expectedOut = (uint256(1000 ether) * 25 ether) / uint256(1025 ether);
        assertEq(r.flush(), 0);
        assertEq(usd.balanceOf(treasury), 25 ether);
        assertEq(lockbox.owed(address(usd), operator), 50 ether);
        assertEq(nvnm.balanceOf(sink), expectedOut);
        assertEq(r.heldForBuyback(address(usd)), 0);
        assertEq(staking.stakedOf(validator, alice), 0, "buyback does not compound into a pool");
    }

    function test_flush_survivesARejectingSwapper() public {
        // If a rejected market took the whole flush down with it, one bad pool would stop
        // devshare, commission and delegator payouts on every router at once.
        address swapper = address(new RevertingSwapper());
        vm.prank(owner);
        factory.setSwapper(swapper, SWAP_GAS);

        FeeRouter r = FeeRouter(factory.create(validator, operator, 10_000));
        usd.mint(address(r), 100 ether);

        vm.expectEmit(true, false, false, true, address(r));
        emit FeeRouter.BuybackSwapFailed(factory.swapper(), 25 ether);
        r.flush();

        assertEq(usd.balanceOf(treasury), 25 ether, "devshare still paid");
        assertEq(lockbox.owed(address(usd), operator), 50 ether, "operator share still deferred");
        assertEq(r.heldForBuyback(address(usd)), 25 ether, "buyback cut held for a retry");
        assertEq(usd.balanceOf(address(r)), 25 ether, "and nothing else left on the router");
        assertEq(usd.balanceOf(sink), 0, "never stablecoin to the sink");
        assertEq(usd.allowance(address(r), factory.swapper()), 0, "approval cleared");
        vm.prank(owner);
        assertEq(r.sweep(address(usd), owner), 0, "sweep cannot reach it");
    }

    function test_flush_revertsWhenTheCallerCannotFundTheSwap() public {
        // Otherwise a caller picks a gas limit that starves the swap, and every buyback waits.
        MockSwapPool pool = new MockSwapPool(address(usd), address(nvnm));
        usd.mint(address(pool), 1000 ether);
        nvnm.mint(address(pool), 1000 ether);
        vm.prank(owner);
        factory.setSwapper(address(pool), SWAP_GAS);

        FeeRouter r = FeeRouter(factory.create(validator, operator, 10_000));
        usd.mint(address(r), 100 ether);
        vm.expectRevert(FeeRouter.SwapUnderfunded.selector);
        r.flush{gas: SWAP_GAS / 2}();
    }

    function test_flush_survivesASwapperThatBurnsItsBudget() public {
        address swapper = address(new GasBurningSwapper());
        vm.prank(owner);
        factory.setSwapper(swapper, SWAP_GAS);

        FeeRouter r = FeeRouter(factory.create(validator, operator, 10_000));
        usd.mint(address(r), 100 ether);
        vm.expectEmit(true, false, false, true, address(r));
        emit FeeRouter.BuybackSwapFailed(swapper, 25 ether);
        r.flush{gas: 2 * SWAP_GAS}();
        assertEq(r.heldForBuyback(address(usd)), 25 ether);
    }

    function test_flush_neverCompletesWithAStarvedSwap() public {
        // The check funds the swap, not what follows it: a limit just past it may run out of gas
        // after the call. What no limit may do is complete a flush whose swap got less.
        BudgetRecordingSwapper swapper = new BudgetRecordingSwapper();
        vm.prank(owner);
        factory.setSwapper(address(swapper), SWAP_GAS);
        FeeRouter r = FeeRouter(factory.create(validator, operator, 10_000));
        usd.mint(address(r), 100 ether);

        for (uint256 limit = SWAP_GAS; limit < 2 * SWAP_GAS; limit += 1000) {
            (bool ok,) = address(r).call{gas: limit}(abi.encodeWithSignature("flush()"));
            if (ok) {
                assertGe(swapper.received(), SWAP_GAS - 1000, "the swap ran on less than its budget");
                return;
            }
        }
        assertTrue(false, "no limit under twice the budget completed a flush");
    }

    function test_factory_swapperNeedsAGasBudget() public {
        vm.prank(owner);
        vm.expectRevert(FeeRouterFactory.ZeroGas.selector);
        factory.setSwapper(makeAddr("swapper"), 0);
    }

    function test_flush_retriesTheHeldBuybackWithinTheSwapperCap() public {
        // Unset, the cut waits on the router; later flushes swap it, at most a cap per swap.
        FeeRouter r = FeeRouter(factory.create(validator, operator, 10_000));
        usd.mint(address(r), 100 ether);
        r.flush();
        assertEq(r.heldForBuyback(address(usd)), 25 ether);

        CappedSwapper swapper = new CappedSwapper(10 ether);
        vm.prank(owner);
        factory.setSwapper(address(swapper), SWAP_GAS);
        r.flush(); // no new fees: the held cut alone
        assertEq(r.heldForBuyback(address(usd)), 15 ether);
        r.flush();
        r.flush();
        assertEq(r.heldForBuyback(address(usd)), 0);
        assertEq(nvnm.balanceOf(sink), 25 ether);
        assertEq(usd.balanceOf(sink), 0, "never stablecoin to the sink");
    }

    function test_flush_appliesProtocolCutsToASecondFeeToken() public {
        // FeeManager swaps each payer's fee into the recipient's preferred token, so a router
        // normally holds one. This is the case where that preference points somewhere other
        // than the pool's reward token: the cuts are still owed, and flushing only
        // `rewardToken` would leave them unpaid.
        MockERC20 other = new MockERC20("otherUSD", "otherUSD");
        FeeRouter r = FeeRouter(factory.create(validator, operator, 10_000));
        other.mint(address(r), 100 ether);

        r.flush(address(other));

        assertEq(other.balanceOf(treasury), 25 ether, "devshare paid in the second token");
        assertEq(r.heldForBuyback(address(other)), 25 ether, "buyback cut held: no swapper takes it");
        assertEq(lockbox.owed(address(other), operator), 50 ether, "operator owed the validator remainder");
        assertEq(other.balanceOf(address(r)), 25 ether);
    }

    function test_flush_holdsTheDelegatorShareOfAnUnpoolableToken() public {
        // The pool only accounts in `rewardToken`. Paying the delegators' share to the operator
        // instead would fund the validator out of its delegators' allocation.
        _commence();
        _stake(100 ether);
        MockERC20 other = new MockERC20("otherUSD", "otherUSD");
        other.mint(address(router), 100 ether); // setUp's router: 10% commission

        vm.expectEmit(true, false, false, true, address(router));
        emit FeeRouter.DelegatorShareUnrouted(address(other), 45 ether);
        assertEq(router.flush(address(other)), 0, "nothing deposited: the pool cannot hold it");

        assertEq(other.balanceOf(treasury), 25 ether, "protocol cuts still pay");
        assertEq(router.heldForBuyback(address(other)), 25 ether);
        assertEq(other.balanceOf(operator), 5 ether, "operator paid commission only");
        assertEq(router.heldForDelegators(address(other)), 45 ether, "delegators' share stays put");
        assertEq(other.balanceOf(address(router)), 70 ether);
        assertEq(staking.earned(validator, alice), 0);
    }

    function test_flush_doesNotRecutTheHeldDelegatorShare() public {
        // flush is permissionless. If the held share stayed in the flushable balance, anyone
        // could call flush repeatedly and grind the delegators' funds into devshare, buybacks
        // and the operator a quarter at a time.
        _commence();
        _stake(100 ether);
        MockERC20 other = new MockERC20("otherUSD", "otherUSD");
        other.mint(address(router), 100 ether);

        router.flush(address(other));
        assertEq(other.balanceOf(address(router)), 70 ether, "delegators' share and the buyback cut");
        assertEq(router.heldForDelegators(address(other)), 45 ether);

        uint256 devBefore = other.balanceOf(treasury);
        uint256 opBefore = other.balanceOf(operator);
        assertEq(router.flush(address(other)), 0, "second flush finds nothing new");

        assertEq(other.balanceOf(treasury), devBefore, "devshare not taken twice");
        assertEq(other.balanceOf(operator), opBefore, "commission not taken twice");
        assertEq(other.balanceOf(address(router)), 70 ether, "held shares intact");
    }

    function test_sweep_clearsTheHeldDelegatorShare() public {
        _commence();
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
        assertEq(router.heldForDelegators(address(other)), 45 ether);
    }

    function test_flush_swapsOnlyTheRewardToken() public {
        // The swapper is bound to one pair, so a second fee token must not be routed into it.
        address swapper = address(new RevertingSwapper());
        vm.prank(owner);
        factory.setSwapper(swapper, SWAP_GAS);

        MockERC20 other = new MockERC20("otherUSD", "otherUSD");
        FeeRouter r = FeeRouter(factory.create(validator, operator, 10_000));
        other.mint(address(r), 100 ether);
        r.flush(address(other)); // would emit BuybackSwapFailed if it had tried to swap

        assertEq(r.heldForBuyback(address(other)), 25 ether, "held without touching the swapper");
        assertEq(other.allowance(address(r), swapper), 0, "never approved");
    }

    function test_flush_defaultsToTheRewardToken() public {
        FeeRouter r = FeeRouter(factory.create(validator, operator, 10_000));
        usd.mint(address(r), 100 ether);
        r.flush();
        assertEq(usd.balanceOf(treasury), 25 ether);
        assertEq(r.heldForBuyback(address(usd)), 25 ether);
    }

    function test_constructor_validation() public {
        vm.expectRevert(FeeRouter.ZeroAddress.selector);
        new FeeRouter(address(0), operator, address(staking), address(factory), 0);
        // Without a factory there are no cuts and no lockbox to defer to.
        vm.expectRevert(FeeRouter.ZeroAddress.selector);
        new FeeRouter(validator, operator, address(staking), address(0), 0);
        vm.expectRevert(FeeRouter.InvalidBps.selector);
        new FeeRouter(validator, operator, address(staking), address(factory), 10_001);
    }

    function test_sweep_takesOnlyTheHeldShare() public {
        // Live fees are flush's to route; sweeping them would hand the owner the whole balance.
        usd.mint(address(router), 100 ether);
        nvnm.mint(address(router), 5 ether);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(FeeRouter.NotFactoryOwner.selector);
        router.sweep(address(usd), operator);

        vm.startPrank(owner);
        assertEq(router.sweep(address(usd), operator), 0);
        assertEq(router.sweep(address(nvnm), operator), 0);
        vm.stopPrank();
        assertEq(usd.balanceOf(address(router)), 100 ether, "fees stay for flush");
        assertEq(nvnm.balanceOf(address(router)), 5 ether);
    }

    function test_flush_dustBuybackDoesNotRevert() public {
        MockSwapPool pool = new MockSwapPool(address(usd), address(nvnm));
        usd.mint(address(pool), 1000 ether);
        nvnm.mint(address(pool), 1000 ether);
        vm.prank(owner);
        factory.setSwapper(address(pool), SWAP_GAS);

        FeeRouter r = FeeRouter(factory.create(validator, operator, 10_000));
        usd.mint(address(r), 2); // 25% of 2 = 0 after truncation
        assertEq(r.flush(), 0);
        assertEq(lockbox.owed(address(usd), operator), 2);
    }

    function test_factory_constructorValidation() public {
        address box = address(lockbox);
        vm.expectRevert(FeeRouterFactory.ZeroAddress.selector);
        new FeeRouterFactory(address(0), box, owner, 2000, treasury);
        vm.expectRevert(FeeRouterFactory.ZeroAddress.selector);
        new FeeRouterFactory(address(staking), address(0), owner, 2000, treasury);
        vm.expectRevert(FeeRouterFactory.ZeroAddress.selector);
        new FeeRouterFactory(address(staking), box, owner, 2000, address(0));
        vm.expectRevert(FeeRouterFactory.CommissionTooHigh.selector);
        new FeeRouterFactory(address(staking), box, owner, 10_001, treasury);
    }

    function test_factory_isDeterministicPerParams() public {
        vm.expectRevert();
        factory.create(validator, operator, 1000);
        address other = factory.create(validator, operator, 2000);
        assertTrue(other != address(router));
        assertEq(FeeRouter(other).commissionBps(), 2000);
        assertEq(FeeRouter(other).rewardToken(), address(usd));
    }

    function test_flush_paysTheOperatorOnceCommenced() public {
        usd.mint(address(router), 100 ether);
        router.flush();
        assertEq(lockbox.owed(address(usd), operator), 50 ether, "deferred before commencement");

        _commence();

        usd.mint(address(router), 100 ether);
        router.flush();
        assertEq(usd.balanceOf(operator), 50 ether, "paid straight through after it");
        assertEq(lockbox.owed(address(usd), operator), 50 ether, "the deferred share waits for a claim");
    }

    function test_flush_followsTheVotedSplit() public {
        _seatValidator();
        vm.prank(validator);
        uint256 id = lockbox.proposeSplit(2000, 3000);
        vm.warp(block.timestamp + 1 days);
        lockbox.applySplit(id);

        FeeRouter r = FeeRouter(factory.create(validator, operator, 10_000));
        usd.mint(address(r), 100 ether);
        r.flush();
        assertEq(usd.balanceOf(treasury), 20 ether);
        assertEq(r.heldForBuyback(address(usd)), 30 ether);
        assertEq(lockbox.owed(address(usd), operator), 50 ether);
    }
}
