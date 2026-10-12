// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NVNMStaking} from "../src/NVNMStaking.sol";
import {MockBondGateway} from "./support/MockBondGateway.sol";
import {MockERC20} from "./support/MockERC20.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";

/// @dev Random stakes, exits, deposits, compounds, claims, bonds and bridge slashes by three
///      users over two validators. A call the contract refuses is simply not a step.
contract StakingHandler is Test {
    NVNMStaking immutable staking;
    MockERC20 immutable nvnm;
    MockERC20 immutable usd;
    MockBondGateway immutable gateway;
    address[2] public validators = [makeAddr("v1"), makeAddr("v2")];
    address[3] public users = [makeAddr("u1"), makeAddr("u2"), makeAddr("u3")];
    uint256 public deposited; // reward token in
    uint256 public claimed; // reward token out

    constructor(NVNMStaking staking_, MockERC20 nvnm_, MockERC20 usd_, MockBondGateway gateway_) {
        (staking, nvnm, usd, gateway) = (staking_, nvnm_, usd_, gateway_);
        for (uint256 i; i < users.length; ++i) {
            nvnm.mint(users[i], 1e30);
            vm.prank(users[i]);
            nvnm.approve(address(staking), type(uint256).max);
        }
        nvnm.mint(address(this), 1e30);
        nvnm.approve(address(staking), type(uint256).max);
        usd.mint(address(this), 1e30);
        usd.approve(address(staking), type(uint256).max);
    }

    function stake(uint256 u, uint256 v, uint256 amount) external {
        vm.prank(users[u % 3]);
        try staking.stake(validators[v % 2], bound(amount, 1, 1e24)) {} catch {}
    }

    function unstake(uint256 u, uint256 v, uint256 amount) external {
        (address user, address val) = (users[u % 3], validators[v % 2]);
        uint256 have = staking.stakedOf(val, user);
        if (have == 0) return;
        vm.prank(user);
        try staking.unstake(val, bound(amount, 1, have)) {} catch {}
    }

    function withdraw(uint256 u, uint256 v) external {
        vm.prank(users[u % 3]);
        try staking.withdraw(validators[v % 2]) {} catch {}
    }

    function deposit(uint256 v, uint256 amount) external {
        amount = bound(amount, 1, 1e24);
        try staking.depositReward(validators[v % 2], amount) {
            deposited += amount;
        } catch {}
    }

    function compound(uint256 v, uint256 amount) external {
        try staking.compoundReward(validators[v % 2], bound(amount, 1, 1e22)) {} catch {}
    }

    function claim(uint256 u, uint256 v) external {
        vm.prank(users[u % 3]);
        try staking.claim(validators[v % 2]) returns (uint256 got) {
            claimed += got;
        } catch {}
    }

    function bond(uint256 v, uint256 amount) external {
        gateway.deliverBond(staking, validators[v % 2], bound(amount, 1, 1e24));
    }

    function resign(uint256 v) external {
        vm.prank(validators[v % 2]);
        try staking.resignCandidate() {} catch {}
    }

    function withdrawBond(uint256 v) external {
        vm.prank(validators[v % 2]);
        try staking.withdrawBond() {} catch {}
    }

    function slash(uint256 v, uint256 amount) external {
        gateway.deliverSlash(staking, validators[v % 2], bound(amount, 1, 1e24));
    }

    function warp(uint256 by) external {
        vm.warp(block.timestamp + bound(by, 1, 2 days));
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 200
contract NVNMStakingInvariantTest is StdInvariant, Test {
    NVNMStaking staking;
    MockERC20 nvnm;
    MockERC20 usd;
    StakingHandler handler;

    function setUp() public {
        address owner = makeAddr("safe");
        nvnm = new MockERC20("NVNM", "NVNM");
        usd = new MockERC20("nUSD", "nUSD");
        staking = NVNMStaking(LibClone.deployERC1967(address(new NVNMStaking())));
        staking.initialize(owner, address(nvnm), address(usd));
        MockBondGateway gateway = new MockBondGateway(nvnm);
        vm.startPrank(owner);
        staking.setBondGateway(address(gateway));
        staking.setUnbondingPeriod(1 days);
        staking.setRewardDuration(1 hours);
        vm.stopPrank();
        handler = new StakingHandler(staking, nvnm, usd, gateway);
        targetContract(address(handler));
    }

    /// @dev Every token the books promise is in the contract: live stake, exiting stake, bonds,
    ///      and what slashing took but has not yet sent home.
    function invariant_theStakeTokenCoversTheBooks() public view {
        uint256 owed;
        for (uint256 v; v < 2; ++v) {
            address val = handler.validators(v);
            owed += staking.totalStaked(val) + staking.bondOf(val) + staking.seizedPendingOf(val);
            for (uint256 u; u < 3; ++u) {
                (uint256 exiting,) = staking.pendingUnstakeOf(val, handler.users(u));
                owed += exiting;
            }
        }
        assertGe(nvnm.balanceOf(address(staking)), owed);
    }

    /// @dev Shares never pay out more than the pool holds.
    function invariant_sharesNeverExceedThePool() public view {
        for (uint256 v; v < 2; ++v) {
            address val = handler.validators(v);
            uint256 live;
            for (uint256 u; u < 3; ++u) {
                live += staking.stakedOf(val, handler.users(u));
            }
            assertLe(live, staking.totalStaked(val));
        }
    }

    /// @dev Rewards come only from deposits: what is claimable is in the contract, and nothing
    ///      more than was deposited ever leaves.
    function invariant_rewardsNeverExceedDeposits() public view {
        uint256 earned;
        for (uint256 v; v < 2; ++v) {
            for (uint256 u; u < 3; ++u) {
                earned += staking.earned(handler.validators(v), handler.users(u));
            }
        }
        assertGe(usd.balanceOf(address(staking)), earned);
        assertLe(handler.claimed() + earned, handler.deposited());
    }
}
