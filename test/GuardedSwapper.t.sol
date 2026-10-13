// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {GuardedSwapper} from "../src/GuardedSwapper.sol";
import {MockERC20} from "./support/MockERC20.sol";
import {MockSwapPool} from "./support/MockSwapPool.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Stands in for `FeeRouterFactory`: `keeper` plays a router it deployed.
contract MockRouterRegistry {
    mapping(address => bool) public isRouter;

    function set(address account, bool active) external {
        isRouter[account] = active;
    }
}

/// @dev A market that re-enters the swapper from inside its own swap.
contract ReenteringMarket {
    GuardedSwapper immutable guard;

    constructor(GuardedSwapper guard_) {
        guard = guard_;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256) external returns (uint256) {
        guard.swap(tokenIn, tokenOut, amountIn, 0);
        return 0;
    }
}

/// @dev A market that sends half of what it reports.
contract OverstatingMarket {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256) external returns (uint256) {
        SafeTransferLib.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        SafeTransferLib.safeTransfer(tokenOut, msg.sender, amountIn / 2);
        return amountIn;
    }
}

/// @dev A market that takes half of what it is offered, and pays for all of it.
contract HalfTakingMarket {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256) external returns (uint256) {
        SafeTransferLib.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn / 2);
        SafeTransferLib.safeTransfer(tokenOut, msg.sender, amountIn);
        return amountIn;
    }
}

