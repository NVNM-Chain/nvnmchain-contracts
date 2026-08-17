// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { NVNMStaking } from "../src/NVNMStaking.sol";
import { MockERC20 } from "./support/MockERC20.sol";
import { Test } from "forge-std/Test.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { LibClone } from "solady/utils/LibClone.sol";

contract NVNMStakingV2 is NVNMStaking {
    function version() external pure returns (uint256) {
        return 2;
    }
}

abstract contract NVNMStakingTestBase is Test {
    NVNMStaking staking;
    MockERC20 nvnm; // stake token
    MockERC20 usd; // reward token (fee stablecoin)

    address owner = makeAddr("safe");
    address validator = makeAddr("validator");
    address validator2 = makeAddr("validator2");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address treasury = makeAddr("treasury");

    function setUp() public {
        nvnm = new MockERC20("NVNM", "NVNM");
        usd = new MockERC20("nvmnUSD", "nvmnUSD");
        address impl = address(new NVNMStaking());
        staking = NVNMStaking(LibClone.deployERC1967(impl));
        staking.initialize(owner, address(nvnm), address(usd));

        for (address who = alice;; who = bob) {
            nvnm.mint(who, 1000 ether);
            vm.prank(who);
            nvnm.approve(address(staking), type(uint256).max);
            if (who == bob) break;
        }
        // Reward depositor (stands in for the fee-routing layer).
        usd.mint(address(this), 1_000_000 ether);
        usd.approve(address(staking), type(uint256).max);
    }

    function _stake(address who, address val, uint256 amt) internal {
        vm.prank(who);
        staking.stake(val, amt);
    }
}

