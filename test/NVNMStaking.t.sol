// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {VALIDATOR_REGISTRY} from "../src/Constants.sol";
import {NVNMStaking} from "../src/NVNMStaking.sol";
import {IEquivocation} from "../src/interfaces/IEquivocation.sol";
import {MockBondGateway} from "./support/MockBondGateway.sol";
import {MockERC20} from "./support/MockERC20.sol";
import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {LibClone} from "solady/utils/LibClone.sol";

contract NVNMStakingV2 is NVNMStaking {
    function version() external pure returns (uint256) {
        return 2;
    }
}

abstract contract NVNMStakingTestBase is Test {
    NVNMStaking staking;
    MockERC20 nvnm; // stake token
    MockERC20 usd; // reward token (fee stablecoin)
    MockBondGateway gateway;

    address owner = makeAddr("safe");
    address validator = makeAddr("validator");
    address validator2 = makeAddr("validator2");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        nvnm = new MockERC20("NVNM", "NVNM");
        usd = new MockERC20("nUSD", "nUSD");
        address impl = address(new NVNMStaking());
        staking = NVNMStaking(LibClone.deployERC1967(impl));
        staking.initialize(owner, address(nvnm), address(usd));
        gateway = new MockBondGateway(nvnm);
        vm.prank(owner);
        staking.setBondGateway(address(gateway));

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

    /// @dev `amount` more of `who`'s bond, bridged in from Ethereum.
    function _bond(address who, uint256 amount) internal {
        gateway.deliverBond(staking, who, amount);
    }

    /// @dev Let every deposit so far vest in full.
    function _vest() internal {
        vm.warp(vm.getBlockTimestamp() + staking.rewardDuration());
    }

    /// @dev The node's registry: the four addresses these tests stand, in registry order.
    function _registry() internal view returns (address[] memory eligible) {
        eligible = new address[](4);
        (eligible[0], eligible[1], eligible[2], eligible[3]) = (validator, validator2, alice, bob);
    }

    /// @dev The committee elected from the registry.
    function _committee() internal view returns (address[] memory) {
        return staking.computeCommittee(_registry());
    }

    /// @dev Ask for a `bond` to stand, under the 7-day unbonding period a bond requires.
    function _openRegistration(uint256 bond) internal {
        vm.startPrank(owner);
        staking.setUnbondingPeriod(7 days);
        staking.setMinAcquired(bond);
        vm.stopPrank();
    }

    /// @dev Configure the election (Phase 5), which is what opens slashing.
    function _startElection() internal {
        vm.startPrank(owner);
        if (staking.unbondingPeriod() == 0) staking.setUnbondingPeriod(7 days);
        staking.setCommitteeConfig(21, 1, 0);
        vm.stopPrank();
    }

    uint64 lastEpoch; // the last one evidence named

    /// @dev The mocked registry reads `evidence` as `who` signing twice in `epoch`'s view 3.
    function _registryReads(bytes memory evidence, address who, uint64 epoch) internal {
        vm.mockCall(
            VALIDATOR_REGISTRY, abi.encodeCall(IEquivocation.equivocator, (evidence)), abi.encode(who, epoch, uint64(3))
        );
    }

    /// @dev Evidence against `who` for an epoch nobody has paid for yet.
    function _evidenceAgainst(address who) internal returns (bytes memory evidence) {
        evidence = bytes.concat(keccak256(abi.encode(who)), abi.encode(++lastEpoch));
        _registryReads(evidence, who, lastEpoch);
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
    // Streaming rounds the rate down, so a vested deposit pays out a wei short at most.
    function test_depositReward_noStakersReverts() public {
        vm.expectRevert(NVNMStaking.NoStakers.selector);
        staking.depositReward(validator, 100 ether);
    }

    function test_singleStaker_getsAllRewards() public {
        _stake(alice, validator, 100 ether);
        staking.depositReward(validator, 500 ether);
        _vest();
        assertApproxEqAbs(staking.earned(validator, alice), 500 ether, 1);

        vm.prank(alice);
        uint256 claimed = staking.claim(validator);
        assertApproxEqAbs(claimed, 500 ether, 1);
        assertEq(usd.balanceOf(alice), claimed);
        assertEq(staking.earned(validator, alice), 0);
    }

    function test_depositReward_smallDepositIntoLargePoolIsNotTruncated() public {
        // 1M NVNM staked mints ~1e27 shares (the 1e3 virtual-offset scale). An under-scaled
        // accumulator truncates a 5e8-unit deposit (500 USDC at 6 decimals) to zero: the
        // transfer lands, no delegator is ever credited, and the tokens strand.
        nvnm.mint(alice, 1_000_000 ether);
        _stake(alice, validator, 1_000_000 ether);
        staking.depositReward(validator, 5e8);
        _vest();
        assertApproxEqAbs(staking.earned(validator, alice), 5e8, 1);
    }

    function test_rewards_splitProRata() public {
        _stake(alice, validator, 300 ether);
        _stake(bob, validator, 100 ether); // 3:1
        staking.depositReward(validator, 400 ether);
        _vest();
        assertApproxEqAbs(staking.earned(validator, alice), 300 ether, 1);
        assertApproxEqAbs(staking.earned(validator, bob), 100 ether, 1);
    }

    function test_rewards_countStakeWhileTheyVest() public {
        // alice stakes, reward #1 vests to her alone; then bob joins, reward #2 splits.
        _stake(alice, validator, 100 ether);
        staking.depositReward(validator, 100 ether); // all alice
        _vest();
        _stake(bob, validator, 100 ether);
        staking.depositReward(validator, 100 ether); // 50/50
        _vest();

        assertApproxEqAbs(staking.earned(validator, alice), 150 ether, 1);
        assertApproxEqAbs(staking.earned(validator, bob), 50 ether, 1);
    }

    function test_stakingMore_doesNotStealPastRewards() public {
        _stake(alice, validator, 100 ether);
        staking.depositReward(validator, 100 ether); // alice earned 100
        _vest();
        _stake(alice, validator, 900 ether); // stake up AFTER the deposit
        // The pre-existing 100 must not be diluted or re-counted.
        assertApproxEqAbs(staking.earned(validator, alice), 100 ether, 1);
        staking.depositReward(validator, 50 ether); // now on 1000 staked, still all alice
        _vest();
        assertApproxEqAbs(staking.earned(validator, alice), 150 ether, 2); // a wei per deposit
    }

    function test_perValidator_isolation() public {
        _stake(alice, validator, 100 ether);
        _stake(bob, validator2, 100 ether);
        staking.depositReward(validator, 100 ether);
        _vest();
        // Only validator's stakers earn; validator2's pool is untouched.
        assertApproxEqAbs(staking.earned(validator, alice), 100 ether, 1);
        assertEq(staking.earned(validator2, bob), 0);
    }

    function test_unstake_keepsAccruedClaimable() public {
        _stake(alice, validator, 100 ether);
        staking.depositReward(validator, 100 ether);
        _vest();
        vm.prank(alice);
        staking.unstake(validator, 100 ether); // fully exit
        // Accrued rewards survive the exit.
        assertApproxEqAbs(staking.earned(validator, alice), 100 ether, 1);
        vm.prank(alice);
        assertApproxEqAbs(staking.claim(validator), 100 ether, 1);
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
        _openRegistration(10 ether);
        _bond(validator, 10 ether);
        _startElection();

        vm.prank(owner);
        staking.setEquivocation(10_000);
        staking.slashEquivocation(_evidenceAgainst(validator));

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
        staking.setCommitteeConfig(21, 1, 0);
        vm.stopPrank();
        _stake(alice, validator, 100 ether);

        vm.prank(alice);
        staking.unstake(validator, 100 ether);
        // No longer elected...
        address[] memory vals = _committee();
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

    function test_unbonding_periodIsCapped() public {
        vm.prank(owner);
        vm.expectRevert(NVNMStaking.InvalidPeriod.selector);
        staking.setUnbondingPeriod(14 days + 1);
    }

    // -- slashing ------------------------------------------------------------
    function test_slash_seizesTheBondOnly() public {
        _openRegistration(50 ether);
        _bond(validator, 50 ether);
        _stake(alice, validator, 100 ether);
        _startElection();
        vm.prank(owner);
        staking.setEquivocation(5000);

        assertEq(staking.slashEquivocation(_evidenceAgainst(validator)), 25 ether, "half the acquired bond only");
        assertEq(staking.bondOf(validator), 25 ether);
        assertEq(staking.stakedOf(validator, alice), 100 ether, "delegators untouched");

        vm.prank(owner);
        staking.setEquivocation(10_000);
        staking.slashEquivocation(_evidenceAgainst(validator)); // rest of the bond
        assertEq(staking.bondOf(validator), 0);

        assertEq(staking.sendSeized(validator), 50 ether, "both slashes in one send");
        assertEq(gateway.seized(validator), 50 ether);
        vm.prank(validator);
        vm.expectRevert(NVNMStaking.NotCandidate.selector);
        staking.resignCandidate(); // nothing left to return
    }

    function test_slash_leavesPendingDelegatorsWhole() public {
        _openRegistration(50 ether);
        _bond(validator, 50 ether);
        _stake(alice, validator, 100 ether);
        vm.prank(alice);
        staking.unstake(validator, 100 ether);
        _startElection();
        vm.prank(owner);
        staking.setEquivocation(10_000);

        assertEq(staking.slashEquivocation(_evidenceAgainst(validator)), 50 ether);
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        assertEq(staking.withdraw(validator), 100 ether);
    }

    function test_slash_takesTheBondNotTheSeatDelegationEarns() public {
        vm.prank(owner);
        staking.setUnbondingPeriod(7 days);
        _bond(validator, 50 ether);
        _stake(alice, validator, 300 ether);
        _startElection();
        vm.prank(owner);
        staking.setEquivocation(10_000);

        assertEq(staking.slashEquivocation(_evidenceAgainst(validator)), 50 ether);
        assertEq(_committee()[0], validator, "no minAcquired: seated on delegated stake alone");
    }

    // -- lifecycle -----------------------------------------------------------
    function test_initialize_zeroTokenReverts() public {
        NVNMStaking fresh = NVNMStaking(LibClone.deployERC1967(address(new NVNMStaking())));
        vm.expectRevert(NVNMStaking.ZeroAddress.selector);
        fresh.initialize(owner, address(0), address(usd));
        vm.expectRevert(NVNMStaking.ZeroAddress.selector);
        fresh.initialize(owner, address(nvnm), address(0));
        vm.expectRevert(NVNMStaking.ZeroAddress.selector);
        fresh.initialize(address(0), address(nvnm), address(usd));
    }

    function test_storage_sitsAtTheNamespacedSlot() public view {
        // ERC-7201, and `stakeToken` is the struct's first field.
        bytes32 slot = keccak256(abi.encode(uint256(keccak256("nvnm.staking.storage")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(address(uint160(uint256(vm.load(address(staking), slot)))), address(nvnm));
    }

    function test_upgrade_preservesStakeAndRewards_onlyOwner() public {
        _stake(alice, validator, 100 ether);
        staking.depositReward(validator, 100 ether);
        _vest();

        address v2 = address(new NVNMStakingV2());
        vm.prank(alice);
        vm.expectRevert(); // Ownable.Unauthorized
        staking.upgradeToAndCall(v2, "");

        vm.prank(owner);
        staking.upgradeToAndCall(v2, "");
        assertEq(NVNMStakingV2(address(staking)).version(), 2);
        assertEq(staking.stakedOf(validator, alice), 100 ether);
        assertApproxEqAbs(staking.earned(validator, alice), 100 ether, 1);
    }
}

contract NVNMStakingElectionTest is NVNMStakingTestBase {
    // -- committee election --------------------------------------------------
    function _electionSetup() internal {
        vm.startPrank(owner);
        staking.setUnbondingPeriod(7 days);
        staking.setCommitteeConfig(21, 1, 0); // top-21, equal acquired/delegated weight, no cap
        vm.stopPrank();
    }

    function test_election_ranksByStakeOneSeatEach() public {
        _electionSetup();
        _stake(alice, validator, 300 ether);
        _stake(bob, validator2, 150 ether);

        address[] memory vals = _committee();
        assertEq(vals.length, 2);
        assertEq(vals[0], validator);
        assertEq(vals[1], validator2);
    }

    function test_election_overweightsAcquiredStake() public {
        vm.startPrank(owner);
        staking.setUnbondingPeriod(7 days);
        staking.setCommitteeConfig(21, 10, 0); // acquired counts 10x
        vm.stopPrank();
        _bond(validator2, 50 ether);
        _stake(alice, validator, 400 ether); // weight 400
        // validator2: 50*10 + 0 = 500 > 400, ranks first despite less delegated.
        address[] memory vals = _committee();
        assertEq(vals[0], validator2);
        assertEq(vals[1], validator);
    }

    function test_election_weightIsTheElectionScore() public {
        vm.startPrank(owner);
        staking.setUnbondingPeriod(7 days);
        staking.setCommitteeConfig(1, 10, 0); // one seat; acquired counts 10x
        vm.stopPrank();
        _bond(validator2, 50 ether);
        _stake(alice, validator, 400 ether);
        address outsider = makeAddr("outsideTheRegistry");
        _stake(bob, outsider, 100 ether);
        vm.prank(owner);
        staking.setCommitteeConfig(1, 10, 300 ether); // the cap binds at the read

        address[] memory who = new address[](3);
        (who[0], who[1], who[2]) = (validator2, validator, outsider);
        uint256[] memory weights = staking.electionWeight(who);
        assertEq(_committee().length, 1, "one seat");
        assertEq(weights[0], 500 ether, "bond 50 at 10x");
        assertEq(weights[1], 300 ether, "outside the committee, still weighed: 400 capped at 300");
        assertEq(weights[2], 100 ether, "whoever the node asks about is weighed; the registry is its gate");

        vm.prank(owner);
        staking.setMinAcquired(60 ether);
        weights = staking.electionWeight(who);
        assertEq(weights[0] + weights[1] + weights[2], 0, "below minAcquired, all of them");
    }

    function test_election_weightIsZeroUntilConfigured() public {
        _stake(alice, validator, 100 ether);
        address[] memory who = new address[](1);
        who[0] = validator;
        assertEq(staking.electionWeight(who)[0], 0);
    }

    function test_election_respectsCommitteeSize() public {
        _electionSetup();
        vm.prank(owner);
        staking.setCommitteeConfig(1, 1, 0);
        _stake(alice, validator, 300 ether);
        _stake(bob, validator2, 200 ether);

        address[] memory vals = _committee();
        assertEq(vals.length, 1);
        assertEq(vals[0], validator);
    }

    function test_election_capsTheCommitteeAt21() public {
        vm.startPrank(owner);
        staking.setUnbondingPeriod(7 days);
        vm.expectRevert(NVNMStaking.TooManySeats.selector);
        staking.setCommitteeConfig(22, 1, 0);
        staking.setCommitteeConfig(21, 1, 0);
        vm.stopPrank();
        (uint256 seats,,) = staking.committeeConfig();
        assertEq(seats, 21);
    }

    function test_election_anUnbondingBondWeighsNothing() public {
        _openRegistration(50 ether);
        _bond(validator, 50 ether);
        _stake(alice, validator, 100 ether);
        _startElection();
        address[] memory who = new address[](1);
        who[0] = validator;
        assertEq(staking.electionWeight(who)[0], 150 ether);

        vm.prank(validator);
        staking.resignCandidate();
        assertEq(staking.electionWeight(who)[0], 0, "out of the election the moment it unbonds");
        assertEq(_committee().length, 0);
        vm.prank(validator);
        staking.registerCandidate();
        assertEq(staking.electionWeight(who)[0], 150 ether, "and back the moment it stands again");
    }

    function test_election_takesTheRegistryAsItComes() public {
        // Fewer eligible than seats, an address with nothing behind it, an address named twice:
        // every weighted address gets one seat, heaviest first.
        _electionSetup();
        _stake(alice, validator, 100 ether);
        _stake(bob, validator2, 50 ether);
        address[] memory eligible = new address[](4);
        (eligible[0], eligible[1], eligible[2], eligible[3]) = (validator2, validator, validator, makeAddr("unstaked"));
        address[] memory vals = staking.computeCommittee(eligible);
        assertEq(vals.length, 2);
        assertEq(vals[0], validator);
        assertEq(vals[1], validator2);
    }

    function test_election_excludesZeroWeightAndAddressesOutsideTheRegistry() public {
        _electionSetup();
        address stranger = makeAddr("outsideTheRegistry");
        _stake(bob, stranger, 500 ether); // staked, but not in the node's registry

        address[] memory vals = _committee();
        assertEq(vals.length, 0);
    }

    function test_election_enforcesDelegationCap() public {
        vm.startPrank(owner);
        staking.setUnbondingPeriod(7 days);
        staking.setCommitteeConfig(21, 1, 100 ether);
        vm.stopPrank();
        _stake(alice, validator, 100 ether);
        vm.prank(bob);
        vm.expectRevert(NVNMStaking.DelegationCap.selector);
        staking.stake(validator, 1 ether);
    }

    function test_election_dropsCandidatesTheNodeCannotSeat() public {
        // A candidate outside the registry would take a seat nobody fills, and a heavy one
        // pushes a real validator below the cut.
        _electionSetup();
        vm.prank(owner);
        staking.setCommitteeConfig(1, 1, 0);
        _stake(alice, validator, 300 ether);
        _stake(bob, validator2, 100 ether);

        address[] memory registry = new address[](1);
        registry[0] = validator2;
        address[] memory vals = staking.computeCommittee(registry);
        assertEq(vals.length, 1);
        assertEq(vals[0], validator2, "the heavier candidate is not in the registry");
    }

    function test_election_needsAnUnbondingPeriod() public {
        // Stake elects as it stands at the boundary block: with no lockup after it, stake
        // borrowed for that one block buys a seat for the whole epoch.
        vm.startPrank(owner);
        vm.expectRevert(NVNMStaking.UnbondingRequired.selector);
        staking.setCommitteeConfig(21, 1, 0);

        staking.setUnbondingPeriod(7 days);
        staking.setCommitteeConfig(21, 1, 0);
        vm.expectRevert(NVNMStaking.UnbondingRequired.selector);
        staking.setUnbondingPeriod(0);
        vm.stopPrank();
    }

    function test_election_unconfiguredElectsNobody() public {
        // Empty, not a revert: the node maps a deterministic revert to a stalled epoch feed,
        // while an empty committee drops every node into the registry fallback together.
        address[] memory vals = _committee();
        assertEq(vals.length, 0);
    }

    function test_election_delegationCapBindsAtReadTime() public {
        _electionSetup();
        _stake(alice, validator, 300 ether);
        _stake(bob, validator2, 400 ether);
        address[] memory vals = _committee();
        assertEq(vals[0], validator2); // 400 > 300 uncapped

        // Lowering the cap must clamp the incumbents' election weight too, or tightening
        // delegation influence exempts exactly the entrenched pools it targets. Both pools
        // clamp to 50 and the tie falls back to registry order.
        vm.prank(owner);
        staking.setCommitteeConfig(21, 1, 50 ether);
        vals = _committee();
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
        address[] memory vals = _committee();
        assertEq(vals.length, 0, "two seats below a floor of three elects nobody");

        vm.prank(owner);
        staking.setMinSeats(2);
        vals = _committee();
        assertEq(vals.length, 2, "at the floor the committee seats");
        assertEq(staking.minSeats(), 2);

        // Neither bound may cross the other: that would elect nobody for good.
        vm.startPrank(owner);
        vm.expectRevert(NVNMStaking.TooManySeats.selector);
        staking.setMinSeats(22);
        vm.expectRevert(NVNMStaking.TooManySeats.selector);
        staking.setCommitteeConfig(1, 1, 0);
        staking.setCommitteeConfig(2, 1, 0);
        vm.expectRevert(NVNMStaking.TooManySeats.selector);
        staking.setMinSeats(3);
        vm.stopPrank();
    }

    function test_election_absurdAcquiredWeightSaturatesInsteadOfReverting() public {
        // The weight formula must be total: a checked-overflow revert here is deterministic,
        // and the node maps it to a stalled epoch feed rather than the registry fallback.
        vm.startPrank(owner);
        staking.setUnbondingPeriod(7 days);
        staking.setCommitteeConfig(21, type(uint256).max, 0);
        vm.stopPrank();
        _bond(alice, 50 ether); // 50e18 bond x 2^256-1 weight overflows unchecked math

        address[] memory vals = _committee();
        assertEq(vals.length, 1);
        assertEq(vals[0], alice);
    }

    /// Every election and exit knob is the owner's alone. One test, so a setter that loses
    /// `onlyOwner` fails here rather than nowhere.
    function test_onlyOwnerConfigures() public {
        vm.startPrank(makeAddr("stranger"));
        vm.expectRevert(Ownable.Unauthorized.selector);
        staking.setCommitteeConfig(1, 1, 0);
        vm.expectRevert(Ownable.Unauthorized.selector);
        staking.setMinAcquired(1 ether);
        vm.expectRevert(Ownable.Unauthorized.selector);
        staking.setMinSeats(3);
        vm.expectRevert(Ownable.Unauthorized.selector);
        staking.setUnbondingPeriod(1 days);
        vm.expectRevert(Ownable.Unauthorized.selector);
        staking.setRewardDuration(1 hours);
        vm.expectRevert(Ownable.Unauthorized.selector);
        staking.setBondGateway(address(0));
        vm.stopPrank();
    }

    // -- bonded candidacy ----------------------------------------------------
    function test_candidacy_aBridgedBondStands() public {
        _openRegistration(50 ether);

        _bond(alice, 50 ether);
        assertEq(staking.bondOf(alice), 50 ether);
        assertEq(nvnm.balanceOf(alice), 1000 ether, "never taken from her balance here");

        // Electable by the bond alone, the registry willing.
        vm.prank(owner);
        staking.setCommitteeConfig(21, 1, 0);
        _stake(bob, alice, 100 ether);
        address[] memory vals = _committee();
        assertEq(vals[0], alice);
    }

    function test_candidacy_bondNeedsAnUnbondingPeriod() public {
        // With no period a resignation refunds at once, and an operator front-runs its own
        // slash to walk away whole: while a bond is posted the period cannot be zeroed.
        _openRegistration(50 ether);
        _bond(alice, 50 ether);

        vm.prank(owner);
        vm.expectRevert(NVNMStaking.UnbondingRequired.selector);
        staking.setUnbondingPeriod(0);

        vm.prank(alice);
        staking.resignCandidate();
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        staking.withdrawBond();
        vm.prank(owner);
        staking.setUnbondingPeriod(0); // every bond is home
    }

    /// @dev Bond alice under a 7-day unbonding period and resign her.
    function _resignUnderUnbonding() internal {
        _openRegistration(50 ether);
        _bond(alice, 50 ether);
        vm.prank(alice);
        staking.resignCandidate();
    }

    function test_candidacy_resignUnbondsBond() public {
        _resignUnderUnbonding();

        assertEq(gateway.returned(alice), 0, "bond is not returned yet");
        (uint256 amount, uint256 releaseAt) = staking.pendingBondOf(alice);
        assertEq(amount, 50 ether);
        assertEq(releaseAt, block.timestamp + 7 days);

        vm.prank(alice);
        vm.expectRevert(NVNMStaking.StillUnbonding.selector);
        staking.withdrawBond();

        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        assertEq(staking.withdrawBond(), 50 ether);
        assertEq(gateway.returned(alice), 50 ether, "home to her bond on Ethereum");
        assertEq(gateway.feePayer(), alice, "she pays the bridge");
        (amount, releaseAt) = staking.pendingBondOf(alice);
        assertEq(amount + releaseAt, 0, "bucket cleared");
    }

    function test_candidacy_resigningDoesNotOutrunSlash() public {
        // The reason the bond unbonds at all: without it an operator front-runs its own slash
        // with `resignCandidate` and walks away whole, so nothing is ever at risk.
        _resignUnderUnbonding();
        _startElection();

        vm.prank(owner);
        staking.setEquivocation(10_000);
        assertEq(staking.slashEquivocation(_evidenceAgainst(alice)), 50 ether, "resigned bond still slashable");
        staking.sendSeized(alice);
        assertEq(gateway.seized(alice), 50 ether);

        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        assertEq(staking.withdrawBond(), 0);
        assertEq(gateway.returned(alice), 0, "nothing left to return");
    }

    function test_candidacy_reRegisteringCancelsTheUnbonding() public {
        // The bond never left, so standing again needs no fresh one. Otherwise the clock keeps
        // running while the validator is electable again, and `withdrawBond` pulls the bond out
        // from under a live candidate.
        _resignUnderUnbonding();

        vm.prank(alice);
        staking.registerCandidate();
        (uint256 amount, uint256 releaseAt) = staking.pendingBondOf(alice);
        assertEq(amount + releaseAt, 0, "no longer unbonding");
        assertEq(staking.bondOf(alice), 50 ether, "the bond is still posted and at risk");

        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        vm.expectRevert(NVNMStaking.NothingToWithdraw.selector);
        staking.withdrawBond();
    }

    function test_election_minAcquiredExcludesUnbondedCandidates() public {
        // §7: validator stake is acquired, never delegated. Below the floor, delegation alone
        // must not buy a seat however large it is.
        vm.startPrank(owner);
        staking.setUnbondingPeriod(7 days);
        staking.setCommitteeConfig(21, 1, 0);
        staking.setMinAcquired(50 ether);
        vm.stopPrank();
        _stake(alice, validator, 500 ether); // heavily delegated, still unbonded

        address[] memory vals = _committee();
        assertEq(vals.length, 0, "no bond, no seat");

        // Posting the bond makes the same validator electable.
        _bond(bob, 50 ether);
        vals = _committee();
        assertEq(vals.length, 1);
        assertEq(vals[0], bob);
    }

    function test_election_minAcquiredDefaultsOff() public {
        // The PoA phases post no bond: the registry's owner curates, and delegation elects.
        vm.startPrank(owner);
        staking.setUnbondingPeriod(7 days);
        staking.setCommitteeConfig(21, 1, 0);
        vm.stopPrank();
        _stake(alice, validator, 100 ether);

        assertEq(staking.minAcquired(), 0);
        address[] memory vals = _committee();
        assertEq(vals.length, 1, "no floor configured, delegated stake elects");
    }

    function test_compoundReward_respectsDelegationCap() public {
        vm.startPrank(owner);
        staking.setUnbondingPeriod(7 days);
        staking.setCommitteeConfig(21, 1, 150 ether);
        vm.stopPrank();
        _stake(alice, validator, 100 ether);

        nvnm.mint(address(this), 100 ether);
        nvnm.approve(address(staking), type(uint256).max);
        vm.expectRevert(NVNMStaking.DelegationCap.selector);
        staking.compoundReward(validator, 60 ether); // 100 + 60 > 150

        staking.compoundReward(validator, 50 ether); // exactly at the cap
        assertEq(staking.totalStaked(validator), 150 ether);
    }

    function test_candidacy_unbondingBondCarriesNoElectionWeight() public {
        _resignUnderUnbonding();
        vm.prank(owner);
        staking.setCommitteeConfig(21, 1, 0);

        address[] memory vals = _committee();
        assertEq(vals.length, 0, "a resigned candidate is not electable on an unbonding bond");
    }

    function test_withdrawBond_nothingToWithdrawReverts() public {
        vm.prank(alice);
        vm.expectRevert(NVNMStaking.NothingToWithdraw.selector);
        staking.withdrawBond();
    }

    function test_candidacy_bondChangeDoesNotAffectHeldBonds() public {
        _openRegistration(50 ether);
        _bond(alice, 50 ether);

        vm.prank(owner);
        staking.setMinAcquired(500 ether); // raised after alice bonded: she cannot stand, but keeps her bond
        vm.prank(alice);
        staking.resignCandidate();
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        assertEq(staking.withdrawBond(), 50 ether, "refund is the bond actually paid");
    }

    function test_candidacy_duplicateAndNonCandidateRevert() public {
        _openRegistration(50 ether);
        _bond(alice, 50 ether);

        // Standing already, there is nothing to stand again for; with no bond, nothing to resign.
        vm.prank(alice);
        vm.expectRevert(NVNMStaking.AlreadyCandidate.selector);
        staking.registerCandidate();
        vm.prank(bob);
        vm.expectRevert(NVNMStaking.NotCandidate.selector);
        staking.resignCandidate();
        vm.prank(bob);
        vm.expectRevert(NVNMStaking.AlreadyCandidate.selector);
        staking.registerCandidate();
    }

    function test_bondFromBridge_onlyTheGateway() public {
        vm.prank(alice);
        vm.expectRevert(NVNMStaking.NotBondGateway.selector);
        staking.bondFromBridge(alice, 50 ether);
    }

    function test_candidacy_aBondBelowTheBarStandsOnceItReachesIt() public {
        _openRegistration(50 ether);
        vm.prank(owner);
        staking.setCommitteeConfig(21, 1, 0);
        address[] memory who = new address[](1);
        who[0] = alice;

        _bond(alice, 30 ether);
        assertEq(staking.electionWeight(who)[0], 0, "not yet");
        _bond(alice, 20 ether);
        assertEq(staking.electionWeight(who)[0], 50 ether);
        assertEq(staking.bondOf(alice), 50 ether);
    }

    function test_candidacy_aBondArrivesEvenWhenItCannotStand() public {
        // It is already locked on Ethereum: a delivery that reverted would leave it there unrecorded.
        vm.prank(owner);
        staking.setUnbondingPeriod(7 days);
        _bond(bob, 50 ether); // no election configured
        assertEq(staking.bondOf(bob), 50 ether);

        _resignUnderUnbonding();
        _bond(alice, 10 ether);
        (uint256 amount, uint256 releaseAt) = staking.pendingBondOf(alice);
        assertEq(amount, 60 ether, "joins the unbonding bond");
        assertGt(releaseAt, 0, "without standing her again");
    }

    function test_candidacy_aTopUpRestartsTheUnbonding() public {
        // Joining a matured bond as it stood, a top-up left in the block it arrived.
        _resignUnderUnbonding();
        vm.warp(block.timestamp + 7 days);
        _bond(alice, 10 ether);

        (uint256 amount, uint256 releaseAt) = staking.pendingBondOf(alice);
        assertEq(amount, 60 ether);
        assertEq(releaseAt, block.timestamp + 7 days, "the whole bond waits again");
        vm.prank(alice);
        vm.expectRevert(NVNMStaking.StillUnbonding.selector);
        staking.withdrawBond();
    }

    function test_candidacy_aTopUpNeverBringsTheReleaseForward() public {
        _resignUnderUnbonding();
        (, uint256 releaseAt) = staking.pendingBondOf(alice);
        vm.prank(owner);
        staking.setUnbondingPeriod(1 days);

        _bond(alice, 10 ether);
        (, uint256 restarted) = staking.pendingBondOf(alice);
        assertEq(restarted, releaseAt, "the shorter period does not cut the wait already owed");
    }

    function test_candidacy_aBondThatNeverStoodGoesHome() public {
        _openRegistration(50 ether);
        _bond(alice, 10 ether);

        vm.prank(alice);
        staking.resignCandidate();
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        assertEq(staking.withdrawBond(), 10 ether);
        assertEq(gateway.returned(alice), 10 ether);
    }
}

/// @dev Rewards vest over `rewardDuration` rather than landing whole at the deposit.
contract NVNMStakingStreamTest is NVNMStakingTestBase {
    function test_rewards_aStakeAroundAFlushEarnsNothing() public {
        // The attack streaming closes: join in the block of the flush, leave in the next, and
        // take a share of fees earned before arriving.
        _stake(alice, validator, 100 ether);
        _stake(bob, validator, 100 ether);
        staking.depositReward(validator, 100 ether);
        vm.prank(bob);
        staking.unstake(validator, 100 ether);

        _vest();
        assertEq(staking.earned(validator, bob), 0);
        assertApproxEqAbs(staking.earned(validator, alice), 100 ether, 1);
    }

    function test_rewards_vestOverTheDuration() public {
        _stake(alice, validator, 100 ether);
        staking.depositReward(validator, 100 ether);
        assertEq(staking.earned(validator, alice), 0, "nothing at the deposit");

        vm.warp(vm.getBlockTimestamp() + staking.rewardDuration() / 2);
        assertApproxEqAbs(staking.earned(validator, alice), 50 ether, 1);
        _vest();
        assertApproxEqAbs(staking.earned(validator, alice), 100 ether, 1, "no more than was deposited");
    }

    function test_rewards_aDepositMidStreamCarriesTheUnvested() public {
        _stake(alice, validator, 100 ether);
        staking.depositReward(validator, 100 ether);
        vm.warp(vm.getBlockTimestamp() + staking.rewardDuration() / 2);
        staking.depositReward(validator, 100 ether); // 50 unvested + 100 over a fresh duration

        _vest();
        assertApproxEqAbs(staking.earned(validator, alice), 200 ether, 2);
    }

    function test_rewards_streamPausesWhileThePoolIsEmpty() public {
        // Vesting to nobody would strand the tokens: the rest waits for the next stake.
        _stake(alice, validator, 100 ether);
        staking.depositReward(validator, 100 ether);
        uint256 half = staking.rewardDuration() / 2;
        vm.warp(vm.getBlockTimestamp() + half);
        vm.prank(alice);
        staking.unstake(validator, 100 ether);

        vm.warp(vm.getBlockTimestamp() + 10 days);
        _stake(bob, validator, 100 ether);
        vm.warp(vm.getBlockTimestamp() + half);
        assertApproxEqAbs(staking.earned(validator, alice), 50 ether, 1);
        assertApproxEqAbs(staking.earned(validator, bob), 50 ether, 1);
    }

    function test_rewards_aDepositAfterADryStreamStartsAtTheDeposit() public {
        // Settles after the stream ran dry leave its clock alone; the next deposit must restamp
        // it, or the new stream vests from where the old one stopped.
        _stake(alice, validator, 100 ether);
        staking.depositReward(validator, 100 ether);
        _vest();
        vm.prank(alice);
        staking.claim(validator);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(alice);
        staking.claim(validator); // nothing streaming: nothing written
        vm.warp(vm.getBlockTimestamp() + 1 days);

        staking.depositReward(validator, 100 ether);
        assertEq(staking.earned(validator, alice), 0, "nothing of the new stream yet");
        vm.warp(vm.getBlockTimestamp() + staking.rewardDuration() / 2);
        assertApproxEqAbs(staking.earned(validator, alice), 50 ether, 1);
    }

    function test_setRewardDuration_isBounded() public {
        vm.startPrank(owner);
        vm.expectRevert(NVNMStaking.InvalidPeriod.selector);
        staking.setRewardDuration(0);
        vm.expectRevert(NVNMStaking.InvalidPeriod.selector);
        staking.setRewardDuration(31 days);
        staking.setRewardDuration(1 hours);
        vm.stopPrank();
        assertEq(staking.rewardDuration(), 1 hours);
    }
}
