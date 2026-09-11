// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

import {Anchoring} from "../src/Anchoring.sol";
import {IAnchoring} from "../src/IAnchoring.sol";
import {Roles} from "../src/Roles.sol";
import {AnchoringFixture} from "./support/AnchoringFixture.sol";

/// The write half: what the chain sets, who may write, and what it refuses.
contract AnchoringTest is AnchoringFixture {
    function _registry(address owner) internal returns (uint64) {
        _as(owner);
        return anchoring.addRegistry("us-ca1", "First Circuit", "{}");
    }

    // ---- addRegistry ----

    function test_a_registry_is_created_as_the_module_creates_it() public {
        vm.expectEmit(true, false, false, true);
        emit IAnchoring.AddRegistry(alice, 1, "us-ca1");
        uint64 id = _registry(alice);
        assertEq(id, 1, "ids start at one");

        (IAnchoring.Registry[] memory got,) = anchoring.registries(1, _page(0, 0));
        assertEq(got[0].id, 1);
        assertEq(got[0].name, "us-ca1");
        assertEq(got[0].description, "First Circuit");
        assertEq(got[0].metadata, "{}");
        // As Go's `bech32.ConvertAndEncode` and `time.Time.String()` print them.
        assertEq(got[0].creator, "nvnm1qqqqqqqqqqqqqqqqqqqqqqqqqqqq5ywwwjr3ky");
        assertEq(got[0].createdAt, "2025-09-09 00:00:00 +0000 UTC");
    }

    function test_the_creator_is_the_registrys_first_admin() public {
        uint64 id = _registry(alice);
        assertTrue(anchoring.hasRole(Roles.forRegistry(id, Roles.ADMIN), alice));
        assertEq(anchoring.roleMemberCount(Roles.forRegistry(id, Roles.ADMIN)), 1);
    }

    function test_registry_ids_keep_counting() public {
        assertEq(_registry(alice), 1);
        assertEq(_registry(bob), 2);
        assertEq(_registry(alice), 3);
    }

    function test_a_registry_needs_a_name() public {
        _as(alice);
        vm.expectRevert("name cannot be empty");
        anchoring.addRegistry("", "d", "{}");
    }

    function test_a_registry_name_has_a_limit() public {
        _as(alice);
        vm.expectRevert("name exceeds max length");
        anchoring.addRegistry(_repeat(129), "d", "{}");
    }

    // ---- addRecord ----

    function test_a_record_is_stored_with_the_chains_own_fields() public {
        uint64 id = _registry(alice);

        vm.expectEmit(true, false, false, true);
        emit IAnchoring.AddRecord(alice, id, 1, 1, "1 C.C.A. 144");
        _as(alice);
        uint64 recordId = anchoring.addRecord(_record(id, "1 C.C.A. 144"));
        assertEq(recordId, 1);

        (IAnchoring.Record[] memory got,) = anchoring.records(id, "", recordId, 0, _page(0, 0));
        assertEq(got[0].recordId, 1, "submitted 999");
        assertEq(got[0].index, 1, "submitted 999");
        assertTrue(got[0].isLatest, "submitted false");
        assertEq(got[0].timestamp, "2025-09-09 00:00:00 +0000 UTC", 'submitted "whenever"');
        assertEq(got[0].checksum, "1 C.C.A. 144");
        assertEq(got[0].checksumAlgo, "cite-canonical-v1");
        assertEq(got[0].status, "Active");
        assertEq(got[0].registryId, id);
    }

    /// The same checksum again is a new version; only the newest is latest.
    function test_the_same_checksum_versions_the_record() public {
        uint64 id = _registry(alice);
        _as(alice);
        uint64 first = anchoring.addRecord(_record(id, "1 C.C.A. 144"));
        _as(alice);
        uint64 second = anchoring.addRecord(_record(id, "1 C.C.A. 144"));
        assertEq(first, second, "one record id");

        (IAnchoring.Record[] memory latest,) = anchoring.records(id, "", first, 0, _page(0, 0));
        assertEq(latest[0].index, 2);
        assertTrue(latest[0].isLatest);

        (IAnchoring.Record[] memory previous,) = anchoring.records(id, "", first, 1, _page(0, 0));
        assertEq(previous[0].index, 1);
        assertFalse(previous[0].isLatest, "superseded");
    }

    function test_a_different_checksum_is_a_different_record() public {
        uint64 id = _registry(alice);
        _as(alice);
        assertEq(anchoring.addRecord(_record(id, "a")), 1);
        _as(alice);
        assertEq(anchoring.addRecord(_record(id, "b")), 2);
    }

    function test_a_record_needs_a_registry_that_exists() public {
        _registry(alice);
        _as(alice);
        vm.expectRevert("registry does not exist");
        anchoring.addRecord(_record(7, "a"));
    }

    function test_a_stranger_cannot_add_a_record() public {
        uint64 id = _registry(alice);
        _as(bob);
        vm.expectRevert("unauthorized");
        anchoring.addRecord(_record(id, "a"));
    }

    /// `types.ValidateRecordForCreate`, field by field.
    function test_a_record_is_validated_before_anything_else() public {
        uint64 id = _registry(alice);
        IAnchoring.Record memory r = _record(id, "a");

        r.checksum = "";
        _expectAddRecordRevert(r, "checksum cannot be empty");
        r.checksum = "a";

        r.checksumAlgo = "";
        _expectAddRecordRevert(r, "checksum algorithm cannot be empty");
        r.checksumAlgo = "cite-canonical-v1";

        r.uri = "";
        _expectAddRecordRevert(r, "uri cannot be empty");
        r.uri = "u";

        r.metadata = "";
        _expectAddRecordRevert(r, "metadata cannot be empty");
        r.metadata = "{}"; // empty too
        _expectAddRecordRevert(r, "metadata cannot be empty");
        r.metadata = '{"a":1}';

        r.status = "";
        _expectAddRecordRevert(r, "status cannot be empty");
        r.status = "Active";

        r.registryId = 0;
        _expectAddRecordRevert(r, "registry ID cannot be zero");
    }

    /// Caps are inclusive; the export's longest metadata is exactly 2048 bytes.
    function test_a_field_at_its_cap_is_accepted() public {
        uint64 id = _registry(alice);
        IAnchoring.Record memory r = _record(id, "a");

        r.metadata = _repeat(2048);
        _as(alice);
        assertEq(anchoring.addRecord(r), 1, "2048 is allowed");

        r.metadata = _repeat(2049);
        _expectAddRecordRevert(r, "metadata exceeds max length");

        r.metadata = '{"a":1}';
        r.checksum = _repeat(64);
        _as(alice);
        assertEq(anchoring.addRecord(r), 2, "64 is allowed");
        r.checksum = _repeat(65);
        _expectAddRecordRevert(r, "checksum exceeds max length");
    }

    // ---- updateRecordStatus ----

    function test_a_status_is_updated_in_place() public {
        uint64 id = _registry(alice);
        _as(alice);
        uint64 recordId = anchoring.addRecord(_record(id, "a"));

        vm.expectEmit(true, false, false, true);
        emit IAnchoring.UpdateRecordStatus(alice, id, recordId, 1, "Revoked");
        _as(alice);
        anchoring.updateRecordStatus(id, recordId, 1, "Revoked");

        (IAnchoring.Record[] memory got,) = anchoring.records(id, "", recordId, 1, _page(0, 0));
        assertEq(got[0].status, "Revoked");
        assertTrue(got[0].isLatest, "status is not a new version");
    }

    function test_a_status_update_needs_a_record() public {
        uint64 id = _registry(alice);
        _as(alice);
        vm.expectRevert("record does not exist");
        anchoring.updateRecordStatus(id, 1, 1, "Revoked");
    }

    function test_a_stranger_cannot_update_a_status() public {
        uint64 id = _registry(alice);
        _as(alice);
        uint64 recordId = anchoring.addRecord(_record(id, "a"));
        _as(bob);
        vm.expectRevert("unauthorized");
        anchoring.updateRecordStatus(id, recordId, 1, "Revoked");
    }

    // ---- roles ----

    function test_an_admin_delegates_editing_to_a_registry() public {
        uint64 id = _registry(alice);

        vm.expectEmit(true, false, false, true);
        emit IAnchoring.GrantRole(alice, id, "", bob, Roles.EDITOR);
        _as(alice);
        anchoring.grantRole(id, "", bob, Roles.EDITOR);

        _as(bob);
        assertEq(anchoring.addRecord(_record(id, "a")), 1);
    }

    function test_a_record_role_is_scoped_to_its_checksum() public {
        uint64 id = _registry(alice);
        _as(alice);
        anchoring.addRecord(_record(id, "a"));

        _as(alice);
        anchoring.grantRole(id, "a", bob, Roles.EDITOR);

        _as(bob);
        anchoring.addRecord(_record(id, "a")); // a second version, allowed

        _as(bob);
        vm.expectRevert("unauthorized");
        anchoring.addRecord(_record(id, "b"));
    }

    function test_a_role_needs_a_scope_that_exists() public {
        uint64 id = _registry(alice);
        _as(alice);
        vm.expectRevert("registry does not exist");
        anchoring.grantRole(9, "", bob, Roles.EDITOR);

        _as(alice);
        vm.expectRevert("record does not exist in registry");
        anchoring.grantRole(id, "never-anchored", bob, Roles.EDITOR);
    }

    function test_a_non_admin_cannot_delegate() public {
        uint64 id = _registry(alice);
        _as(alice);
        anchoring.grantRole(id, "", bob, Roles.EDITOR);

        _as(bob); // an editor, not an admin
        vm.expectRevert("missing required role");
        anchoring.grantRole(id, "", carol, Roles.EDITOR);
    }

    /// Break-glass: the module admin installs a registry admin without holding the role.
    function test_the_module_admin_can_install_a_registry_admin() public {
        uint64 id = _registry(alice);

        _as(moduleAdmin);
        anchoring.grantRole(id, "", carol, Roles.ADMIN);
        assertTrue(anchoring.hasRole(Roles.forRegistry(id, Roles.ADMIN), carol));

        // Registry admin only; any other role goes through the check.
        _as(moduleAdmin);
        vm.expectRevert("missing required role");
        anchoring.grantRole(id, "", carol, Roles.EDITOR);
    }

    function test_a_role_is_revoked() public {
        uint64 id = _registry(alice);
        _as(alice);
        anchoring.grantRole(id, "", bob, Roles.EDITOR);

        vm.expectEmit(true, false, false, true);
        emit IAnchoring.RevokeRole(alice, id, "", bob, Roles.EDITOR);
        _as(alice);
        anchoring.revokeRole(id, "", bob, Roles.EDITOR);

        _as(bob);
        vm.expectRevert("unauthorized");
        anchoring.addRecord(_record(id, "a"));
    }

    function test_revoking_a_role_nobody_holds_says_so() public {
        uint64 id = _registry(alice);
        _as(alice);
        vm.expectRevert("address does not have the specified role");
        anchoring.revokeRole(id, "", bob, Roles.EDITOR);
    }

    /// A registry keeps an admin: appoint another before the last one leaves.
    function test_the_last_admin_cannot_be_revoked() public {
        uint64 id = _registry(alice);

        _as(alice);
        vm.expectRevert("cannot revoke the last registry admin");
        anchoring.revokeRole(id, "", alice, Roles.ADMIN);

        _as(alice);
        anchoring.grantRole(id, "", bob, Roles.ADMIN);
        _as(bob);
        anchoring.revokeRole(id, "", alice, Roles.ADMIN);
        assertFalse(anchoring.hasRole(Roles.forRegistry(id, Roles.ADMIN), alice));
    }

    /// Each of these reverts either way; what is pinned is which error the caller sees.
    function test_a_role_request_is_validated_in_the_modules_order() public {
        uint64 id = _registry(alice);

        _as(alice);
        vm.expectRevert("registry ID cannot be zero");
        anchoring.grantRole(0, "", bob, Roles.EDITOR);

        _as(alice);
        vm.expectRevert("checksum exceeds max length");
        anchoring.grantRole(id, _repeat(65), bob, Roles.EDITOR);

        _as(alice);
        vm.expectRevert("role cannot be empty");
        anchoring.grantRole(id, "", bob, "");

        _as(alice);
        vm.expectRevert("role cannot be empty");
        anchoring.revokeRole(id, "", bob, "");
    }

    function test_a_status_update_is_validated_in_the_modules_order() public {
        uint64 id = _registry(alice);
        _as(alice);
        uint64 recordId = anchoring.addRecord(_record(id, "a"));

        _as(alice);
        vm.expectRevert("record ID cannot be zero"); // before the status
        anchoring.updateRecordStatus(id, 0, 1, "");

        _as(alice);
        vm.expectRevert("status cannot be empty");
        anchoring.updateRecordStatus(id, recordId, 1, "");

        _as(alice);
        vm.expectRevert("index cannot be zero");
        anchoring.updateRecordStatus(id, recordId, 0, "Revoked");
    }

    /// An error, not an empty page: the two mean different things.
    function test_a_name_search_needs_a_name() public {
        _registry(alice);
        vm.expectRevert("name must be provided");
        anchoring.registriesByName("", 1, _page(0, 0));
    }

    // ---- the EOA gate ----

    function test_a_contract_cannot_call_a_transaction_method() public {
        Caller proxy = new Caller(anchoring);
        vm.prank(alice, alice);
        vm.expectRevert("sender not an eoa");
        proxy.addRegistry();
    }

    /// `msg.sender == tx.origin` alone would admit a contract that is also the origin.
    function test_an_origin_with_code_is_not_an_eoa() public {
        Caller proxy = new Caller(anchoring);
        vm.prank(address(proxy), address(proxy));
        vm.expectRevert("sender not an eoa");
        anchoring.addRegistry("us-ca1", "d", "{}");
    }

    /// A 7702 delegation, 0xef0100 and an address, is still an EOA.
    function test_a_delegated_account_is_still_an_eoa() public {
        vm.etch(alice, abi.encodePacked(hex"ef0100", bob));
        _as(alice);
        assertEq(anchoring.addRegistry("us-ca1", "d", "{}"), 1);
    }

    // ---- helpers ----

    function _expectAddRecordRevert(IAnchoring.Record memory r, string memory reason) private {
        _as(alice);
        vm.expectRevert(bytes(reason));
        anchoring.addRecord(r);
    }

    function _repeat(uint256 n) private pure returns (string memory) {
        bytes memory out = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = "x";
        }
        return string(out);
    }
}

/// Forwards a call, so the EOA gate has something to refuse.
contract Caller {
    Anchoring private immutable ANCHORING;

    constructor(Anchoring anchoring) {
        ANCHORING = anchoring;
    }

    function addRegistry() external returns (uint64) {
        return ANCHORING.addRegistry("us-ca1", "d", "{}");
    }
}