/// @dev Split across two contracts (staking/rewards/exits here, candidacy and elections in
///      `NVNMStakingElectionTest`): one contract holding every test sits on solc's via-IR
///      "Tag too large" code-size cliff.
contract NVNMStakingTest is NVNMStakingTestBase {
    // -- staking basics ------------------------------------------------------
    function test_stake_and_unstake() public {
        _stake(alice, validator, 100 ether);
        assertEq(staking.stakedOf(validator, alice), 100 ether);
        assertEq(staking.totalStaked(validator), 100 ether);
        assertEq(nvnm.balanceOf(address(staking)), 100 ether);

        vm.prank(alice);
        staking.unstake(validator, 40 ether);
        assertEq(staking.stakedOf(validator, alice), 60 ether);
        assertEq(nvnm.balanceOf(alice), 940 ether);
    }

    function test_stake_zeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(NVNMStaking.ZeroAmount.selector);
        staking.stake(validator, 0);
    }

    function test_unstake_moreThanStakedReverts() public {
        _stake(alice, validator, 100 ether);
        vm.prank(alice);
        vm.expectRevert(NVNMStaking.InsufficientStake.selector);
        staking.unstake(validator, 101 ether);
    }

    // -- reward distribution -------------------------------------------------
    function test_depositReward_noStakersReverts() public {
        vm.expectRevert(NVNMStaking.NoStakers.selector);
        staking.depositReward(validator, 100 ether);
    }

    function test_singleStaker_getsAllRewards() public {
        _stake(alice, validator, 100 ether);
        staking.depositReward(validator, 500 ether);
        assertEq(staking.earned(validator, alice), 500 ether);

        vm.prank(alice);
        uint256 claimed = staking.claim(validator);
        assertEq(claimed, 500 ether);
        assertEq(usd.balanceOf(alice), 500 ether);
        assertEq(staking.earned(validator, alice), 0);
    }

    function test_depositReward_smallDepositIntoLargePoolIsNotTruncated() public {
        // 1M NVNM staked mints ~1e27 shares (the 1e3 virtual-offset scale). An under-scaled
        // accumulator truncates a 5e8-unit deposit (500 USDC at 6 decimals) to zero: the
        // transfer lands, no delegator is ever credited, and the tokens strand.
        nvnm.mint(alice, 1_000_000 ether);
        _stake(alice, validator, 1_000_000 ether);
        staking.depositReward(validator, 5e8);
        assertApproxEqAbs(staking.earned(validator, alice), 5e8, 1);
    }

    function test_rewards_splitProRata() public {
        _stake(alice, validator, 300 ether);
        _stake(bob, validator, 100 ether); // 3:1
        staking.depositReward(validator, 400 ether);
        assertEq(staking.earned(validator, alice), 300 ether);
        assertEq(staking.earned(validator, bob), 100 ether);
    }

    function test_rewards_onlyCountStakeAtDepositTime() public {
        // alice stakes, reward #1 is hers alone; then bob joins, reward #2 splits.
        _stake(alice, validator, 100 ether);
        staking.depositReward(validator, 100 ether); // all alice
        _stake(bob, validator, 100 ether);
        staking.depositReward(validator, 100 ether); // 50/50

        assertEq(staking.earned(validator, alice), 150 ether);
        assertEq(staking.earned(validator, bob), 50 ether);
    }

    function test_stakingMore_doesNotStealPastRewards() public {
        _stake(alice, validator, 100 ether);
        staking.depositReward(validator, 100 ether); // alice earned 100
        _stake(alice, validator, 900 ether); // stake up AFTER the deposit
        // The pre-existing 100 must not be diluted or re-counted.
        assertEq(staking.earned(validator, alice), 100 ether);
        staking.depositReward(validator, 50 ether); // now on 1000 staked, still all alice
        assertEq(staking.earned(validator, alice), 150 ether);
    }

    function test_perValidator_isolation() public {
        _stake(alice, validator, 100 ether);
        _stake(bob, validator2, 100 ether);
        staking.depositReward(validator, 100 ether);
        // Only validator's stakers earn; validator2's pool is untouched.
        assertEq(staking.earned(validator, alice), 100 ether);
        assertEq(staking.earned(validator2, bob), 0);
    }

    function test_unstake_keepsAccruedClaimable() public {
        _stake(alice, validator, 100 ether);
        staking.depositReward(validator, 100 ether);
        vm.prank(alice);
        staking.unstake(validator, 100 ether); // fully exit
        // Accrued rewards survive the exit.
        assertEq(staking.earned(validator, alice), 100 ether);
        vm.prank(alice);
        assertEq(staking.claim(validator), 100 ether);
    }

    // -- compounding ---------------------------------------------------------
    function test_compoundReward_growsAllStakesProRata() public {
        _stake(alice, validator, 300 ether);
        _stake(bob, validator, 100 ether);
        nvnm.mint(address(this), 100 ether);
        nvnm.approve(address(staking), 100 ether);

        staking.compoundReward(validator, 100 ether); // e.g. fee-buyback proceeds
        // 1 wei tolerance: the virtual-offset share rate rounds in the pool's favor.
        assertApproxEqAbs(staking.stakedOf(validator, alice), 375 ether, 1, "3/4 of the growth");
        assertApproxEqAbs(staking.stakedOf(validator, bob), 125 ether, 1, "1/4 of the growth");
        // Shares and the stablecoin reward accumulator are untouched (first mint scales by the
        // 1e3 virtual-share offset).
        assertEq(staking.sharesOf(validator, alice), 300 ether * 1e3);
        assertEq(staking.earned(validator, alice), 0);
    }

    function test_compoundReward_noStakersReverts() public {
        nvnm.mint(address(this), 1 ether);
        nvnm.approve(address(staking), 1 ether);
        vm.expectRevert(NVNMStaking.NoStakers.selector);
        staking.compoundReward(validator, 1 ether);
    }

    function test_slash_doesNotCollapseDelegatorPool() public {
        _stake(alice, validator, 100 ether);
        vm.prank(owner);
        staking.setCandidacyBond(10 ether);
        nvnm.mint(validator, 10 ether);
        vm.startPrank(validator);
        nvnm.approve(address(staking), 10 ether);
        staking.registerCandidate();
        vm.stopPrank();

        vm.prank(owner);
        staking.slash(validator, 10_000, treasury);

        nvnm.mint(address(this), 1 ether);
        nvnm.approve(address(staking), 1 ether);
        staking.compoundReward(validator, 1 ether); // pool still live
        assertApproxEqAbs(staking.stakedOf(validator, alice), 101 ether, 1);
    }

    function test_stake_inflationAttackUnprofitable() public {
        // Classic first-depositor inflation: 1 wei stake, then a large donation via
        // compoundReward to push the share rate so the victim mints zero shares.
        address attacker = alice;
        address victim = bob;
        vm.startPrank(attacker);
        nvnm.approve(address(staking), type(uint256).max);
        staking.stake(validator, 1);
        staking.compoundReward(validator, 100 ether);
        vm.stopPrank();

        _stake(victim, validator, 100 ether);
        // The virtual offset keeps the victim's mint proportional: they recover ~all of their
        // 100-ether deposit (a bounded sub-0.1% griefing residual from the 1-wei-first-stake
        // rounding), and the attacker cannot exit with more than they put in.
        assertApproxEqRel(staking.stakedOf(validator, victim), 100 ether, 1e15); // within 0.1%
        uint256 attackerValue = staking.stakedOf(validator, attacker);
        assertLe(attackerValue, 100 ether + 1); // donation not recouped from the victim

        vm.prank(victim);
        staking.unstake(validator, 99.9 ether); // victim can exit ~all of their stake
    }

    function test_stake_zeroSharesBackstopReverts() public {
        // Push the rate past the virtual offset with tiny magnitudes: 1 wei staked, 3e6 wei
        // compounded → a 1-wei stake would mint 0 shares and must revert, not silently donate.
        vm.startPrank(alice);
        nvnm.approve(address(staking), type(uint256).max);
        staking.stake(validator, 1);
        staking.compoundReward(validator, 3e6);
        vm.stopPrank();

        vm.startPrank(bob);
        nvnm.approve(address(staking), 1);
        vm.expectRevert(NVNMStaking.ZeroShares.selector);
        staking.stake(validator, 1);
        vm.stopPrank();
    }

    // -- unbonding -----------------------------------------------------------
    function test_unbonding_zeroPeriod_isImmediate() public {
        // Default period 0: unstake pays out instantly (covered above; assert explicitly).
        _stake(alice, validator, 100 ether);
        vm.prank(alice);
        staking.unstake(validator, 100 ether);
        assertEq(nvnm.balanceOf(alice), 1000 ether);
    }

    function test_unbonding_delaysWithdrawal() public {
        vm.prank(owner);
        staking.setUnbondingPeriod(7 days);
        _stake(alice, validator, 100 ether);

        vm.prank(alice);
        staking.unstake(validator, 100 ether);
        assertEq(nvnm.balanceOf(alice), 900 ether, "no instant payout");
        (uint256 amount, uint256 releaseAt) = staking.pendingUnstakeOf(validator, alice);
        assertEq(amount, 100 ether);
        assertEq(releaseAt, block.timestamp + 7 days);

        vm.prank(alice);
        vm.expectRevert(NVNMStaking.StillUnbonding.selector);
        staking.withdraw(validator);

        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        assertEq(staking.withdraw(validator), 100 ether);
        assertEq(nvnm.balanceOf(alice), 1000 ether);
        (amount,) = staking.pendingUnstakeOf(validator, alice);
        assertEq(amount, 0);
    }

    function test_unbonding_newRequestResetsClock() public {
        // Absolute warps only: via-ir rematerializes TIMESTAMP, so reading block.timestamp
        // in test code after vm.warp is unreliable.
        uint256 t0 = 1_000_000;
        vm.warp(t0);
        vm.prank(owner);
        staking.setUnbondingPeriod(7 days);
        _stake(alice, validator, 200 ether);

        vm.prank(alice);
        staking.unstake(validator, 100 ether); // matures at t0 + 7d
        vm.warp(t0 + 6 days);
        vm.prank(alice);
        staking.unstake(validator, 100 ether); // resets the aggregate bucket to t0 + 13d

        vm.warp(t0 + 7 days); // first request alone would have matured; the bucket has not
        vm.prank(alice);
        vm.expectRevert(NVNMStaking.StillUnbonding.selector);
        staking.withdraw(validator);

        vm.warp(t0 + 13 days);
        vm.prank(alice);
        assertEq(staking.withdraw(validator), 200 ether);
    }

    function test_unbonding_stakeStopsEarningAndElecting() public {
        vm.startPrank(owner);
        staking.setUnbondingPeriod(7 days);
        staking.setCandidate(validator, true);
        staking.setCommitteeConfig(21, 1, 0);
        vm.stopPrank();
        _stake(alice, validator, 100 ether);

        vm.prank(alice);
        staking.unstake(validator, 100 ether);
        // No longer elected...
        (address[] memory vals,) = staking.computeCommittee();
        assertEq(vals.length, 0);
        // ...and rewards can no longer be deposited toward it (no live stake).
        vm.expectRevert(NVNMStaking.NoStakers.selector);
        staking.depositReward(validator, 100 ether);
    }

    function test_unbonding_withdrawNothingReverts() public {
        vm.prank(alice);
        vm.expectRevert(NVNMStaking.NothingToWithdraw.selector);
        staking.withdraw(validator);
    }

    function test_unbonding_configAuthAndCap() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        staking.setUnbondingPeriod(1 days);

        vm.prank(owner);
        vm.expectRevert(NVNMStaking.InvalidPeriod.selector);
        staking.setUnbondingPeriod(31 days);
    }

    // -- slashing ------------------------------------------------------------
    function test_slash_doesNotTouchDelegators() public {
        _stake(alice, validator, 300 ether);
        _stake(bob, validator, 100 ether);

        vm.prank(owner);
        assertEq(staking.slash(validator, 5000, treasury), 0);
        assertEq(staking.stakedOf(validator, alice), 300 ether);
        assertEq(staking.stakedOf(validator, bob), 100 ether);
        assertEq(staking.totalStaked(validator), 400 ether);
    }

    function test_slash_systemCallerAllowed_strangerNot() public {
        vm.prank(owner);
        staking.setCandidacyBond(100 ether);
        nvnm.mint(validator, 100 ether);
        vm.startPrank(validator);
        nvnm.approve(address(staking), 100 ether);
        staking.registerCandidate();
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(NVNMStaking.NotAuthorized.selector);
        staking.slash(validator, 1000, treasury);

        vm.prank(address(0)); // the protocol system caller
        assertEq(staking.slash(validator, 1000, treasury), 10 ether);
        assertEq(staking.bondOf(validator), 90 ether);
    }

    function test_slash_leavesPendingDelegatorsWhole() public {
        vm.prank(owner);
        staking.setUnbondingPeriod(7 days);
        _stake(alice, validator, 100 ether);
        vm.prank(alice);
        staking.unstake(validator, 100 ether);

        vm.prank(owner);
        assertEq(staking.slash(validator, 5000, treasury), 0);

        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        assertEq(staking.withdraw(validator), 100 ether);
    }

    function test_slash_paramValidation() public {
        vm.startPrank(owner);
        vm.expectRevert(NVNMStaking.InvalidBps.selector);
        staking.slash(validator, 0, treasury);
        vm.expectRevert(NVNMStaking.InvalidBps.selector);
        staking.slash(validator, 10_001, treasury);
        vm.expectRevert(NVNMStaking.ZeroAddress.selector);
        staking.slash(validator, 1000, address(0));
        vm.stopPrank();
    }

    function test_slash_seizesCandidacyBond() public {
        vm.prank(owner);
        staking.setCandidacyBond(50 ether);
        nvnm.mint(validator, 50 ether);
        vm.startPrank(validator);
        nvnm.approve(address(staking), 50 ether);
        staking.registerCandidate();
        vm.stopPrank();
        _stake(alice, validator, 100 ether);

        vm.prank(owner);
        uint256 seized = staking.slash(validator, 5000, treasury);
        assertEq(seized, 25 ether, "half the acquired bond only");
        assertEq(staking.bondOf(validator), 25 ether);
        assertEq(staking.stakedOf(validator, alice), 100 ether, "delegators untouched");

        vm.prank(owner);
        staking.slash(validator, 10_000, treasury); // rest of the bond
        assertEq(staking.bondOf(validator), 0);

        uint256 before = nvnm.balanceOf(validator);
        vm.prank(validator);
        staking.resignCandidate();
        assertEq(nvnm.balanceOf(validator), before, "already-seized bond is not refunded");
    }

    function test_slash_reducesElectionSeats() public {
        vm.startPrank(owner);
        staking.setCandidate(validator, true);
        staking.setCommitteeConfig(21, 1, 0);
        vm.stopPrank();
        _stake(alice, validator, 300 ether);

        vm.prank(owner);
        staking.slash(validator, 10_000, treasury); // bond is 0; still elected on delegated
        (address[] memory vals, uint256[] memory seats) = staking.computeCommittee();
        assertEq(vals[0], validator);
        assertEq(seats[0], 1);
    }

    // -- lifecycle -----------------------------------------------------------
    function test_initialize_zeroTokenReverts() public {
        NVNMStaking fresh = NVNMStaking(LibClone.deployERC1967(address(new NVNMStaking())));
        vm.expectRevert(NVNMStaking.ZeroAddress.selector);
        fresh.initialize(owner, address(0), address(usd));
        vm.expectRevert(NVNMStaking.ZeroAddress.selector);
        fresh.initialize(owner, address(nvnm), address(0));
    }

    function test_upgrade_preservesStakeAndRewards_onlyOwner() public {
        _stake(alice, validator, 100 ether);
        staking.depositReward(validator, 100 ether);

        address v2 = address(new NVNMStakingV2());
        vm.prank(alice);
        vm.expectRevert(); // Ownable.Unauthorized
        staking.upgradeToAndCall(v2, "");

        vm.prank(owner);
        staking.upgradeToAndCall(v2, "");
        assertEq(NVNMStakingV2(address(staking)).version(), 2);
        assertEq(staking.stakedOf(validator, alice), 100 ether);
        assertEq(staking.earned(validator, alice), 100 ether);
    }
}

