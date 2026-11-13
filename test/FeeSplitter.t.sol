// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";

Token constant USD = Token(0x20C0000000000000000000000000000000000000);

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

    function credit(address recipient, uint256 amount) external {
        USD.mint(address(this), amount);
        collectedFees[recipient][address(USD)] += amount;
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
    address constant OPERATOR = address(0x101);

    MockFeeManager fees;
    FeeSplitter splitter;

    function setUp() public {
        vm.etch(address(USD), address(new Token()).code);
        vm.etch(0xfeEC000000000000000000000000000000000000, address(new MockFeeManager()).code);
        fees = MockFeeManager(0xfeEC000000000000000000000000000000000000);
        splitter = new FeeSplitter(OWNER, DEV, BUY, 2_500, 2_500, OPERATOR);
    }

    function test_split_pays_the_cuts_and_holds_the_rest() public {
        fees.credit(address(splitter), 1_000_000);
        assertEq(splitter.split(), 1_000_000);

        assertEq(USD.balanceOf(DEV), 250_000);
        assertEq(USD.balanceOf(BUY), 250_000);
        assertEq(splitter.held(), 500_000);
        assertEq(USD.balanceOf(address(splitter)), 500_000);
    }

    /// Anyone may call `distributeFees` before the splitter exists; what arrived early is split too.
    function test_split_takes_a_balance_paid_out_before_it_was_deployed() public {
        USD.mint(address(splitter), 400_000);
        fees.credit(address(splitter), 600_000);
        assertEq(splitter.split(), 1_000_000);
        assertEq(USD.balanceOf(DEV), 250_000);
    }

    function test_held_shares_are_not_split_again() public {
        fees.credit(address(splitter), 1_000_000);
        splitter.split();
        assertEq(splitter.split(), 0);

        fees.credit(address(splitter), 2_000_000);
        assertEq(splitter.split(), 2_000_000);
        assertEq(USD.balanceOf(DEV), 750_000);
        assertEq(splitter.held(), 1_500_000);
    }

    function test_rounding_goes_to_the_validator() public {
        fees.credit(address(splitter), 1_003);
        splitter.split();
        assertEq(USD.balanceOf(DEV), 250);
        assertEq(splitter.held(), 503);
        assertEq(splitter.split(), 0);
    }

    function test_nothing_is_claimable_before_commencement() public {
        fees.credit(address(splitter), 1_000_000);
        splitter.split();
        vm.expectRevert(FeeSplitter.NotCommenced.selector);
        splitter.claim();
    }

    function test_after_commencement_anyone_pays_the_operator_what_is_held() public {
        fees.credit(address(splitter), 1_000_000);
        splitter.split();
        vm.prank(OWNER);
        splitter.commence();

        assertEq(splitter.claim(), 500_000);
        assertEq(USD.balanceOf(OPERATOR), 500_000);
        assertEq(splitter.held(), 0);
        assertEq(splitter.claim(), 0);
    }

    function test_a_claim_splits_what_arrived_since_the_last_split() public {
        vm.prank(OWNER);
        splitter.commence();
        fees.credit(address(splitter), 1_000_000);

        assertEq(splitter.claim(), 500_000);
        assertEq(USD.balanceOf(DEV), 250_000);
        assertEq(USD.balanceOf(BUY), 250_000);
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

    function test_only_the_operator_moves_its_payout() public {
        vm.prank(OWNER);
        vm.expectRevert(FeeSplitter.NotOperator.selector);
        splitter.moveOperator(OWNER);
        vm.prank(OPERATOR);
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        splitter.moveOperator(address(0));

        address moved = address(0xC1);
        vm.prank(OPERATOR);
        splitter.moveOperator(moved);
        fees.credit(address(splitter), 1_000_000);
        vm.prank(OWNER);
        splitter.commence();
        splitter.claim();
        assertEq(USD.balanceOf(moved), 500_000);
        assertEq(USD.balanceOf(OPERATOR), 0);
    }

    function test_the_constructor_refuses_a_bad_split() public {
        vm.expectRevert(FeeSplitter.InvalidBps.selector);
        new FeeSplitter(OWNER, DEV, BUY, 9_000, 2_000, OPERATOR);
        vm.expectRevert(FeeSplitter.InvalidBps.selector);
        new FeeSplitter(OWNER, DEV, BUY, 2_500, 1_999, OPERATOR);
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        new FeeSplitter(OWNER, DEV, BUY, 2_500, 2_500, address(0));
    }
}
