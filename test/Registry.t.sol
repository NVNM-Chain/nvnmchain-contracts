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

/// @dev A trivial V2 to prove a beacon upgrade preserves storage and swaps logic for every
///      registry at once.
contract RegistryV2 is Registry {
    function version() external pure returns (uint256) {
        return 2;
    }
}

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
        returns (uint256 recordId, uint256 index)
    {
        vm.prank(as_);
        return reg.addRecord("ipfs://a", checksum, "sha256", "{}");
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
        addRecord(creator, a, "a-doc");
        addRecord(creator, b, "b-doc");

        // Both are recordId 1, so both anchor under the *same* key -- and neither overwrites
        // the other, because the head is stored per (caller, key) and the caller differs.
        IAnchoring anchoring = IAnchoring(ANCHORING_ADDRESS);
        bytes32 key = a.recordKey(1);
        assertEq(key, b.recordKey(1), "the same key in both registries...");
        assertEq(anchoring.latest(address(a), key), a.latestRecordDigest(1));
        assertEq(anchoring.latest(address(b), key), b.latestRecordDigest(1));
        assertTrue(
            anchoring.latest(address(a), key) != anchoring.latest(address(b), key),
            "...holding their own heads, because the caller is the partition"
        );
    }

    // -- records -------------------------------------------------------------
    function test_addRecord_assignsIdsAndAnchorsSelfVerifyingDigest() public {
        Registry reg = Registry(deploy(creator, "docs"));
        (uint256 recordId, uint256 index) = addRecord(creator, reg, "abc");
        assertEq(recordId, 1);
        assertEq(index, 1);

        // The head is the digest of the exact envelope the event carried.
        bytes memory envelope = abi.encode(
            reg.KIND_RECORD(), recordId, index, "ipfs://a", "abc", "sha256", "{}", block.timestamp
        );
        assertEq(reg.latestRecordDigest(recordId), keccak256(envelope));
    }

    function test_sameChecksum_keepsRecordIdAndBumpsIndex() public {
        // The version index inside the envelope keeps digests distinct, so the precompile's
        // no-op rule never fires for a re-anchored identical record.
        Registry reg = Registry(deploy(creator, "docs"));
        (uint256 r1, uint256 i1) = addRecord(creator, reg, "abc");
        (uint256 r2, uint256 i2) = addRecord(creator, reg, "abc");
        assertEq(r1, r2, "one stream per checksum");
        assertEq(i1, 1);
        assertEq(i2, 2);
        assertEq(reg.versionCount(r1), 2);
    }

    function test_checksumStreams_arePerRegistry() public {
        Registry a = Registry(deploy(creator, "a"));
        Registry b = Registry(deploy(creator, "b"));
        addRecord(creator, b, "other");
        (uint256 inA,) = addRecord(creator, a, "shared");
        (uint256 inB,) = addRecord(creator, b, "shared");
        assertEq(inA, 1);
        assertEq(inB, 2, "independent per-registry recordId sequences");
    }

    function test_addRecord_requiresARole() public {
        Registry reg = Registry(deploy(creator, "docs"));
        vm.expectRevert(Registry.Unauthorized.selector);
        addRecord(stranger, reg, "abc");
    }

    function test_everyEnvelopeLeadsWithItsKind() public {
        // An indexer classifies a payload from the log alone, without deriving keys first.
        Registry reg = Registry(deploy(creator, "docs"));
        (uint256 recordId, uint256 index) = addRecord(creator, reg, "abc");
        vm.prank(creator);
        reg.updateRecordStatus(recordId, index, "redacted");

        bytes32[2] memory keys = [reg.recordKey(recordId), reg.statusKey(recordId, index)];
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
        // special case for deployment, so initialize emits it like any other grant.
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
        (uint256 recordId, uint256 index) = addRecord(creator, reg, "abc");

        // Re-asserting the same status must not trip the precompile's no-op rule: the
        // envelope's sequence number keeps every digest distinct.
        vm.prank(creator);
        reg.updateRecordStatus(recordId, index, "redacted");
        vm.prank(creator);
        reg.updateRecordStatus(recordId, index, "redacted");

        assertTrue(
            IAnchoring(ANCHORING_ADDRESS).latest(address(reg), reg.statusKey(recordId, index)) != 0
        );
    }

    function test_updateRecordStatus_checksAuthAndExistence() public {
        Registry reg = Registry(deploy(creator, "docs"));
        (uint256 recordId, uint256 index) = addRecord(creator, reg, "abc");

        vm.prank(stranger);
        vm.expectRevert(Registry.Unauthorized.selector);
        reg.updateRecordStatus(recordId, index, "x");

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Registry.RecordNotFound.selector, recordId, 9));
        reg.updateRecordStatus(recordId, 9, "x");
    }

    // -- upgrade -------------------------------------------------------------
    function test_beaconUpgrade_movesEveryRegistryAtOnce() public {
        Registry a = Registry(deploy(creator, "a"));
        Registry b = Registry(deploy(creator, "b"));
        addRecord(creator, a, "abc");

        address v2 = address(new RegistryV2());
        vm.prank(owner);
        factory.upgradeRegistries(v2);

        // One upgrade, both registries — that is what the beacon buys over N proxies.
        assertEq(RegistryV2(address(a)).version(), 2);
        assertEq(RegistryV2(address(b)).version(), 2);
        assertEq(a.recordIdForChecksum("abc"), 1, "state survives the upgrade");
        assertTrue(a.hasRole("", creator, ADMIN));
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

    function test_aRegistryCannotBeReinitialized() public {
        // initialize grants its first admin, so a second call is a seizure: the caller would
        // write itself in as a registry admin of someone else's registry.
        Registry reg = Registry(deploy(creator, "docs"));
        vm.prank(stranger);
        vm.expectRevert();
        reg.initialize(stranger, stranger);
        assertFalse(reg.hasRole("", stranger, ADMIN));
    }

    function test_aCodelessImplementationIsRefused() public {
        // delegatecall to an account with no code *succeeds* with empty returndata, so a
        // registry behind such a beacon would answer every call with zeros rather than
        // reverting. Both entry points refuse the whole class -- zero and any codeless
        // address (an EOA, a typo) alike.
        for (uint256 i; i < 2; i++) {
            address codeless = i == 0 ? address(0) : makeAddr("eoa");
            vm.prank(owner);
            vm.expectRevert(RegistryFactory.CodelessImplementation.selector);
            factory.upgradeRegistries(codeless);

            RegistryFactory fresh =
                RegistryFactory(LibClone.deployERC1967(address(new RegistryFactory())));
            vm.expectRevert(RegistryFactory.CodelessImplementation.selector);
            fresh.initialize(owner, codeless);
        }
    }

    function test_onlyOwnerUpgrades() public {
        address v2 = address(new RegistryV2());
        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.upgradeRegistries(v2);
    }
}
