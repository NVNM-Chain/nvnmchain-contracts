// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {FeeLockbox} from "../src/FeeLockbox.sol";
import {MockERC20} from "./support/MockERC20.sol";
import {MockValidatorConfig} from "./support/MockValidatorConfig.sol";
import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract FeeLockboxTest is Test {
    FeeLockbox lockbox;
    MockValidatorConfig registry;
    MockERC20 usd;

    address owner = makeAddr("safe");
    address operator = makeAddr("operator");
    address[] vals;

    function setUp() public {
        lockbox = new FeeLockbox(owner, 2500, 2500, 1 days);
        vm.etch(address(lockbox.REGISTRY()), address(new MockValidatorConfig()).code);
        registry = MockValidatorConfig(address(lockbox.REGISTRY()));
        usd = new MockERC20("nUSD", "nUSD");
        usd.mint(address(this), 1000 ether);
        usd.approve(address(lockbox), type(uint256).max);
    }

    /// @dev `n` active validators, all declared, the first `affiliatedCount` of them affiliated.
    function _set(uint256 n, uint256 affiliatedCount) internal {
        delete vals;
        for (uint256 i; i < n; ++i) {
            vals.push(address(uint160(0x1000 + i)));
        }
        registry.setActive(vals);
        for (uint256 i; i < n; ++i) {
            if (!lockbox.declared(_seat(vals[i]))) {
                vm.prank(owner);
                lockbox.setAffiliated(vals[i], i < affiliatedCount);
            }
        }
    }

    /// @dev The seat of an address in the set.
    function _seat(address v) internal view returns (bytes32) {
        return lockbox.seat(registry.indexOf(v), v);
    }

    function _votes(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            vm.prank(vals[i]);
            lockbox.vote(true);
        }
    }

    function test_deposit_holdsUntilCommenced() public {
        lockbox.deposit(address(usd), operator, 100 ether);
        assertEq(lockbox.owed(address(usd), operator), 100 ether);
        assertEq(usd.balanceOf(address(lockbox)), 100 ether);

        vm.expectRevert(FeeLockbox.NotCommenced.selector);
        lockbox.claim(address(usd), operator);
    }

    function test_commence_refusedWhileMajorityAffiliated() public {
        // The genesis set: four of five affiliated. A unanimous vote does not override it.
        _set(5, 4);
        _votes(5);
        vm.expectRevert(FeeLockbox.MajorityAffiliated.selector);
        lockbox.commence();

        // Half is not a majority either.
        _set(8, 4);
        vm.expectRevert(FeeLockbox.MajorityAffiliated.selector);
        lockbox.commence();
    }

    function test_commence_needsAMajorityVote() public {
        _set(9, 4); // Phase 2: five non-affiliated of nine
        _votes(4);
        vm.expectRevert(FeeLockbox.VoteShort.selector);
        lockbox.commence();

        _votes(5);
        lockbox.commence();
        assertTrue(lockbox.commenced());
        (uint256 active, uint256 aff, uint256 votes,) = lockbox.composition();
        assertEq(active, 9);
        assertEq(aff, 4);
        assertEq(votes, 5);

        vm.expectRevert(FeeLockbox.AlreadyCommenced.selector);
        lockbox.commence();
    }

    function test_claim_paysTheDeferredShare() public {
        lockbox.deposit(address(usd), operator, 100 ether);
        _set(9, 4);
        _votes(5);
        lockbox.commence();

        vm.prank(makeAddr("keeper"));
        assertEq(lockbox.claim(address(usd), operator), 100 ether);
        assertEq(usd.balanceOf(operator), 100 ether);
        assertEq(lockbox.owed(address(usd), operator), 0);
        assertEq(lockbox.claim(address(usd), operator), 0);
    }

    function test_deposit_closesAtCommencement() public {
        _set(9, 4);
        _votes(5);
        lockbox.commence();

        vm.expectRevert(FeeLockbox.AlreadyCommenced.selector);
        lockbox.deposit(address(usd), operator, 10 ether);
    }

    function test_vote_onlyActiveValidators_andOnlyWhileActive() public {
        _set(9, 4);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(FeeLockbox.NotValidator.selector);
        lockbox.vote(true);

        _votes(5);
        // A validator replaced in the set takes its vote with it.
        vals[4] = address(uint160(0x2000));
        registry.setActive(vals);
        vm.prank(owner);
        lockbox.setAffiliated(vals[4], false);
        (,, uint256 votes,) = lockbox.composition();
        assertEq(votes, 4);
        vm.expectRevert(FeeLockbox.VoteShort.selector);
        lockbox.commence();
    }

    /// @dev The registry numbers a returning address as a new entry, and keeps an entry's number
    ///      when it is handed to another address: either way the records start over.
    function test_records_belongToTheSeat_notTheAddress() public {
        _set(5, 0);
        _votes(5);
        address reused = vals[4];
        vals.pop();
        registry.setActive(vals);
        vals.push(reused);
        registry.setActive(vals);
        (uint256 active,, uint256 votes, uint256 undeclared) = lockbox.composition();
        assertEq(active, 5);
        assertEq(votes, 4, "the returning address has not voted");
        assertEq(undeclared, 1, "nor been declared");
        vm.prank(owner);
        lockbox.setAffiliated(reused, true);

        registry.transfer(0, address(uint160(0x3000)));
        (,, votes, undeclared) = lockbox.composition();
        assertEq(votes, 3, "the new holder has not voted");
        assertEq(undeclared, 1, "nor been declared");
    }

    function test_vote_canBeWithdrawn() public {
        _set(9, 4);
        _votes(5);
        vm.prank(vals[0]);
        lockbox.vote(false);
        vm.expectRevert(FeeLockbox.VoteShort.selector);
        lockbox.commence();
    }

    function test_commence_needsEveryActiveValidatorDeclared() public {
        // Leaving the founders undeclared would let three of five commence.
        _set(9, 4);
        vals.push(address(uint160(0x2000)));
        registry.setActive(vals);
        _votes(10);
        vm.expectRevert(FeeLockbox.Undeclared.selector);
        lockbox.commence();

        vm.prank(owner);
        lockbox.setAffiliated(vals[9], false);
        lockbox.commence();
    }

    function test_setAffiliated_ownerOnly_activeOnly_andFinal() public {
        vals.push(makeAddr("validator"));
        registry.setActive(vals);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Ownable.Unauthorized.selector);
        lockbox.setAffiliated(vals[0], true);

        vm.startPrank(owner);
        vm.expectRevert(FeeLockbox.NotValidator.selector);
        lockbox.setAffiliated(operator, true);

        lockbox.setAffiliated(vals[0], true);
        vm.expectRevert(FeeLockbox.AlreadyDeclared.selector);
        lockbox.setAffiliated(vals[0], false);
        vm.stopPrank();
        assertTrue(lockbox.affiliated(_seat(vals[0])));
    }

    function test_deposit_rejectsZeroOperator() public {
        vm.expectRevert(FeeLockbox.ZeroAddress.selector);
        lockbox.deposit(address(usd), address(0), 1 ether);
    }

    // -- the fee split -------------------------------------------------------
    function _propose(uint256 by, uint256 devBps, uint256 buyBps) internal returns (uint256 id) {
        vm.prank(vals[by]);
        id = lockbox.proposeSplit(devBps, buyBps);
    }

    /// @dev `vals[from..to)` back proposal `id`.
    function _back(uint256 id, uint256 from, uint256 to) internal {
        for (uint256 i = from; i < to; ++i) {
            vm.prank(vals[i]);
            lockbox.voteSplit(id, true);
        }
    }

    function test_constructor_checksTheSplit() public {
        vm.expectRevert(FeeLockbox.BuybackBelowFloor.selector);
        new FeeLockbox(owner, 2500, 1999, 1 days);
        vm.expectRevert(FeeLockbox.InvalidBps.selector);
        new FeeLockbox(owner, 6000, 5000, 1 days);
        vm.expectRevert(FeeLockbox.ZeroDelay.selector);
        new FeeLockbox(owner, 2500, 2500, 0);
        assertEq(lockbox.devshareBps(), 2500);
        assertEq(lockbox.buybackBps(), 2500);
    }

    function test_split_appliesAfterTheDelayWithAMajority() public {
        _set(5, 4);
        uint256 id = _propose(0, 2000, 3000); // the proposer backs it
        _back(id, 1, 3); // three of five
        vm.expectRevert(FeeLockbox.SplitPending.selector);
        lockbox.applySplit(id);

        vm.warp(block.timestamp + 1 days);
        lockbox.applySplit(id);
        assertEq(lockbox.devshareBps(), 2000);
        assertEq(lockbox.buybackBps(), 3000);
        vm.expectRevert(FeeLockbox.AlreadyApplied.selector);
        lockbox.applySplit(id);
    }

    function test_split_needsAMajorityOfTheActiveSet() public {
        _set(5, 4);
        uint256 id = _propose(0, 2000, 3000);
        _back(id, 1, 2); // two of five
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(FeeLockbox.VoteShort.selector);
        lockbox.applySplit(id);

        // A backer replaced in the set takes its vote with it.
        _back(id, 2, 3);
        vals[2] = address(uint160(0x2000));
        registry.setActive(vals);
        vm.expectRevert(FeeLockbox.VoteShort.selector);
        lockbox.applySplit(id);
    }

    function test_split_votesAreProposalScoped() public {
        _set(5, 4);
        uint256 first = _propose(0, 2000, 3000);
        _back(first, 1, 3);
        uint256 second = _propose(0, 1000, 4000); // backed by its proposer only
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(FeeLockbox.VoteShort.selector);
        lockbox.applySplit(second);
        lockbox.applySplit(first);
    }

    function test_split_waitsOutTheDelayAfterItsMajority() public {
        _set(5, 4);
        uint256 id = _propose(0, 2000, 3000);
        vm.warp(block.timestamp + 1 days);
        _back(id, 1, 3); // a majority only now
        vm.expectRevert(FeeLockbox.SplitPending.selector);
        lockbox.applySplit(id);

        // Withdrawing restarts a backer's clock; backing again does not.
        vm.prank(vals[1]);
        lockbox.voteSplit(id, false);
        vm.warp(block.timestamp + 12 hours);
        _back(id, 1, 3);
        vm.warp(block.timestamp + 12 hours);
        vm.expectRevert(FeeLockbox.SplitPending.selector);
        lockbox.applySplit(id);
        vm.warp(block.timestamp + 12 hours);
        lockbox.applySplit(id);
    }

    function test_split_cannotPayTheFoundersBeforeCommencement() public {
        _set(5, 4);
        uint256 moreDev = _propose(0, 3000, 2000);
        uint256 lessValidator = _propose(0, 2500, 3000);
        uint256 lessDev = _propose(0, 1500, 3500);
        _back(moreDev, 1, 3);
        _back(lessValidator, 1, 3);
        _back(lessDev, 1, 3);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(FeeLockbox.DevshareRaised.selector);
        lockbox.applySplit(moreDev);
        vm.expectRevert(FeeLockbox.ValidatorShareCut.selector);
        lockbox.applySplit(lessValidator);
        lockbox.applySplit(lessDev);
        assertEq(lockbox.devshareBps(), 1500);

        // Once distribution has commenced the set decides freely, above the buyback floor.
        _set(9, 4);
        _votes(5);
        lockbox.commence();
        uint256 later = _propose(5, 4000, 4000);
        _back(later, 0, 4); // five of nine with the proposer
        vm.warp(block.timestamp + 1 days);
        lockbox.applySplit(later);
        assertEq(lockbox.devshareBps(), 4000);
    }

    function test_split_commencementVoidsEarlierProposals() public {
        _set(5, 4);
        uint256 moreDev = _propose(0, 3000, 2000);
        _back(moreDev, 1, 5);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(FeeLockbox.DevshareRaised.selector);
        lockbox.applySplit(moreDev);

        _set(9, 4);
        _votes(5);
        lockbox.commence();
        // Its five backers are a settled majority of nine, but they voted under the old rules.
        vm.expectRevert(FeeLockbox.SplitStale.selector);
        lockbox.applySplit(moreDev);
    }

    function test_split_holdsTheBuybackFloor() public {
        _set(5, 4);
        vm.startPrank(vals[0]);
        vm.expectRevert(FeeLockbox.BuybackBelowFloor.selector);
        lockbox.proposeSplit(2500, 1999);
        vm.expectRevert(FeeLockbox.InvalidBps.selector);
        lockbox.proposeSplit(6000, 5000);
        vm.stopPrank();
    }

    function test_split_onlyActiveValidatorsProposeAndVote() public {
        _set(5, 4);
        uint256 id = _propose(0, 2000, 3000);
        vm.startPrank(makeAddr("stranger"));
        vm.expectRevert(FeeLockbox.NotValidator.selector);
        lockbox.proposeSplit(2000, 3000);
        vm.expectRevert(FeeLockbox.NotValidator.selector);
        lockbox.voteSplit(id, true);
        vm.stopPrank();

        vm.prank(vals[1]);
        vm.expectRevert(FeeLockbox.NoSuchSplit.selector);
        lockbox.voteSplit(id + 1, true);
        vm.expectRevert(FeeLockbox.NoSuchSplit.selector);
        lockbox.applySplit(id + 1);
    }
}
