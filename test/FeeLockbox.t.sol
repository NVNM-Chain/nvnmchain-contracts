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
        lockbox = new FeeLockbox(owner);
        vm.etch(address(lockbox.REGISTRY()), address(new MockValidatorConfig()).code);
        registry = MockValidatorConfig(address(lockbox.REGISTRY()));
        usd = new MockERC20("nUSD", "nUSD");
        usd.mint(address(this), 1000 ether);
        usd.approve(address(lockbox), type(uint256).max);
    }

    /// @dev `n` active validators, the first `affiliatedCount` of them declared affiliated.
    function _set(uint256 n, uint256 affiliatedCount) internal {
        delete vals;
        for (uint256 i; i < n; ++i) {
            vals.push(address(uint160(0x1000 + i)));
            if (i < affiliatedCount) {
                vm.prank(owner);
                lockbox.setAffiliated(vals[i]);
            }
        }
        registry.setActive(vals);
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
        (uint256 active, uint256 aff, uint256 votes) = lockbox.composition();
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
        (,, uint256 votes) = lockbox.composition();
        assertEq(votes, 4);
        vm.expectRevert(FeeLockbox.VoteShort.selector);
        lockbox.commence();
    }

    function test_vote_canBeWithdrawn() public {
        _set(9, 4);
        _votes(5);
        vm.prank(vals[0]);
        lockbox.vote(false);
        vm.expectRevert(FeeLockbox.VoteShort.selector);
        lockbox.commence();
    }

    function test_setAffiliated_ownerOnly() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Ownable.Unauthorized.selector);
        lockbox.setAffiliated(operator);

        vm.prank(owner);
        vm.expectRevert(FeeLockbox.ZeroAddress.selector);
        lockbox.setAffiliated(address(0));
    }

    function test_deposit_rejectsZeroOperator() public {
        vm.expectRevert(FeeLockbox.ZeroAddress.selector);
        lockbox.deposit(address(usd), address(0), 1 ether);
    }
}
