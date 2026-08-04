// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { LibClone } from "solady/utils/LibClone.sol";

import { AnchoringRegistry } from "../src/AnchoringRegistry.sol";
import { ANCHORING_ADDRESS, IAnchoring } from "../src/interfaces/IAnchoring.sol";
import { MockAnchoring } from "./support/MockAnchoring.sol";

/// @dev A trivial V2 to prove upgrades preserve storage and swap logic.
contract AnchoringRegistryV2 is AnchoringRegistry {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract AnchoringRegistryTest is Test {
    AnchoringRegistry reg;

    bytes32 constant ADMIN = "admin";
    bytes32 constant EDITOR = "editor";

    address owner = makeAddr("safe"); // Safe multisig stand-in: upgrade authority + break-glass
    address creator = makeAddr("creator");
    address editor = makeAddr("editor");
    address stranger = makeAddr("stranger");

    function setUp() public {
        // The precompile is enshrined on-chain; in forge it's the mock, etched at its address.
        vm.etch(ANCHORING_ADDRESS, address(new MockAnchoring()).code);

        address impl = address(new AnchoringRegistry());
        reg = AnchoringRegistry(LibClone.deployERC1967(impl));
        reg.initialize(owner);
    }

    function addRegistry(address as_, string memory name) internal returns (uint256) {
        vm.prank(as_);
        return reg.addRegistry(name, "", "");
    }

    function addRecord(address as_, uint256 registryId, string memory checksum)
        internal
        returns (uint256 recordId, uint256 index)
    {
        vm.prank(as_);
        return reg.addRecord(registryId, "ipfs://a", checksum, "sha256", "{}");
    }

    // -- registries ----------------------------------------------------------
    function test_addRegistry_isPermissionless_andNamesMayRepeat() public {
        assertEq(addRegistry(creator, "docs"), 1);
        assertEq(addRegistry(stranger, "docs"), 2, "names are not unique; ids are canonical");
        assertEq(reg.registryCount(), 2);

        // The creator holds the registry admin role; a registry anchor landed in the log.
        assertTrue(reg.hasRole(1, "", creator, ADMIN));
        assertFalse(reg.hasRole(2, "", creator, ADMIN));
        assertTrue(IAnchoring(ANCHORING_ADDRESS).latest(address(reg), reg.registryKey(1)) != 0);
    }

    // -- records -------------------------------------------------------------
    function test_addRecord_assignsIdsAndAnchorsSelfVerifyingDigest() public {
        uint256 id = addRegistry(creator, "docs");
        (uint256 recordId, uint256 index) = addRecord(creator, id, "abc");
        assertEq(recordId, 1);
        assertEq(index, 1);

        // The head is the digest of the exact envelope the event carried.
        bytes memory envelope =
            abi.encode(id, recordId, index, "ipfs://a", "abc", "sha256", "{}", block.timestamp);
        assertEq(reg.latestRecordDigest(id, recordId), keccak256(envelope));
    }

    function test_sameChecksum_keepsRecordIdAndBumpsIndex() public {
        uint256 id = addRegistry(creator, "docs");
        (uint256 r1, uint256 i1) = addRecord(creator, id, "abc");
        (uint256 r2, uint256 i2) = addRecord(creator, id, "abc");
        assertEq(r1, r2, "one stream per checksum");
        assertEq(i1, 1);
        assertEq(i2, 2);
        assertEq(reg.versionCount(id, r1), 2);
    }

    function test_identicalContent_isANewVersion_notANoOpRevert() public {
        // The version index inside the envelope keeps digests distinct, so the precompile's
        // no-op rule never fires for a re-anchored identical record.
        uint256 id = addRegistry(creator, "docs");
        (, uint256 i1) = addRecord(creator, id, "abc");
        (, uint256 i2) = addRecord(creator, id, "abc");
        assertEq(i1 + 1, i2);
    }

    function test_checksumStreams_arePerRegistry() public {
        uint256 a = addRegistry(creator, "a");
        uint256 b = addRegistry(creator, "b");
        addRecord(creator, b, "other");
        (uint256 inA,) = addRecord(creator, a, "shared");
        (uint256 inB,) = addRecord(creator, b, "shared");
        assertEq(inA, 1);
        assertEq(inB, 2, "independent per-registry recordId sequences");
    }

    function test_addRecord_requiresARole() public {
        uint256 id = addRegistry(creator, "docs");
        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        reg.addRecord(id, "ipfs://a", "abc", "sha256", "{}");
    }

    function test_addRecord_unknownRegistryReverts() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(AnchoringRegistry.RegistryNotFound.selector, 99));
        reg.addRecord(99, "ipfs://a", "abc", "sha256", "{}");
    }

    // -- RBAC ----------------------------------------------------------------
    function test_grantAndRevoke_registryEditor() public {
        uint256 id = addRegistry(creator, "docs");

        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        reg.grantRole(id, "", editor, EDITOR);

        vm.prank(creator);
        reg.grantRole(id, "", editor, EDITOR);
        addRecord(editor, id, "abc");

        vm.prank(creator);
        reg.revokeRole(id, "", editor, EDITOR);
        vm.prank(editor);
        vm.expectRevert(Ownable.Unauthorized.selector);
        reg.addRecord(id, "ipfs://a", "def", "sha256", "{}");
    }

    function test_recordRole_isScopedToItsChecksumAndRegistry() public {
        // The question from the design thread: a record-scoped grant must not leak to
        // another checksum, nor to another registry sharing the same checksum.
        uint256 a = addRegistry(creator, "a");
        uint256 b = addRegistry(creator, "b");
        addRecord(creator, a, "shared");
        addRecord(creator, a, "other");
        addRecord(creator, b, "shared");

        vm.prank(creator);
        reg.grantRole(a, "shared", editor, EDITOR);

        addRecord(editor, a, "shared"); // its own scope: ok

        vm.prank(editor);
        vm.expectRevert(Ownable.Unauthorized.selector);
        reg.addRecord(a, "ipfs://a", "other", "sha256", "{}"); // other checksum: no

        vm.prank(editor);
        vm.expectRevert(Ownable.Unauthorized.selector);
        reg.addRecord(b, "ipfs://a", "shared", "sha256", "{}"); // other registry: no
    }

    function test_grantRole_requiresTheScopeToExist() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(AnchoringRegistry.RegistryNotFound.selector, 99));
        reg.grantRole(99, "", editor, EDITOR);

        uint256 id = addRegistry(creator, "docs");
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AnchoringRegistry.NoRecordForChecksum.selector, id, keccak256("nope")
            )
        );
        reg.grantRole(id, "nope", editor, EDITOR);
    }

    function test_lastRegistryAdmin_cannotBeRevoked() public {
        uint256 id = addRegistry(creator, "docs");

        vm.prank(creator);
        vm.expectRevert(AnchoringRegistry.LastAdmin.selector);
        reg.revokeRole(id, "", creator, ADMIN);

        // With a replacement in place the original can step down.
        vm.prank(creator);
        reg.grantRole(id, "", editor, ADMIN);
        vm.prank(editor);
        reg.revokeRole(id, "", creator, ADMIN);
        assertFalse(reg.hasRole(1, "", creator, ADMIN));
    }

    function test_owner_breakGlass_grantsRegistryAdminOnly() public {
        uint256 id = addRegistry(creator, "docs");

        // The owner holds no role in the registry, yet may install a new admin...
        vm.prank(owner);
        reg.grantRole(id, "", stranger, ADMIN);
        assertTrue(reg.hasRole(id, "", stranger, ADMIN));

        // ...but the bypass covers exactly that: not editor grants, not revokes.
        vm.prank(owner);
        vm.expectRevert(Ownable.Unauthorized.selector);
        reg.grantRole(id, "", stranger, EDITOR);
        vm.prank(owner);
        vm.expectRevert(Ownable.Unauthorized.selector);
        reg.revokeRole(id, "", stranger, ADMIN);
    }

    function test_repeatedGrants_doNotInflateTheAdminCount() public {
        uint256 id = addRegistry(creator, "docs");
        for (uint256 i; i < 3; i++) {
            vm.prank(creator);
            reg.grantRole(id, "", editor, ADMIN);
        }
        vm.prank(editor);
        reg.revokeRole(id, "", creator, ADMIN);
        // Were the count inflated, this second revoke would still pass; it must hit LastAdmin.
        vm.prank(editor);
        vm.expectRevert(AnchoringRegistry.LastAdmin.selector);
        reg.revokeRole(id, "", editor, ADMIN);
    }

    function test_invalidRole_rejected() public {
        uint256 id = addRegistry(creator, "docs");
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(AnchoringRegistry.InvalidRole.selector, bytes32("root"))
        );
        reg.grantRole(id, "", editor, "root");
    }

    // -- status --------------------------------------------------------------
    function test_updateRecordStatus_isIdempotentAndAnchored() public {
        uint256 id = addRegistry(creator, "docs");
        (uint256 recordId, uint256 index) = addRecord(creator, id, "abc");

        // Re-asserting the same status must not trip the precompile's no-op rule: the
        // envelope's sequence number keeps every digest distinct.
        vm.prank(creator);
        reg.updateRecordStatus(id, recordId, index, "redacted");
        vm.prank(creator);
        reg.updateRecordStatus(id, recordId, index, "redacted");

        assertTrue(
            IAnchoring(ANCHORING_ADDRESS).latest(address(reg), reg.statusKey(id, recordId, index))
                != 0
        );
    }

    function test_updateRecordStatus_checksAuthAndExistence() public {
        uint256 id = addRegistry(creator, "docs");
        (uint256 recordId, uint256 index) = addRecord(creator, id, "abc");

        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        reg.updateRecordStatus(id, recordId, index, "x");

        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(AnchoringRegistry.RecordNotFound.selector, id, recordId, 9)
        );
        reg.updateRecordStatus(id, recordId, 9, "x");
    }

    // -- upgrade -------------------------------------------------------------
    function test_upgrade_preservesStateAndSwapsLogic() public {
        uint256 id = addRegistry(creator, "docs");
        addRecord(creator, id, "abc");

        address v2 = address(new AnchoringRegistryV2());
        vm.prank(owner);
        reg.upgradeToAndCall(v2, "");

        assertEq(AnchoringRegistryV2(address(reg)).version(), 2);
        assertEq(reg.registryCount(), 1, "state survives the upgrade");
        assertEq(reg.recordIdForChecksum(id, "abc"), 1);
        assertTrue(reg.hasRole(id, "", creator, ADMIN));
    }
}
