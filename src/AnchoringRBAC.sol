// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

/// @title AnchoringRBAC
/// @notice The tables `x/anchoring/rbac` keeps: each role's admin role and its members.
/// @dev Not OpenZeppelin's `AccessControl`, whose rules differ: no last-admin guard here, and the
///      zero role means "unconfigured". `_roleMemberCount` is added to answer `IsSoleAdmin`.
abstract contract AnchoringRBAC {
    mapping(bytes32 => bytes32) internal _roleAdmin; // role => the role that administers it
    mapping(bytes32 => mapping(address => bool)) internal _roleMembers;
    mapping(bytes32 => uint256) internal _roleMemberCount;

    bytes32 internal constant NO_ROLE = bytes32(0); // `rbac.DefaultRoleAdmin`: unconfigured

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roleMembers[role][account];
    }

    function roleMemberCount(bytes32 role) public view returns (uint256) {
        return _roleMemberCount[role];
    }

    /// @notice Reverts for an unconfigured role, as `GetRoleAdmin` does, rather than returning zero.
    function getRoleAdmin(bytes32 role) public view returns (bytes32) {
        bytes32 admin = _roleAdmin[role];
        require(admin != NO_ROLE, "role admin not configured");
        return admin;
    }

    function _setRoleAdmin(bytes32 role, bytes32 adminRole) internal {
        _roleAdmin[role] = adminRole;
    }

    /// `GrantRole`: the granter must hold the role's admin role.
    function _grantRole(bytes32 role, address account, address granter) internal {
        require(hasRole(getRoleAdmin(role), granter), "missing required role");
        _grantRoleUnchecked(role, account);
    }

    /// `GrantRoleUnchecked`, for a registry's creator and the break-glass path. Idempotent.
    function _grantRoleUnchecked(bytes32 role, address account) internal {
        if (_roleMembers[role][account]) return;
        _roleMembers[role][account] = true;
        _roleMemberCount[role]++;
    }

    /// `RevokeRole`: the revoker must hold the role's admin role.
    function _revokeRole(bytes32 role, address account, address revoker) internal {
        require(hasRole(getRoleAdmin(role), revoker), "missing required role");
        _revokeRoleUnchecked(role, account);
    }

    function _revokeRoleUnchecked(bytes32 role, address account) internal {
        if (!_roleMembers[role][account]) return;
        _roleMembers[role][account] = false;
        _roleMemberCount[role]--;
    }

    /// `IsSoleAdmin`: exactly one holder.
    function _isSoleAdmin(bytes32 adminRole) internal view returns (bool) {
        return _roleMemberCount[adminRole] == 1;
    }
}
