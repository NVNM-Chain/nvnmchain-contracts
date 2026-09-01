// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Test, Vm } from "forge-std/Test.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { LibClone } from "solady/utils/LibClone.sol";

import { Registry } from "../src/Registry.sol";
import { RegistryFactory } from "../src/RegistryFactory.sol";
import { ANCHORING_ADDRESS, IAnchoring } from "../src/interfaces/IAnchoring.sol";
import { MockAnchoring } from "./support/MockAnchoring.sol";
import { RegistryDeployer } from "./support/RegistryDeployer.sol";

contract RegistryTest is Test {
    RegistryFactory factory;

    // Pinned to the contract's constants in setUp, so they can never drift from the source.
    bytes32 ADMIN;
    bytes32 EDITOR;

    address owner = makeAddr("safe"); // Safe multisig stand-in: upgrade authority + break-glass
    address creator = makeAddr("creator");
    address editor = makeAddr("editor");
    address stranger = makeAddr("stranger");

    function setUp() public {
        // The precompile is enshrined on-chain; in forge it's the mock, etched at its address.
        vm.etch(ANCHORING_ADDRESS, address(new MockAnchoring()).code);

        // Deploy through the shipped one-shot deployer so the recipe vendored into e2e is the
        // one under test; the pranked CREATE makes `owner` the deployer's msg.sender.
        vm.prank(owner);
        factory = new RegistryDeployer().factory();

        Registry probe = Registry(deploy(creator, "probe"));
        ADMIN = probe.ROLE_ADMIN();
        EDITOR = probe.ROLE_EDITOR();
    }

    function deploy(address as_, string memory name) internal returns (address) {
        vm.prank(as_);
        return factory.deployRegistry(name, "", "");
    }

    function addRecord(address as_, Registry reg, string memory checksum)
        internal
        returns (bytes32 checksumHash, uint256 index)
    {
        return addRecord(as_, reg, checksum, Registry.RecordCategory.Unspecified, "");
    }

    function addRecord(
        address as_,
        Registry reg,
        string memory checksum,
        Registry.RecordCategory category,
        string memory dataPointer
    ) internal returns (bytes32 checksumHash, uint256 index) {
        vm.prank(as_);
        return reg.addRecord("ipfs://a", checksum, "sha256", "{}", category, dataPointer);
    }

    // -- deployment ----------------------------------------------------------
    function test_deployRegistry_isPermissionless_andNamesMayRepeat() public {
        address a = deploy(creator, "docs");
        address b = deploy(stranger, "docs");
        assertTrue(a != b, "names are not unique; the address is canonical");

        // The creator holds the registry admin role in its own registry only.
        assertTrue(Registry(a).hasRole("", creator, ADMIN));
        assertFalse(Registry(b).hasRole("", creator, ADMIN));
    }

    function test_deployRegistry_announcesTheAddressItReturns() public {
        // The log is the whole record of which registries exist -- there is no on-chain
        // set -- so the announcement has to name the address the call handed back.
        vm.recordLogs();
        address reg = deploy(creator, "docs");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 wanted = keccak256("RegistryDeployed(address,address,string,string,string)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(factory) && logs[i].topics[0] == wanted) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), reg, "the registry");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), creator, "its creator");
                return;
            }
        }
        revert("no RegistryDeployed for the returned address");
    }

    function test_deployRegistry_rejectsAnEmptyName() public {
        vm.prank(creator);
        vm.expectRevert(RegistryFactory.EmptyName.selector);
        factory.deployRegistry("", "", "");
    }

    /// The whole point of the design: two registries are two namespaces in the precompile,
    /// so nothing in the key or the payload has to keep them apart.
    function test_registriesAreSeparateNamespacesInTheLog() public {
        Registry a = Registry(deploy(creator, "a"));
        Registry b = Registry(deploy(creator, "b"));
        // The same checksum in both, so the same key -- it derives from the checksum and
        // nothing else. Differing uris keep the two heads apart.
        vm.prank(creator);
        a.addRecord(
            "ipfs://in-a", "shared", "sha256", "{}", Registry.RecordCategory.Unspecified, ""
        );
        vm.prank(creator);
        b.addRecord(
            "ipfs://in-b", "shared", "sha256", "{}", Registry.RecordCategory.Unspecified, ""
        );

        IAnchoring anchoring = IAnchoring(ANCHORING_ADDRESS);
        bytes32 hash = keccak256("shared");
        bytes32 key = a.recordKey(hash);
        assertEq(key, b.recordKey(hash), "the same key in both registries...");
        assertEq(anchoring.latest(address(a), key), a.latestRecordDigest(hash));
        assertEq(anchoring.latest(address(b), key), b.latestRecordDigest(hash));
        assertTrue(
            anchoring.latest(address(a), key) != anchoring.latest(address(b), key),
            "...holding their own heads, because the caller is the partition"
        );
    }

    // -- records -------------------------------------------------------------
    function test_addRecord_identifiesByChecksumAndAnchorsSelfVerifyingDigest() public {
        Registry reg = Registry(deploy(creator, "docs"));
        (bytes32 checksumHash, uint256 index) =
            addRecord(creator, reg, "abc", Registry.RecordCategory.AgenticAI, "did:x#1");
        assertEq(checksumHash, keccak256("abc"), "the checksum hash is the identity");
        assertEq(index, 1);

        // The head is the digest of the exact envelope the event carried. Category and pointer
        // are inside it, so neither can be restated after the fact without a new anchor.
        bytes memory envelope = abi.encode(
            reg.KIND_RECORD(),
            checksumHash,
            index,
            "ipfs://a",
            "abc",
            "sha256",
            "{}",
            Registry.RecordCategory.AgenticAI,
            "did:x#1",
            block.timestamp
        );
        assertEq(reg.latestRecordDigest(checksumHash), keccak256(envelope));
    }

    /// A consumer deduping on `dataPointer` reads it from the log, not the envelope.
    function test_addRecord_emitsCategoryAndPointer() public {
        Registry reg = Registry(deploy(creator, "docs"));

        vm.expectEmit(true, true, true, true);
        emit Registry.RecordAdded(
            keccak256("abc"), 1, "abc", Registry.RecordCategory.MultiPartyClinicalTrials, "trial-7"
        );
        addRecord(creator, reg, "abc", Registry.RecordCategory.MultiPartyClinicalTrials, "trial-7");
    }

    /// The enum is the validation. Both calls are byte-identical bar the category, so the
    /// rejection can only be the category — not a stale selector or a mis-encoded argument.
    function test_addRecord_rejectsAnUnknownCategory() public {
        Registry reg = Registry(deploy(creator, "docs"));

        vm.prank(creator);
        (bool valid,) = address(reg).call(callAddRecord("abc", 4)); // AgenticAI, the last member
        assertTrue(valid, "the last member of the enum is accepted");

        vm.prank(creator);
        (bool tooHigh,) = address(reg).call(callAddRecord("def", 5));
        assertFalse(tooHigh, "one past it is refused at decode");
    }

    function callAddRecord(string memory checksum, uint8 category)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            Registry.addRecord.selector, "ipfs://a", checksum, "sha256", "{}", category, ""
        );
    }

    function test_sameChecksum_isOneStreamAndBumpsIndex() public {
        // The version index inside the envelope keeps digests distinct, so the precompile's
        // no-op rule never fires for a re-anchored identical record.
        Registry reg = Registry(deploy(creator, "docs"));
        (bytes32 h1, uint256 i1) = addRecord(creator, reg, "abc");
        (bytes32 h2, uint256 i2) = addRecord(creator, reg, "abc");
        assertEq(h1, h2, "one stream per checksum");
        assertEq(i1, 1);
        assertEq(i2, 2);
        assertEq(reg.versionCount(h1), 2);
    }

    function test_checksumStreams_arePerRegistry() public {
        Registry a = Registry(deploy(creator, "a"));
        Registry b = Registry(deploy(creator, "b"));
        addRecord(creator, b, "shared");
        addRecord(creator, b, "shared");
        (bytes32 hash,) = addRecord(creator, a, "shared");

        // One identity, two registries: the address separates them, so the version counts
        // run independently even though the key is the same in both.
        assertEq(a.versionCount(hash), 1);
        assertEq(b.versionCount(hash), 2);
    }

    function test_addRecord_requiresARole() public {
        Registry reg = Registry(deploy(creator, "docs"));
        vm.expectRevert(Registry.Unauthorized.selector);
        addRecord(stranger, reg, "abc");
    }

    function test_addRecord_requiresAChecksumAndAUri() public {
        // The checksum *is* the record's identity and an empty uri anchors a version pointing
        // at nothing, so neither is something the contract could supply for the caller.
        Registry reg = Registry(deploy(creator, "docs"));

        // Refused ahead of the role check, so an empty checksum is not a way to ask whether a
        // stream exists either.
        vm.prank(stranger);
        vm.expectRevert(Registry.EmptyChecksum.selector);
        reg.addRecord("ipfs://a", "", "sha256", "{}", Registry.RecordCategory.Unspecified, "");

        vm.prank(creator);
        vm.expectRevert(Registry.EmptyUri.selector);
        reg.addRecord("", "abc", "sha256", "{}", Registry.RecordCategory.Unspecified, "");

        assertEq(reg.versionCount(keccak256("abc")), 0, "neither started a stream");
    }

    /// The keys and tags every off-chain reader derives for itself, against the vectors the
    /// decoder in `nvnmchain-anchoring` holds. Nothing else here notices them moving: the
    /// namespace test compares two registries' derivations to each other, and the kind test
    /// reads the tag out of an envelope this contract just wrote -- both follow a rename.
    function test_theWireFormatIsWhatOffChainReadersDerive() public {
        Registry reg = Registry(deploy(creator, "docs"));
        // `keccak256("0xabc")`, the checksum those vectors were generated for.
        bytes32 hash = 0x851bb152e67e6c958ab7da1431fcaed09ce0efc598885f69a750b3b4b81fc1dc;
        assertEq(hash, keccak256("0xabc"));

        assertEq(reg.KIND_RECORD(), bytes32("record"));
        assertEq(reg.KIND_STATUS(), bytes32("status"));
        assertEq(
            reg.REGISTRY_SCOPE(), 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
        );

        assertEq(
            reg.recordKey(hash), 0x5de9cfc79de28bdb120140799229816d1be7b571e7dc8db35d3f24d2a35142a3
        );
        assertEq(
            reg.statusKey(hash, 1),
            0x40c526ce172b7720c74b54727866222688294b31844db86d18ec1075c5702c61
        );
        assertEq(
            reg.recordRole(hash, EDITOR),
            0xb09af46f64b6fcc046e2a1984e62b5693ebaa204c9d2a2a5227985b5bb238a4e
        );
    }

    function test_everyEnvelopeLeadsWithItsKind() public {
        // An indexer classifies a payload from the log alone, without deriving keys first.
        Registry reg = Registry(deploy(creator, "docs"));
        (bytes32 checksumHash, uint256 index) = addRecord(creator, reg, "abc");
        vm.prank(creator);
        reg.updateRecordStatus("abc", index, "redacted");

        bytes32[2] memory keys = [reg.recordKey(checksumHash), reg.statusKey(checksumHash, index)];
        bytes32[2] memory kinds = [reg.KIND_RECORD(), reg.KIND_STATUS()];

        for (uint256 i; i < keys.length; i++) {
            bytes memory envelope =
                MockAnchoring(ANCHORING_ADDRESS).metadataOf(address(reg), keys[i]);
            assertEq(abi.decode(envelope, (bytes32)), kinds[i]);
        }
    }

    // -- RBAC ----------------------------------------------------------------
    function test_grantAndRevoke_registryEditor() public {
        Registry reg = Registry(deploy(creator, "docs"));

        vm.prank(stranger);
        vm.expectRevert(Registry.Unauthorized.selector);
        reg.grantRole("", editor, EDITOR);

        vm.prank(creator);
        reg.grantRole("", editor, EDITOR);
        addRecord(editor, reg, "abc");

        vm.prank(creator);
        reg.revokeRole("", editor, EDITOR);
        vm.expectRevert(Registry.Unauthorized.selector);
        addRecord(editor, reg, "def");
    }

    function test_recordRole_isScopedToItsChecksumAndRegistry() public {
        // A record-scoped grant must not leak to another checksum, nor to another registry
        // sharing the same checksum — which is now the address doing the scoping.
        Registry a = Registry(deploy(creator, "a"));
        Registry b = Registry(deploy(creator, "b"));
        addRecord(creator, a, "shared");
        addRecord(creator, a, "other");
        addRecord(creator, b, "shared");

        vm.prank(creator);
        a.grantRole("shared", editor, EDITOR);

        addRecord(editor, a, "shared"); // its own scope: ok

        vm.expectRevert(Registry.Unauthorized.selector);
        addRecord(editor, a, "other"); // other checksum: no

        vm.expectRevert(Registry.Unauthorized.selector);
        addRecord(editor, b, "shared"); // other registry: no
    }

    function test_grantRole_requiresTheScopeToExist() public {
        Registry reg = Registry(deploy(creator, "docs"));
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(Registry.NoRecordForChecksum.selector, keccak256("nope"))
        );
        reg.grantRole("nope", editor, EDITOR);
    }

    function test_revokingARoleNeverHeldReverts() public {
        // A revoke names a specific grant, so a wrong one has to fail rather than no-op --
        // succeeding would read as "that account no longer holds it" when it never did.
        Registry reg = Registry(deploy(creator, "docs"));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Registry.MissingRole.selector, stranger, EDITOR));
        reg.revokeRole("", stranger, EDITOR);
    }

    function test_hasRole_answersForARecordScope() public {
        // Every other assertion here reads the registry scope. This is the branch resolving a
        // checksum to its stream, which answers false for one with no stream rather than
        // reverting -- the read an integration reaches for first.
        Registry reg = Registry(deploy(creator, "docs"));
        addRecord(creator, reg, "abc");
        vm.prank(creator);
        reg.grantRole("abc", editor, EDITOR);

        assertTrue(reg.hasRole("abc", editor, EDITOR));
        assertFalse(reg.hasRole("abc", editor, ADMIN), "the role is part of the scope");
        assertFalse(reg.hasRole("", editor, EDITOR), "a record grant is not a registry one");
        assertFalse(reg.hasRole("nope", editor, EDITOR), "a checksum with no stream at all");
    }

    function test_scopesAreAUnion_ratherThanAnOverride() public {
        // `_checkWriter` is an OR, so a record-scoped grant adds a writer to one stream and
        // takes nothing away from a registry-scoped one. There is no way to deny.
        Registry reg = Registry(deploy(creator, "docs"));
        addRecord(creator, reg, "abc");
        vm.prank(creator);
        reg.grantRole("", editor, EDITOR);
        vm.prank(creator);
        reg.grantRole("abc", stranger, EDITOR);

        (, uint256 narrowed) = addRecord(stranger, reg, "abc");
        assertEq(narrowed, 2);
        (, uint256 wide) = addRecord(editor, reg, "abc");
        assertEq(wide, 3, "the registry-scoped writer still reaches the narrowed stream");
        (, uint256 elsewhere) = addRecord(editor, reg, "def");
        assertEq(elsewhere, 1, "and every other one");
    }

    function test_lastRegistryAdmin_cannotBeRevoked() public {
        Registry reg = Registry(deploy(creator, "docs"));

        vm.prank(creator);
        vm.expectRevert(Registry.LastAdmin.selector);
        reg.revokeRole("", creator, ADMIN);

        // With a replacement in place the original can step down.
        vm.prank(creator);
        reg.grantRole("", editor, ADMIN);
        vm.prank(editor);
        reg.revokeRole("", creator, ADMIN);
        assertFalse(reg.hasRole("", creator, ADMIN));
    }

    function test_owner_breakGlass_grantsRegistryAdminOnly() public {
        Registry reg = Registry(deploy(creator, "docs"));
        assertEq(reg.owner(), owner, "every registry reads its break-glass admin back");

        // The owner holds no role in the registry, yet may install a new admin...
        vm.prank(owner);
        reg.grantRole("", stranger, ADMIN);
        assertTrue(reg.hasRole("", stranger, ADMIN));

        // ...but the bypass covers exactly that: not editor grants, not revokes.
        vm.prank(owner);
        vm.expectRevert(Registry.Unauthorized.selector);
        reg.grantRole("", stranger, EDITOR);
        vm.prank(owner);
        vm.expectRevert(Registry.Unauthorized.selector);
        reg.revokeRole("", stranger, ADMIN);
    }

    function test_repeatedGrants_doNotInflateTheAdminCount() public {
        Registry reg = Registry(deploy(creator, "docs"));
        for (uint256 i; i < 3; i++) {
            vm.prank(creator);
            reg.grantRole("", editor, ADMIN);
        }
        vm.prank(editor);
        reg.revokeRole("", creator, ADMIN);
        // Were the count inflated, this second revoke would still pass; it must hit LastAdmin.
        vm.prank(editor);
        vm.expectRevert(Registry.LastAdmin.selector);
        reg.revokeRole("", editor, ADMIN);
    }

    function test_invalidRole_rejected() public {
        Registry reg = Registry(deploy(creator, "docs"));
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Registry.InvalidRole.selector, bytes32("root")));
        reg.grantRole("", editor, "root");
    }

    /// The inverse of the old `test_aclChangesAreAnchored`: role changes are this contract's
    /// state and its own events, so nothing about them reaches the anchored log. A third copy
    /// there would only be something to drift.
    function test_aclChangesAreNotAnchored() public {
        Registry reg = Registry(deploy(creator, "docs"));

        vm.recordLogs();
        vm.prank(creator);
        reg.grantRole("", editor, EDITOR);
        vm.prank(creator);
        reg.revokeRole("", editor, EDITOR);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 anchored = keccak256("Anchored(address,bytes32,bytes32,bytes)");
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != anchored, "no ACL change reaches the log");
        }
        assertFalse(reg.hasRole("", editor, EDITOR), "...but the state moved");
    }

    function test_theCreatorsAdminIsAnnouncedAsAGrant() public {
        // An indexer folding RoleGranted/RoleRevoked must see the creator's admin without a
        // special case for deployment, so the constructor emits it like any other grant.
        vm.recordLogs();
        Registry reg = Registry(deploy(creator, "docs"));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 wanted = keccak256("RoleGranted(bytes32,address,bytes32)");
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(reg) && logs[i].topics[0] == wanted) {
                assertEq(logs[i].topics[1], reg.REGISTRY_SCOPE(), "registry scope");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), creator);
                found = true;
            }
        }
        assertTrue(found, "deployment announces the creator's admin as a grant");
    }

    // -- status --------------------------------------------------------------
    function test_updateRecordStatus_isIdempotentAndAnchored() public {
        Registry reg = Registry(deploy(creator, "docs"));
        (bytes32 checksumHash, uint256 index) = addRecord(creator, reg, "abc");

        // Re-asserting the same status must not trip the precompile's no-op rule: the
        // envelope's sequence number keeps every digest distinct.
        vm.prank(creator);
        reg.updateRecordStatus("abc", index, "redacted");
        vm.prank(creator);
        reg.updateRecordStatus("abc", index, "redacted");

        assertTrue(
            IAnchoring(ANCHORING_ADDRESS).latest(address(reg), reg.statusKey(checksumHash, index))
                != 0
        );
    }

    function test_updateRecordStatus_checksAuthAndExistence() public {
        Registry reg = Registry(deploy(creator, "docs"));
        (bytes32 checksumHash, uint256 index) = addRecord(creator, reg, "abc");

        vm.prank(stranger);
        vm.expectRevert(Registry.Unauthorized.selector);
        reg.updateRecordStatus("abc", index, "x");

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Registry.RecordNotFound.selector, checksumHash, 9));
        reg.updateRecordStatus("abc", 9, "x");

        // A checksum with no stream at all takes the same path -- its version count is zero,
        // so every index is out of range.
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(Registry.RecordNotFound.selector, keccak256("nope"), 1)
        );
        reg.updateRecordStatus("nope", 1, "x");
    }

    function test_ownershipCannotBeRenounced() public {
        // `revokeRole` will not remove a registry's last admin, so an admin whose key is lost
        // is recoverable through the factory's owner and nowhere else.
        Registry reg = Registry(deploy(creator, "docs"));

        vm.prank(owner);
        vm.expectRevert(RegistryFactory.OwnershipCannotBeRenounced.selector);
        factory.renounceOwnership();

        // `Ownable` already refuses the zero address, so the two together are the invariant:
        // the factory always has an owner, and every registry always has a rescuer.
        vm.prank(owner);
        vm.expectRevert(Ownable.NewOwnerIsZeroAddress.selector);
        factory.transferOwnership(address(0));

        assertEq(reg.owner(), owner, "and the registry still reads one back");
    }

    function test_breakGlassFollowsTheFactoryOwner() public {
        // Read through the factory rather than copied at deployment, so transferring
        // ownership moves break-glass for registries that already exist -- not only for the
        // ones deployed afterwards.
        Registry reg = Registry(deploy(creator, "docs"));
        address rescuer = makeAddr("new-safe");

        vm.prank(owner);
        factory.transferOwnership(rescuer);

        assertEq(reg.owner(), rescuer, "an existing registry follows");
        vm.prank(rescuer);
        reg.grantRole("", stranger, ADMIN);
        assertTrue(reg.hasRole("", stranger, ADMIN));

        // ...and the old owner keeps nothing.
        vm.prank(owner);
        vm.expectRevert(Registry.Unauthorized.selector);
        reg.grantRole("", editor, ADMIN);
    }
}