contract NVNMStakingElectionTest is NVNMStakingTestBase {
    /// @dev Fills the candidate list to MAX_CANDIDATES via bonded self-registration.
    function _fillCandidates() internal {
        vm.prank(owner);
        staking.setCandidacyBond(1 ether);
        for (uint256 i; i < 256; ++i) {
            address c = address(uint160(0x10000 + i));
            nvnm.mint(c, 1 ether);
            vm.startPrank(c);
            nvnm.approve(address(staking), 1 ether);
            staking.registerCandidate();
            vm.stopPrank();
        }
    }

    function test_candidacy_registrationCapped() public {
        _fillCandidates();
        nvnm.mint(alice, 1 ether);
        vm.startPrank(alice);
        nvnm.approve(address(staking), 1 ether);
        vm.expectRevert(NVNMStaking.CandidateListFull.selector);
        staking.registerCandidate();
        vm.stopPrank();
    }

    function test_candidacy_ownerCurationCapped() public {
        // The cap is what keeps the node's election read inside its gas budget, so owner
        // curation is bounded by it too — not just permissionless registration.
        _fillCandidates();
        vm.prank(owner);
        vm.expectRevert(NVNMStaking.CandidateListFull.selector);
        staking.setCandidate(alice, true);
    }

    function test_election_readFitsNodeGasBudgetWhenFull() public {
        // A full candidate list is the worst case for the per-epoch election read; running out
        // of gas would drop every node to the registry fallback at once.
        _fillCandidates();
        vm.prank(owner);
        staking.setCommitteeConfig(21, 1, 0);

        uint256 gasBefore = gasleft();
        (address[] memory vals,) = staking.computeCommittee();
        uint256 used = gasBefore - gasleft();

        assertEq(vals.length, 21, "full list still elects the committee");
        // ~0.99M measured against a 30M node budget; asserted far tighter so eroded headroom
        // fails the test rather than passing quietly.
        assertLt(used, 5_000_000, "election read must fit the node's call budget");
    }

    // -- committee election --------------------------------------------------
    function _electionSetup() internal {
        vm.startPrank(owner);
        staking.setCandidate(validator, true);
        staking.setCandidate(validator2, true);
        staking.setCommitteeConfig(21, 1, 0); // top-21, equal acquired/delegated weight, no cap
        vm.stopPrank();
    }

    function test_election_ranksByStakeOneSeatEach() public {
        _electionSetup();
        _stake(alice, validator, 300 ether);
        _stake(bob, validator2, 150 ether);

        (address[] memory vals, uint256[] memory seats) = staking.computeCommittee();
        assertEq(vals.length, 2);
        assertEq(vals[0], validator);
        assertEq(seats[0], 1);
        assertEq(vals[1], validator2);
        assertEq(seats[1], 1);
    }

    function test_election_overweightsAcquiredStake() public {
        vm.startPrank(owner);
        staking.setCandidate(validator, true);
        staking.setCandidacyBond(50 ether);
        staking.setCommitteeConfig(21, 10, 0); // acquired counts 10x
        vm.stopPrank();
        nvnm.mint(validator2, 50 ether);
        vm.startPrank(validator2);
        nvnm.approve(address(staking), 50 ether);
        staking.registerCandidate();
        vm.stopPrank();
        _stake(alice, validator, 400 ether); // weight 400
        // validator2: 50*10 + 0 = 500 > 400, ranks first despite less delegated.
        (address[] memory vals,) = staking.computeCommittee();
        assertEq(vals[0], validator2);
        assertEq(vals[1], validator);
    }

    function test_election_respectsCommitteeSize() public {
        _electionSetup();
        vm.prank(owner);
        staking.setCommitteeConfig(1, 1, 0);
        _stake(alice, validator, 300 ether);
        _stake(bob, validator2, 200 ether);

        (address[] memory vals, uint256[] memory seats) = staking.computeCommittee();
        assertEq(vals.length, 1);
        assertEq(vals[0], validator);
        assertEq(seats[0], 1);
    }

    function test_election_excludesZeroWeightAndNonCandidates() public {
        _electionSetup();
        address stranger = makeAddr("nonCandidate");
        _stake(bob, stranger, 500 ether); // staked but not a candidate

        (address[] memory vals,) = staking.computeCommittee();
        assertEq(vals.length, 0);
    }

    function test_election_enforcesDelegationCap() public {
        vm.prank(owner);
        staking.setCommitteeConfig(21, 1, 100 ether);
        _stake(alice, validator, 100 ether);
        vm.prank(bob);
        vm.expectRevert(NVNMStaking.DelegationCap.selector);
        staking.stake(validator, 1 ether);
    }

    function test_election_unconfiguredElectsNobody() public {
        // Empty, not a revert: the node maps a deterministic revert to a stalled epoch feed,
        // while an empty committee drops every node into the registry fallback together.
        (address[] memory vals, uint256[] memory seats) = staking.computeCommittee();
        assertEq(vals.length, 0);
        assertEq(seats.length, 0);
    }

    function test_election_delegationCapBindsAtReadTime() public {
        _electionSetup();
        _stake(alice, validator, 300 ether);
        _stake(bob, validator2, 400 ether);
        (address[] memory vals,) = staking.computeCommittee();
        assertEq(vals[0], validator2); // 400 > 300 uncapped

        // Lowering the cap must clamp the incumbents' election weight too, or tightening
        // delegation influence exempts exactly the entrenched pools it targets. Both pools
        // clamp to 50 and the tie falls back to candidate-list order.
        vm.prank(owner);
        staking.setCommitteeConfig(21, 1, 50 ether);
        (vals,) = staking.computeCommittee();
        assertEq(vals[0], validator);
    }

    function test_election_minSeatsElectsNobodyBelowTheFloor() public {
        // Without the floor, a thinning candidate set walks fault tolerance down seat by
        // seat; below it the election seats nobody and every node falls back together.
        _electionSetup();
        _stake(alice, validator, 100 ether);
        _stake(bob, validator2, 100 ether);

        vm.prank(owner);
        staking.setMinSeats(3);
        (address[] memory vals,) = staking.computeCommittee();
        assertEq(vals.length, 0, "two seats below a floor of three elects nobody");

        vm.prank(owner);
        staking.setMinSeats(2);
        (vals,) = staking.computeCommittee();
        assertEq(vals.length, 2, "at the floor the committee seats");
        assertEq(staking.minSeats(), 2);
    }

    function test_election_minSeatsOnlyOwnerSets() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        staking.setMinSeats(3);
    }

    function test_election_absurdAcquiredWeightSaturatesInsteadOfReverting() public {
        // The weight formula must be total: a checked-overflow revert here is deterministic,
        // and the node maps it to a stalled epoch feed rather than the registry fallback.
        vm.startPrank(owner);
        staking.setCandidacyBond(50 ether);
        staking.setCommitteeConfig(21, type(uint256).max, 0);
        vm.stopPrank();
        vm.prank(alice);
        staking.registerCandidate(); // 50e18 bond x 2^256-1 weight overflows unchecked math

        (address[] memory vals,) = staking.computeCommittee();
        assertEq(vals.length, 1);
        assertEq(vals[0], alice);
    }

    function test_election_candidateManagement() public {
        vm.prank(owner);
        staking.setCandidate(validator, true);
        assertEq(staking.candidates().length, 1);

        vm.prank(owner);
        vm.expectRevert(NVNMStaking.AlreadyCandidate.selector);
        staking.setCandidate(validator, true);

        vm.prank(owner);
        staking.setCandidate(validator, false);
        assertEq(staking.candidates().length, 0);

        // Removed candidate no longer electable even with stake.
        vm.startPrank(owner);
        staking.setCommitteeConfig(21, 1, 0);
        vm.stopPrank();
        _stake(alice, validator, 300 ether);
        (address[] memory vals,) = staking.computeCommittee();
        assertEq(vals.length, 0);
    }

    function test_election_onlyOwnerConfigures() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        staking.setCandidate(validator, true);

        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        staking.setCommitteeConfig(1, 1, 0);
    }

    // -- bonded candidacy ----------------------------------------------------
    function test_candidacy_registerWithBond() public {
        vm.prank(owner);
        staking.setCandidacyBond(50 ether);

        vm.prank(alice);
        staking.registerCandidate();
        assertTrue(staking.candidates().length == 1 && staking.candidates()[0] == alice);
        assertEq(staking.bondOf(alice), 50 ether);
        assertEq(nvnm.balanceOf(alice), 950 ether);

        // Electable like any curated candidate.
        vm.prank(owner);
        staking.setCommitteeConfig(21, 1, 0);
        _stake(bob, alice, 100 ether);
        (address[] memory vals,) = staking.computeCommittee();
        assertEq(vals[0], alice);
    }

    function test_candidacy_closedWithoutBondConfig() public {
        vm.prank(alice);
        vm.expectRevert(NVNMStaking.CandidacyClosed.selector);
        staking.registerCandidate();
    }

    function test_candidacy_resignRefundsBond() public {
        // No unbonding period configured, so the refund is immediate.
        vm.prank(owner);
        staking.setCandidacyBond(50 ether);
        vm.prank(alice);
        staking.registerCandidate();

        vm.prank(alice);
        staking.resignCandidate();
        assertEq(staking.candidates().length, 0);
        assertEq(staking.bondOf(alice), 0);
        assertEq(nvnm.balanceOf(alice), 1000 ether);
    }

    /// @dev Bond alice under a 7-day unbonding period and resign her.
    function _resignUnderUnbonding() internal {
        vm.startPrank(owner);
        staking.setUnbondingPeriod(7 days);
        staking.setCandidacyBond(50 ether);
        vm.stopPrank();
        vm.startPrank(alice);
        staking.registerCandidate();
        staking.resignCandidate();
        vm.stopPrank();
    }

    function test_candidacy_resignUnbondsBond() public {
        _resignUnderUnbonding();

        assertEq(staking.candidates().length, 0, "candidacy ends immediately");
        assertEq(nvnm.balanceOf(alice), 950 ether, "bond is not refunded yet");
        (uint256 amount, uint256 releaseAt) = staking.pendingBondOf(alice);
        assertEq(amount, 50 ether);
        assertEq(releaseAt, block.timestamp + 7 days);

        vm.prank(alice);
        vm.expectRevert(NVNMStaking.StillUnbonding.selector);
        staking.withdrawBond();

        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        assertEq(staking.withdrawBond(), 50 ether);
        assertEq(nvnm.balanceOf(alice), 1000 ether);
        (amount, releaseAt) = staking.pendingBondOf(alice);
        assertEq(amount + releaseAt, 0, "bucket cleared");
    }

    function test_candidacy_resigningDoesNotOutrunSlash() public {
        // The reason the bond unbonds at all: without it an operator front-runs its own slash
        // with `resignCandidate` and walks away whole, so nothing is ever at risk.
        _resignUnderUnbonding();

        vm.prank(owner);
        assertEq(staking.slash(alice, 10_000, treasury), 50 ether, "resigned bond still slashable");
        assertEq(nvnm.balanceOf(treasury), 50 ether);

        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        assertEq(staking.withdrawBond(), 0);
        assertEq(nvnm.balanceOf(alice), 950 ether, "nothing left to withdraw");
    }

    function test_candidacy_cannotReRegisterWhileBondUnbonding() public {
        _resignUnderUnbonding();

        vm.prank(alice);
        vm.expectRevert(NVNMStaking.StillUnbonding.selector);
        staking.registerCandidate();

        vm.warp(block.timestamp + 7 days);
        vm.startPrank(alice);
        staking.withdrawBond();
        staking.registerCandidate(); // clean slate: a fresh bond is posted
        vm.stopPrank();
        assertEq(staking.bondOf(alice), 50 ether);
    }

    function test_election_minAcquiredExcludesUnbondedCandidates() public {
        // §7: validator stake is acquired, never delegated. Below the floor, delegation alone
        // must not buy a seat however large it is.
        vm.startPrank(owner);
        staking.setCommitteeConfig(21, 1, 0);
        staking.setCandidacyBond(50 ether);
        staking.setCandidate(validator, true); // curated, posts no bond
        staking.setMinAcquired(50 ether);
        vm.stopPrank();
        _stake(alice, validator, 500 ether); // heavily delegated, still unbonded

        (address[] memory vals,) = staking.computeCommittee();
        assertEq(vals.length, 0, "no bond, no seat");

        // Posting the bond makes the same validator electable.
        nvnm.mint(bob, 50 ether);
        vm.prank(bob);
        staking.registerCandidate();
        (vals,) = staking.computeCommittee();
        assertEq(vals.length, 1);
        assertEq(vals[0], bob);
    }

    function test_election_minAcquiredDefaultsOff() public {
        // The PoA phases curate candidates directly with no bond posted.
        vm.startPrank(owner);
        staking.setCommitteeConfig(21, 1, 0);
        staking.setCandidate(validator, true);
        vm.stopPrank();
        _stake(alice, validator, 100 ether);

        assertEq(staking.minAcquired(), 0);
        (address[] memory vals,) = staking.computeCommittee();
        assertEq(vals.length, 1, "no floor configured, delegated stake elects");
    }

    function test_compoundReward_respectsDelegationCap() public {
        vm.prank(owner);
        staking.setCommitteeConfig(21, 1, 150 ether);
        _stake(alice, validator, 100 ether);

        nvnm.mint(address(this), 100 ether);
        nvnm.approve(address(staking), type(uint256).max);
        vm.expectRevert(NVNMStaking.DelegationCap.selector);
        staking.compoundReward(validator, 60 ether); // 100 + 60 > 150

        staking.compoundReward(validator, 50 ether); // exactly at the cap
        assertEq(staking.totalStaked(validator), 150 ether);
    }

    function test_election_minAcquiredOnlyOwnerSets() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        staking.setMinAcquired(1 ether);
    }

    function test_candidacy_unbondingBondCarriesNoElectionWeight() public {
        vm.prank(owner);
        staking.setCommitteeConfig(21, 1, 0);
        _resignUnderUnbonding();

        (address[] memory vals,) = staking.computeCommittee();
        assertEq(vals.length, 0, "a resigned candidate is not electable on an unbonding bond");
    }

    function test_candidacy_reAddingCancelsTheUnbonding() public {
        // Otherwise the clock keeps running while the validator is electable again, and
        // `withdrawBond` pulls the bond out from under a live candidate.
        _resignUnderUnbonding();
        vm.prank(owner);
        staking.setCandidate(alice, true);

        (uint256 amount, uint256 releaseAt) = staking.pendingBondOf(alice);
        assertEq(amount + releaseAt, 0, "no longer unbonding");
        assertEq(staking.bondOf(alice), 50 ether, "the bond is still posted and at risk");

        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        vm.expectRevert(NVNMStaking.NothingToWithdraw.selector);
        staking.withdrawBond();
    }

    function test_withdrawBond_nothingToWithdrawReverts() public {
        vm.prank(alice);
        vm.expectRevert(NVNMStaking.NothingToWithdraw.selector);
        staking.withdrawBond();
    }

    function test_candidacy_ownerKickRefundsBond() public {
        vm.prank(owner);
        staking.setCandidacyBond(50 ether);
        vm.prank(alice);
        staking.registerCandidate();

        vm.prank(owner);
        staking.setCandidate(alice, false);
        assertEq(nvnm.balanceOf(alice), 1000 ether, "kicked candidate gets bond back");
    }

    function test_candidacy_bondChangeDoesNotAffectHeldBonds() public {
        vm.prank(owner);
        staking.setCandidacyBond(50 ether);
        vm.prank(alice);
        staking.registerCandidate();

        vm.prank(owner);
        staking.setCandidacyBond(500 ether); // raise after alice registered
        vm.prank(alice);
        staking.resignCandidate();
        assertEq(nvnm.balanceOf(alice), 1000 ether, "refund is the bond actually paid");
    }

    function test_candidacy_duplicateAndNonCandidateRevert() public {
        vm.prank(owner);
        staking.setCandidacyBond(50 ether);
        vm.prank(alice);
        staking.registerCandidate();

        vm.prank(alice);
        vm.expectRevert(NVNMStaking.AlreadyCandidate.selector);
        staking.registerCandidate();

        vm.prank(bob);
        vm.expectRevert(NVNMStaking.NotCandidate.selector);
        staking.resignCandidate();
    }
}
