// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { GuardedSwapper } from "../src/GuardedSwapper.sol";
import { MockERC20 } from "./support/MockERC20.sol";
import { MockSwapPool } from "./support/MockSwapPool.sol";
import { Test } from "forge-std/Test.sol";

/// @dev Stands in for `FeeRouterFactory`: `keeper` plays a router it deployed.
contract MockRouterRegistry {
    mapping(address => bool) public isRouter;

    function set(address account, bool active) external {
        isRouter[account] = active;
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
        usd = new MockERC20("nvmnUSD", "nvmnUSD");
        nvnm = new MockERC20("NVNM", "NVNM");
        pool = new MockSwapPool(address(usd), address(nvnm));
        usd.mint(address(pool), 1000 ether);
        nvnm.mint(address(pool), 1000 ether); // spot price 1:1

        registry = new MockRouterRegistry();
        registry.set(keeper, true);

        guard = new GuardedSwapper(owner, address(usd), address(nvnm));
        vm.startPrank(owner);
        guard.setGuards(address(pool), 50 ether, 500, 2000); // cap 50, -5% floor, alpha 20%
        guard.setDriftBand(1000); // the EMA may not decay past -10% of the seeded price
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
        uint256 out = _swap(10 ether); // x*y=k: 1000*10/1010 ≈ 9.9 -> ~1% impact, within 5%
        assertEq(nvnm.balanceOf(keeper), out);
        assertGt(out, 9.8 ether);
        assertLt(guard.emaPrice(), 1 ether); // EMA followed the (slightly lower) execution price
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
        vm.prank(owner); // an unconfigured swapper has no factory, so only the owner gets past the gate
        vm.expectRevert(GuardedSwapper.NotSeeded.selector);
        fresh.swap(address(usd), address(nvnm), 1 ether, 0);
    }

    function test_swap_wrongPairReverts() public {
        vm.prank(keeper);
        vm.expectRevert(GuardedSwapper.WrongPair.selector);
        guard.swap(address(nvnm), address(usd), 1 ether, 0);
    }

    function test_setGuards_rejectsBpsOverOneHundredPercent() public {
        vm.startPrank(owner);
        vm.expectRevert(GuardedSwapper.InvalidBps.selector);
        guard.setGuards(address(pool), 50 ether, 10_001, 2000);
        vm.expectRevert(GuardedSwapper.InvalidBps.selector);
        guard.setGuards(address(pool), 50 ether, 500, 10_001);
        vm.stopPrank();
    }

    function test_swap_zeroAmountReverts() public {
        vm.prank(keeper);
        vm.expectRevert(GuardedSwapper.ZeroAmount.selector);
        guard.swap(address(usd), address(nvnm), 0, 0);
    }

    function test_onlyOwnerConfigures() public {
        vm.startPrank(keeper);
        vm.expectRevert();
        guard.setGuards(address(pool), 1, 1, 1);
        vm.expectRevert();
        guard.seedPrice(2 ether);
        vm.stopPrank();
    }

    function test_ema_admitsDriftButLimitsCumulativeDrain() public {
        // Small swaps drift the EMA down and keep passing...
        _swap(10 ether);
        _swap(10 ether);
        assertLt(guard.emaPrice(), 1 ether);

        // ...but a large drain (price ~-7% vs the lagging EMA) is rejected...
        vm.prank(keeper);
        vm.expectRevert(GuardedSwapper.PriceBelowFloor.selector);
        guard.swap(address(usd), address(nvnm), 40 ether, 0);

        // ...while normal-sized swaps continue to clear.
        assertGt(_swap(5 ether), 0);
    }

    function test_swap_onlyOwnerAndRoutersMayMoveThePrice() public {
        // An open `swap` is near-free EMA manipulation: the caller keeps the output and trades
        // at the pool's real price. Only the owner and the factory's routers get in.
        vm.prank(stranger);
        vm.expectRevert(GuardedSwapper.NotAuthorized.selector);
        guard.swap(address(usd), address(nvnm), 1 ether, 0);

        registry.set(stranger, true);
        vm.prank(stranger);
        assertGt(guard.swap(address(usd), address(nvnm), 1 ether, 0), 0);

        usd.mint(owner, 10 ether);
        vm.startPrank(owner);
        usd.approve(address(guard), type(uint256).max);
        assertGt(guard.swap(address(usd), address(nvnm), 1 ether, 0), 0);
        vm.stopPrank();
    }

    function test_swap_unsetFactoryLeavesOwnerOnly() public {
        vm.prank(owner);
        guard.setRouterFactory(address(0));
        vm.prank(keeper);
        vm.expectRevert(GuardedSwapper.NotAuthorized.selector);
        guard.swap(address(usd), address(nvnm), 1 ether, 0);
    }

    /// @dev Swap 5 NVNM-worth up to `rounds` times, stopping at the first rejection.
    function _walkPriceDown(uint256 rounds) internal returns (uint256 cleared) {
        for (uint256 i; i < rounds; ++i) {
            vm.prank(keeper);
            try guard.swap(address(usd), address(nvnm), 5 ether, 0) {
                ++cleared;
            } catch {
                return cleared;
            }
        }
    }

    function test_driftBand_stopsTheEmaBeingWalkedDown() public {
        // Each swap lands just inside `maxDeviationBps`, so an EMA-only floor decays with the
        // price it guards and never binds. The reference band is what halts the walk.
        uint256 rounds = 100;
        uint256 clearedWithBand = _walkPriceDown(rounds);
        assertLt(clearedWithBand, rounds, "the band must reject a swap eventually");
        assertGe(guard.emaPrice(), 0.9 ether, "EMA never sinks below the reference band");

        setUp(); // fresh pool and price
        vm.prank(owner);
        guard.setDriftBand(10_000); // disable the reference leg: EMA-only, as before the fix
        assertEq(_walkPriceDown(rounds), rounds, "EMA-only floor never binds");
        // ~0.46 measured: 100 swaps walk it to roughly half the seeded price, and nothing in
        // the EMA leg alone stops the walk continuing.
        assertLt(guard.emaPrice(), 0.9 ether, "and the price is walked past the band");
    }

    function test_setDriftBand_rejectsBpsOverOneHundredPercent() public {
        vm.prank(owner);
        vm.expectRevert(GuardedSwapper.InvalidBps.selector);
        guard.setDriftBand(10_001);
    }

    function test_ema_manipulatedHighPrintCannotRatchetTheFloor() public {
        // Router creation is permissionless, so a hostile router can print one swap at a
        // pumped price. The print pays out in full, but its pull on the EMA is clamped to the
        // deviation band — otherwise the floor ratchets above the honest price and every later
        // buyback reverts until the owner reseeds.
        nvnm.mint(address(pool), 9000 ether); // pump to ~10:1, far above the +5% band
        _swap(1 ether);
        // Clamped EMA input is exactly ema * 1.05, at 20% weight: 1.05*0.2 + 1*0.8 = 1.01.
        assertEq(guard.emaPrice(), 1.01 ether, "EMA absorbs the clamped print only");

        // Back at an honest 1:1 market the floor has not moved out from under real prices.
        MockSwapPool honest = new MockSwapPool(address(usd), address(nvnm));
        usd.mint(address(honest), 1000 ether);
        nvnm.mint(address(honest), 1000 ether);
        vm.prank(owner);
        guard.setGuards(address(honest), 50 ether, 500, 2000);
        assertGt(_swap(1 ether), 0, "honest-priced swaps keep clearing");
    }
}
