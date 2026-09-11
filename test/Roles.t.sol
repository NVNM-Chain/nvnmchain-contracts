// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Roles} from "../src/Roles.sol";

/// Vectors from Go: keccak of the strings `keeper.RegistryRole` and `keeper.RecordRole` format.
/// A mismatch would not fail a call; it would silently lose a migrated grant.
contract RolesTest is Test {
    function test_registry_roles_match_the_keeper() public pure {
        assertEq(
            Roles.forRegistry(1, Roles.ADMIN),
            0x6b3d724913a5b50b16768e04131c5913e11d0212e449e3b6620eb2e4000b3db8,
            "registry:1:admin"
        );
        assertEq(
            Roles.forRegistry(42, Roles.EDITOR),
            0x96d17f75ac9bbf2d8b7deb464208c2c1856b10cbd53e3963f796ae10e754eead,
            "registry:42:editor"
        );
        assertEq(
            Roles.forRegistry(0, Roles.ADMIN),
            0xdc5f30620960944e998e8c71010baa162529d13687faa7d2098022be023f9db4,
            "registry:0:admin"
        );
        assertEq(
            Roles.forRegistry(type(uint64).max, Roles.ADMIN),
            0x851531029566bb4b79ca9b20133ae8e1375367e79ab480be30f1dbcad901861c,
            "registry:18446744073709551615:admin"
        );
        // The corpus's last registry id.
        assertEq(
            Roles.forRegistry(2114, Roles.ADMIN),
            0x6b745cc3df2ae0bb4c77dd86ac77ffa103def6719b8f01f7c7c5ba688cc8ead1,
            "registry:2114:admin"
        );
    }

    function test_record_roles_match_the_keeper() public pure {
        assertEq(
            Roles.forRecord(1, "abc", Roles.ADMIN),
            0x1c02c8c8d8b78bb267b8fd456f83b4e6dae1d4f7e713417686fd5f489455e564,
            "record:1:616263:61646d696e"
        );
        // A real checksum, with spaces and dots.
        assertEq(
            Roles.forRecord(2114, "1 C.C.A. 144", Roles.EDITOR),
            0x2f36f97e117675ede0ade598ca2cf5fc22836dd98361aa0497861f6c5e0e2335,
            "record:2114:3120432e432e412e20313434:656469746f72"
        );
        // A colon, the separator the hex encoding protects.
        assertEq(
            Roles.forRecord(7, "sha256:deadbeef", Roles.ADMIN),
            0x003882e3e0aa6421d678bdb26b9b25234e20b2526447d6bf0e5ada3ad4991026,
            "record:7:7368613235363a6465616462656566:61646d696e"
        );
    }

    /// Without the hex encoding these would be the same string.
    function test_a_checksum_cannot_be_read_as_a_separator() public pure {
        assertTrue(Roles.forRecord(1, "ab", "c") != Roles.forRecord(1, "a", "bc"));
    }

    function testFuzz_registry_and_record_roles_never_collide(uint64 registryId, string calldata checksum) public pure {
        assertTrue(Roles.forRegistry(registryId, Roles.ADMIN) != Roles.forRecord(registryId, checksum, Roles.ADMIN));
    }

    /// The pair forms spell the role names in hex by hand; this ties them to the singular forms.
    function testFuzz_the_pair_forms_agree_with_the_singular_ones(uint64 registryId, string calldata checksum)
        public
        pure
    {
        (bytes32 admin, bytes32 editor) = Roles.bothForRegistry(registryId);
        assertEq(admin, Roles.forRegistry(registryId, Roles.ADMIN));
        assertEq(editor, Roles.forRegistry(registryId, Roles.EDITOR));

        (bytes32 recordAdmin, bytes32 recordEditor) = Roles.bothForRecord(registryId, checksum);
        assertEq(recordAdmin, Roles.forRecord(registryId, checksum, Roles.ADMIN));
        assertEq(recordEditor, Roles.forRecord(registryId, checksum, Roles.EDITOR));
    }
}