contract GuardedSwapperTest is Test {
    GuardedSwapper guard;
    MockSwapPool pool;
    MockERC20 usd;
    MockERC20 nvnm;
    MockRouterRegistry registry;

    address owner = makeAddr("safe");
    address keeper = makeAddr("keeper");
    address stranger = makeAddr("stranger");

    function setUp() public {
        usd = new MockERC20("nUSD", "nUSD");
        nvnm = new MockERC20("NVNM", "NVNM");
        pool = new MockSwapPool(address(usd), address(nvnm));
        usd.mint(address(pool), 1000 ether);
        nvnm.mint(address(pool), 1000 ether); // spot price 1:1

        registry = new MockRouterRegistry();
        registry.set(keeper, true);

        guard = new GuardedSwapper(owner, address(usd), address(nvnm));
        vm.startPrank(owner);
        guard.setGuards(address(pool), 50 ether); // cap 50
        guard.setDriftBand(1000); // execution may fall 10% short of the seeded price
        guard.setRouterFactory(address(registry));
        guard.seedPrice(1 ether); // 1 NVNM per USD
        vm.stopPrank();

        for (address who = keeper;; who = stranger) {
            usd.mint(who, 1000 ether);
            vm.prank(who);
            usd.approve(address(guard), type(uint256).max);
            if (who == stranger) break;
        }
    }

    function _swap(uint256 amountIn) internal returns (uint256) {
        vm.prank(keeper);
        return guard.swap(address(usd), address(nvnm), amountIn, 0);
    }

    function test_swap_withinGuards() public {
        uint256 out = _swap(10 ether); // x*y=k: 1000*10/1010 ≈ 9.9 -> ~1% impact, within the band
        assertEq(nvnm.balanceOf(keeper), out);
        assertGt(out, 9.8 ether);
    }

    function test_swap_sizeCapEnforced() public {
        vm.prank(keeper);
        vm.expectRevert(GuardedSwapper.AmountTooLarge.selector);
        guard.swap(address(usd), address(nvnm), 51 ether, 0);
    }

    function test_swap_manipulatedPoolReverts() public {
        // Sandwich front-run: drain most of the NVNM side so execution price collapses.
        vm.prank(address(pool));
        nvnm.transfer(address(0xdead), 900 ether);

        vm.prank(keeper);
        vm.expectRevert(GuardedSwapper.PriceBelowFloor.selector);
        guard.swap(address(usd), address(nvnm), 10 ether, 0);
    }

    function test_swap_requiresSeedAndInner() public {
        GuardedSwapper fresh = new GuardedSwapper(owner, address(usd), address(nvnm));
        vm.prank(owner);
        fresh.setRouterFactory(address(registry));
        vm.prank(keeper);
        vm.expectRevert(GuardedSwapper.NotSeeded.selector);
        fresh.swap(address(usd), address(nvnm), 1 ether, 0);
    }

    function test_swap_wrongPairReverts() public {
        vm.prank(keeper);
        vm.expectRevert(GuardedSwapper.WrongPair.selector);
        guard.swap(address(nvnm), address(usd), 1 ether, 0);
    }

    function test_swap_zeroAmountReverts() public {
        vm.prank(keeper);
        vm.expectRevert(GuardedSwapper.ZeroAmount.selector);
        guard.swap(address(usd), address(nvnm), 0, 0);
    }

    function test_onlyOwnerConfigures() public {
        vm.startPrank(keeper);
        vm.expectRevert();
        guard.setGuards(address(pool), 1);
        vm.expectRevert();
        guard.setDriftBand(1);
        vm.expectRevert();
        guard.setRouterFactory(address(0));
        vm.expectRevert();
        guard.seedPrice(2 ether);
        vm.stopPrank();
    }

    function test_setDriftBand_alwaysLeavesAFloor() public {
        vm.startPrank(owner);
        vm.expectRevert(GuardedSwapper.InvalidBps.selector);
        guard.setDriftBand(10_000);
        vm.expectRevert(GuardedSwapper.InvalidBps.selector);
        guard.setDriftBand(10_001);
        guard.setDriftBand(9_999);
        vm.stopPrank();
        assertEq(guard.maxDriftBps(), 9_999);
    }

    /// @dev Sell 5 USD up to `rounds` times, stopping at the first rejection: how many cleared,
    ///      and the price the last one cleared at.
    function _walkPriceDown(uint256 rounds) internal returns (uint256 cleared, uint256 lastPrice) {
        for (uint256 i; i < rounds; ++i) {
            vm.prank(keeper);
            try guard.swap(address(usd), address(nvnm), 5 ether, 0) returns (uint256 out) {
                ++cleared;
                lastPrice = (out * 1e18) / 5 ether;
            } catch {
                return (cleared, lastPrice);
            }
        }
    }

    function test_floor_isTheSeededPriceLessTheBand() public {
        // Each sell moves the pool a little; however many came before, one executes above 0.9
        // and the next does not, and nothing in between follows the price down.
        (uint256 cleared, uint256 lastPrice) = _walkPriceDown(100);
        assertLt(cleared, 100, "the floor binds eventually");
        assertGe(lastPrice, 0.9 ether, "every accepted price cleared it");
        uint256 spot = (nvnm.balanceOf(address(pool)) * 1e18) / usd.balanceOf(address(pool));
        assertLt(spot, 0.92 ether, "and it bound where the market is, not earlier");
        vm.prank(keeper);
        vm.expectRevert(GuardedSwapper.PriceBelowFloor.selector);
        guard.swap(address(usd), address(nvnm), 5 ether, 0);
    }

    function test_floor_movesOnlyWhenReseeded() public {
        // The market rises to 1.5 NVNM per USD while the reference says 1: a sandwich that
        // leaves the swap 0.95 clears and keeps a third of the buyback, until the owner reseeds.
        // That is the price of a floor nothing can walk: a stale reference is the owner's watch.
        nvnm.mint(address(pool), 500 ether);
        vm.prank(address(pool));
        nvnm.transfer(address(0xdead), 540 ether); // front-run: 960 NVNM left against 1000 USD
        uint256 out = _swap(10 ether);
        assertApproxEqRel(out, 9.5 ether, 0.01e18, "cleared at 0.95 under a 1.5 market");

        vm.prank(owner);
        guard.seedPrice(1.5 ether);
        vm.prank(keeper);
        vm.expectRevert(GuardedSwapper.PriceBelowFloor.selector);
        guard.swap(address(usd), address(nvnm), 10 ether, 0);
    }

    function test_swap_onlyRoutersMaySwap() public {
        // The buyback market is the flush path's: a direct caller, the owner included, is refused.
        vm.prank(stranger);
        vm.expectRevert(GuardedSwapper.NotAuthorized.selector);
        guard.swap(address(usd), address(nvnm), 1 ether, 0);

        usd.mint(owner, 10 ether);
        vm.startPrank(owner);
        usd.approve(address(guard), type(uint256).max);
        vm.expectRevert(GuardedSwapper.NotAuthorized.selector);
        guard.swap(address(usd), address(nvnm), 1 ether, 0);
        vm.stopPrank();

        registry.set(stranger, true);
        vm.prank(stranger);
        assertGt(guard.swap(address(usd), address(nvnm), 1 ether, 0), 0);
    }

    function test_swap_unsetFactoryStopsEverySwap() public {
        vm.prank(owner);
        guard.setRouterFactory(address(0));
        vm.prank(keeper);
        vm.expectRevert(GuardedSwapper.NotAuthorized.selector);
        guard.swap(address(usd), address(nvnm), 1 ether, 0);
    }

    function test_swap_rejectsAMarketThatReenters() public {
        // A swap is measured by this contract's balances before and after the inner market; one
        // calling back in would be read across them. The guard fires before authorization, so
        // the reentrant call fails as reentrancy rather than as an unauthorized caller.
        ReenteringMarket market = new ReenteringMarket(guard);
        vm.prank(owner);
        guard.setGuards(address(market), 50 ether);
        vm.expectRevert(ReentrancyGuard.Reentrancy.selector);
        _swap(10 ether);
    }

    function test_swap_judgesWhatArrivedNotWhatTheMarketReports() public {
        // Reported at 1:1, delivered at 1:2: the floor sees the delivered price, and the NVNM
        // the swapper already holds is not there to make up the difference.
        OverstatingMarket market = new OverstatingMarket();
        nvnm.mint(address(market), 100 ether);
        nvnm.mint(address(guard), 100 ether);
        vm.prank(owner);
        guard.setGuards(address(market), 50 ether);

        vm.expectRevert(GuardedSwapper.PriceBelowFloor.selector);
        _swap(10 ether);
        assertEq(nvnm.balanceOf(address(guard)), 100 ether);
    }

    function test_swap_rejectsAMarketThatLeavesInputBehind() public {
        HalfTakingMarket market = new HalfTakingMarket();
        nvnm.mint(address(market), 100 ether);
        vm.prank(owner);
        guard.setGuards(address(market), 50 ether);

        // The price clears the floor, but half the input would stay in the swapper.
        vm.expectRevert(GuardedSwapper.PartialFill.selector);
        _swap(10 ether);
    }
}
