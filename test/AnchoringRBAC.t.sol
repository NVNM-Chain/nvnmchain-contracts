// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AnchoringRBAC} from "../src/AnchoringRBAC.sol";
import {Roles} from "../src/Roles.sol";

/// Exposes the internal functions, to test the rules without `Anchoring`.
contract RBACHarness is AnchoringRBAC {
    function setRoleAdmin(bytes32 role, bytes32 adminRole) external {
        _setRoleAdmin(role, adminRole);
    }

    function grantRole(bytes32 role, address account, address granter) external {
        _grantRole(role, account, granter);
    }

    function grantRoleUnchecked(bytes32 role, address account) external {
        _grantRoleUnchecked(role, account);
    }

    function revokeRole(bytes32 role, address account, address revoker) external {
        _revokeRole(role, account, revoker);
    }

    function isSoleAdmin(bytes32 adminRole) external view returns (bool) {
        return _isSoleAdmin(adminRole);
    }
}

contract AnchoringRBACTest is Test {
    RBACHarness internal rbac;

    bytes32 internal admin = Roles.forRegistry(1, Roles.ADMIN);
    bytes32 internal editor = Roles.forRegistry(1, Roles.EDITOR);

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);

    /// As `AddRegistry` leaves it: the admin role administers itself, and alice holds it.
    function setUp() public {
        rbac = new RBACHarness();
        rbac.setRoleAdmin(admin, admin);
        rbac.grantRoleUnchecked(admin, alice);
    }

    function test_an_admin_grants_and_revokes() public {
        rbac.setRoleAdmin(editor, admin);
        rbac.grantRole(editor, bob, alice);
        assertTrue(rbac.hasRole(editor, bob));

        rbac.revokeRole(editor, bob, alice);
        assertFalse(rbac.hasRole(editor, bob));
    }

    function test_a_non_admin_grants_nothing() public {
        rbac.setRoleAdmin(editor, admin);
        vm.expectRevert("missing required role");
        rbac.grantRole(editor, carol, bob);
    }

    /// An unconfigured role fails before membership is checked, so nobody can satisfy it.
    function test_an_unconfigured_role_cannot_be_granted() public {
        bytes32 stray = Roles.forRegistry(42, Roles.EDITOR);
        vm.expectRevert("role admin not configured");
        rbac.grantRole(stray, bob, alice);
        vm.expectRevert("role admin not configured");
        rbac.revokeRole(stray, bob, alice);
        vm.expectRevert("role admin not configured");
        rbac.getRoleAdmin(stray);
    }

    /// A repeated grant, or revoking a non-member, leaves the count alone.
    function test_the_member_count_tracks_the_members() public {
        assertEq(rbac.roleMemberCount(admin), 1);
        assertTrue(rbac.isSoleAdmin(admin));

        rbac.grantRoleUnchecked(admin, alice);
        assertEq(rbac.roleMemberCount(admin), 1, "granting twice");

        rbac.grantRole(admin, bob, alice);
        assertEq(rbac.roleMemberCount(admin), 2);
        assertFalse(rbac.isSoleAdmin(admin));

        rbac.revokeRole(admin, carol, alice);
        assertEq(rbac.roleMemberCount(admin), 2, "revoking a non-member");

        rbac.revokeRole(admin, bob, alice);
        assertTrue(rbac.isSoleAdmin(admin));
    }

    /// Zero holders is not sole, or the last-admin guard would read backwards.
    function test_an_empty_role_is_not_sole() public view {
        assertFalse(rbac.isSoleAdmin(Roles.forRegistry(99, Roles.ADMIN)));
    }

    /// The last-admin guard lives in `Anchoring.revokeRole`, which knows the registry.
    function test_the_last_admin_guard_is_not_at_this_layer() public {
        rbac.revokeRole(admin, alice, alice);
        assertEq(rbac.roleMemberCount(admin), 0);
    }
}
