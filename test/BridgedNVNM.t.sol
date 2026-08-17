// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { BridgedNVNM } from "../src/BridgedNVNM.sol";
import { Test } from "forge-std/Test.sol";
import { EnumerableRoles } from "solady/auth/EnumerableRoles.sol";

contract BridgedNVNMTest is Test {
    BridgedNVNM token;

    address owner = makeAddr("safe");
    address bridge = makeAddr("bridge");
    address alice = makeAddr("alice");

    function setUp() public {
        token = new BridgedNVNM(owner);
        vm.prank(owner);
        token.setRole(bridge, 1, true);
    }

    function test_bridgeMintAndBurn() public {
        vm.prank(bridge);
        token.bridgeMint(alice, 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.totalSupply(), 100 ether);

        // Withdrawal: alice approves the bridge, which burns from her.
        vm.prank(alice);
        token.approve(bridge, 40 ether);
        vm.prank(bridge);
        token.bridgeBurn(alice, 40 ether);
        assertEq(token.balanceOf(alice), 60 ether);
        assertEq(token.totalSupply(), 60 ether);
    }

    function test_bridgeBurn_selfNeedsNoAllowance() public {
        vm.startPrank(bridge);
        token.bridgeMint(bridge, 10 ether);
        token.bridgeBurn(bridge, 10 ether);
        vm.stopPrank();
        assertEq(token.totalSupply(), 0);
    }

    function test_nonBridgeCannotMintOrBurn() public {
        vm.startPrank(alice);
        vm.expectRevert(EnumerableRoles.EnumerableRolesUnauthorized.selector);
        token.bridgeMint(alice, 1 ether);
        vm.expectRevert(EnumerableRoles.EnumerableRolesUnauthorized.selector);
        token.bridgeBurn(alice, 1 ether);
        vm.stopPrank();

        // Not even the owner mints — supply changes only via bridges.
        vm.prank(owner);
        vm.expectRevert(EnumerableRoles.EnumerableRolesUnauthorized.selector);
        token.bridgeMint(owner, 1 ether);
    }

    function test_onlyOwnerManagesBridgeRole() public {
        vm.prank(alice);
        vm.expectRevert();
        token.setRole(alice, 1, true);

        // Owner can revoke; revoked bridge loses mint.
        vm.prank(owner);
        token.setRole(bridge, 1, false);
        vm.prank(bridge);
        vm.expectRevert(EnumerableRoles.EnumerableRolesUnauthorized.selector);
        token.bridgeMint(alice, 1 ether);
    }

    function test_burnWithoutAllowanceReverts() public {
        vm.prank(bridge);
        token.bridgeMint(alice, 10 ether);
        vm.prank(bridge);
        vm.expectRevert();
        token.bridgeBurn(alice, 10 ether); // no allowance granted
    }
}
