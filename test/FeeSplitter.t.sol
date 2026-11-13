// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";

contract Token is ERC20 {
    function name() public pure override returns (string memory) {
        return "nUSD";
    }

    function symbol() public pure override returns (string memory) {
        return "nUSD";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Tempo's FeeManager: a ledger of fees per recipient, paid out to it on request.
contract MockFeeManager {
    mapping(address => mapping(address => uint256)) public collectedFees;

    function credit(address recipient, address token, uint256 amount) external {
        Token(token).mint(address(this), amount);
        collectedFees[recipient][token] += amount;
    }

    function distributeFees(address validator, address token) external {
        uint256 amount = collectedFees[validator][token];
        collectedFees[validator][token] = 0;
        Token(token).transfer(validator, amount);
    }
}

contract FeeSplitterTest is Test {
    address constant OWNER = address(0xA0);
    address constant DEV = address(0xD0);
    address constant BUY = address(0xB0);

    MockFeeManager fees;
    Token usd;
    FeeSplitter splitter;
    address[] ops;

    function setUp() public {
        vm.etch(0xfeEC000000000000000000000000000000000000, address(new MockFeeManager()).code);
        fees = MockFeeManager(0xfeEC000000000000000000000000000000000000);
        usd = new Token();
        for (uint160 i = 1; i <= 5; ++i) {
            ops.push(address(0x100 + i));
        }
        splitter = new FeeSplitter(OWNER, DEV, BUY, 2_500, 2_500, ops);
    }

    function test_split_pays_the_cuts_and_holds_a_tenth_for_each_operator() public {
        fees.credit(address(splitter), address(usd), 1_000_000);
        assertEq(splitter.split(address(usd)), 1_000_000);

        assertEq(usd.balanceOf(DEV), 250_000);
        assertEq(usd.balanceOf(BUY), 250_000);
        for (uint256 i; i < 5; ++i) {
            assertEq(splitter.owed(address(usd), i), 100_000);
        }
        assertEq(splitter.held(address(usd)), 500_000);
        assertEq(usd.balanceOf(address(splitter)), 500_000);
    }

    /// Anyone may call `distributeFees` before the splitter exists; what arrived early is split too.
    function test_split_takes_a_balance_paid_out_before_it_was_deployed() public {
        usd.mint(address(splitter), 400_000);
        fees.credit(address(splitter), address(usd), 600_000);
        assertEq(splitter.split(address(usd)), 1_000_000);
        assertEq(usd.balanceOf(DEV), 250_000);
    }

    function test_held_shares_are_not_split_again() public {
        fees.credit(address(splitter), address(usd), 1_000_000);
        splitter.split(address(usd));
        assertEq(splitter.split(address(usd)), 0);

        fees.credit(address(splitter), address(usd), 2_000_000);
        assertEq(splitter.split(address(usd)), 2_000_000);
        assertEq(usd.balanceOf(DEV), 750_000);
        assertEq(splitter.owed(address(usd), 4), 300_000);
    }

    function test_a_remainder_waits_for_the_next_split() public {
        fees.credit(address(splitter), address(usd), 1_003);
        splitter.split(address(usd));
        // 1,003 - 250 - 250 = 503 for five operators: 100 each, 3 left over.
        assertEq(splitter.owed(address(usd), 0), 100);
        assertEq(splitter.held(address(usd)), 500);
        assertEq(splitter.split(address(usd)), 3);
    }

    function test_nothing_is_claimable_before_commencement() public {
        fees.credit(address(splitter), address(usd), 1_000_000);
        splitter.split(address(usd));
        vm.expectRevert(FeeSplitter.NotCommenced.selector);
        splitter.claim(address(usd), 0);
    }

    function test_after_commencement_anyone_pays_an_operator_its_share() public {
        fees.credit(address(splitter), address(usd), 1_000_000);
        splitter.split(address(usd));
        vm.prank(OWNER);
        splitter.commence();

        assertEq(splitter.claim(address(usd), 2), 100_000);
        assertEq(usd.balanceOf(ops[2]), 100_000);
        assertEq(splitter.claim(address(usd), 2), 0);
        assertEq(splitter.held(address(usd)), 400_000);
        // What is left is held for the other four, so a split finds nothing new.
        assertEq(splitter.split(address(usd)), 0);

        // A later split owes the paid operator only its part of that one.
        fees.credit(address(splitter), address(usd), 1_000_000);
        splitter.split(address(usd));
        assertEq(splitter.claim(address(usd), 2), 100_000);
        assertEq(splitter.claim(address(usd), 0), 200_000);
    }

    function test_only_the_owner_commences_and_only_once() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        splitter.commence();
        vm.startPrank(OWNER);
        splitter.commence();
        vm.expectRevert(FeeSplitter.AlreadyCommenced.selector);
        splitter.commence();
    }

    function test_the_owner_cannot_renounce() public {
        vm.prank(OWNER);
        vm.expectRevert(FeeSplitter.Unrenounceable.selector);
        splitter.renounceOwnership();
    }

    function test_only_an_operator_moves_its_payout() public {
        fees.credit(address(splitter), address(usd), 1_000_000);
        splitter.split(address(usd));
        vm.prank(OWNER);
        vm.expectRevert(FeeSplitter.NotOperator.selector);
        splitter.moveOperator(1, OWNER);

        address moved = address(0xC1);
        vm.prank(ops[1]);
        splitter.moveOperator(1, moved);
        vm.prank(OWNER);
        splitter.commence();
        splitter.claim(address(usd), 1);
        assertEq(usd.balanceOf(moved), 100_000);
        assertEq(usd.balanceOf(ops[1]), 0);
    }

    function test_the_constructor_refuses_a_bad_split() public {
        vm.expectRevert(FeeSplitter.InvalidBps.selector);
        new FeeSplitter(OWNER, DEV, BUY, 9_000, 2_000, ops);
        vm.expectRevert(FeeSplitter.InvalidBps.selector);
        new FeeSplitter(OWNER, DEV, BUY, 2_500, 1_999, ops);
        vm.expectRevert(FeeSplitter.NoOperators.selector);
        new FeeSplitter(OWNER, DEV, BUY, 2_500, 2_500, new address[](0));
        ops[3] = address(0);
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        new FeeSplitter(OWNER, DEV, BUY, 2_500, 2_500, ops);
    }
}
