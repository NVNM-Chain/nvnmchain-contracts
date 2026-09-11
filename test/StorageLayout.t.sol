// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

import {Roles} from "../src/Roles.sol";
import {AnchoringFixture} from "./support/AnchoringFixture.sol";

/// Every slot derived by hand, the way the Go dump writer has to, and checked against real
/// writes. The constants are `layout/anchoring.json`.
contract StorageLayoutTest is AnchoringFixture {
    uint256 internal constant ROLE_ADMIN = 0;
    uint256 internal constant ROLE_MEMBERS = 1;
    uint256 internal constant ROLE_MEMBER_COUNT = 2;
    uint256 internal constant MODULE_ADMIN = 3; // shares its slot with REGISTRY_COUNT
    uint256 internal constant REGISTRY_COUNT = 3;
    uint256 internal constant REGISTRIES = 4;
    uint256 internal constant RECORD_COUNT = 5;
    uint256 internal constant LATEST_INDEX = 6;
    uint256 internal constant RECORDS = 7;
    uint256 internal constant RECORD_ID_BY_CHECKSUM = 8;
    uint256 internal constant REGISTRIES_BY_CHECKSUM = 9;
    uint256 internal constant REGISTRIES_BY_NAME = 10;

    string internal constant CHECKSUM = "1 C.C.A. 144";

    uint64 internal registryId;
    uint64 internal recordId;

    function setUp() public override {
        super.setUp();
        _as(alice);
        registryId = anchoring.addRegistry("us-ca1", "First Circuit", "{}");
        _as(alice);
        recordId = anchoring.addRecord(_record(registryId, CHECKSUM));
    }

    /// 20 + 8 bytes: the address low, the count above it.
    function test_the_module_admin_and_the_registry_count_share_a_slot() public view {
        uint256 packed = uint256(_at(MODULE_ADMIN));
        assertEq(address(uint160(packed)), moduleAdmin, "module admin at offset 0");
        assertEq(uint64(packed >> 160), 1, "registry count at offset 20");
    }

    /// `mapping(uint64 => Registry)`: six slots up from the hashed key.
    function test_a_registry_is_six_slots_from_its_hashed_key() public view {
        uint256 base = uint256(keccak256(abi.encode(uint256(registryId), REGISTRIES)));

        assertEq(uint64(uint256(_at(base))), registryId, "id");
        assertEq(_string(base + 1), "us-ca1", "name");
        assertEq(_string(base + 2), "First Circuit", "description");
        assertEq(_string(base + 3), "nvnm1qqqqqqqqqqqqqqqqqqqqqqqqqqqq5ywwwjr3ky", "creator");
        assertEq(_string(base + 4), "2025-09-09 00:00:00 +0000 UTC", "createdAt");
        assertEq(_string(base + 5), "{}", "metadata");
    }

    /// Three nested mappings: one hash per level, outermost first.
    function test_a_record_is_seven_slots_from_three_nested_hashes() public view {
        uint256 base = _recordBase(registryId, recordId, 1);

        assertEq(_string(base + 0), URI, "uri, which spills out of its slot");
        assertEq(_string(base + 1), CHECKSUM, "checksum");
        assertEq(_string(base + 2), "cite-canonical-v1", "checksumAlgo");
        assertEq(_string(base + 3), '{"cluster":8857414}', "metadata");
        assertEq(_string(base + 4), "2025-09-09 00:00:00 +0000 UTC", "timestamp");
        assertEq(_string(base + 5), "Active", "status");

        // Four fields in the last slot: 8 + 8 + 1 + 8 bytes.
        uint256 packed = uint256(_at(base + 6));
        assertEq(uint64(packed), recordId, "recordId at offset 0");
        assertEq(uint64(packed >> 64), 1, "index at offset 8");
        assertEq(uint8(packed >> 128), 1, "isLatest at offset 16");
        assertEq(uint64(packed >> 136), registryId, "registryId at offset 17");
    }

    /// A string key is hashed as its bytes, unpadded, unlike every other key.
    function test_a_string_key_is_hashed_unpadded() public view {
        uint256 outer = uint256(keccak256(abi.encode(uint256(registryId), RECORD_ID_BY_CHECKSUM)));
        uint256 slot = uint256(keccak256(abi.encodePacked(bytes(CHECKSUM), outer)));
        assertEq(uint64(uint256(_at(slot))), recordId);
    }

    /// A `uint64[]`: length at the hashed slot, elements four to a word from its hash.
    function test_a_registry_id_list_packs_four_to_a_word() public {
        for (uint64 i = 0; i < 3; i++) {
            _as(alice);
            uint64 id = anchoring.addRegistry("us-ca1", "d", "{}");
            _as(alice);
            anchoring.addRecord(_record(id, CHECKSUM));
        }

        uint256 lengthSlot = uint256(keccak256(abi.encodePacked(bytes(CHECKSUM), REGISTRIES_BY_CHECKSUM)));
        assertEq(uint256(_at(lengthSlot)), 4, "length lives at the hashed slot");

        uint256 packed = uint256(_at(uint256(keccak256(abi.encode(lengthSlot)))));
        for (uint64 i = 0; i < 4; i++) {
            assertEq(uint64(packed >> (64 * i)), i + 1, "ascending, four to a word");
        }
    }

    function test_the_name_index_is_a_list_at_a_hashed_name() public view {
        uint256 lengthSlot = uint256(keccak256(abi.encodePacked(bytes("us-ca1"), REGISTRIES_BY_NAME)));
        assertEq(uint256(_at(lengthSlot)), 1);
        assertEq(uint64(uint256(_at(uint256(keccak256(abi.encode(lengthSlot)))))), registryId);
    }

    function test_the_role_tables_are_where_the_seed_writes_them() public view {
        bytes32 role = Roles.forRegistry(registryId, Roles.ADMIN);

        assertEq(_at(uint256(keccak256(abi.encode(role, ROLE_ADMIN)))), role, "a registry admin administers itself");

        uint256 members = uint256(keccak256(abi.encode(role, ROLE_MEMBERS)));
        assertEq(uint256(_at(uint256(keccak256(abi.encode(alice, members))))), 1, "the creator holds it");

        assertEq(uint256(_at(uint256(keccak256(abi.encode(role, ROLE_MEMBER_COUNT))))), 1, "and is the only one");
    }

    function test_the_counters_are_where_the_seed_writes_them() public view {
        assertEq(uint64(uint256(_at(uint256(keccak256(abi.encode(uint256(registryId), RECORD_COUNT)))))), 1);

        uint256 inner = uint256(keccak256(abi.encode(uint256(registryId), LATEST_INDEX)));
        assertEq(uint64(uint256(_at(uint256(keccak256(abi.encode(uint256(recordId), inner)))))), 1);
    }

    // ---- helpers ----

    function _at(uint256 slot) private view returns (bytes32) {
        return vm.load(address(anchoring), bytes32(slot));
    }

    function _recordBase(uint64 registry, uint64 record, uint64 index) private pure returns (uint256) {
        uint256 byRegistry = uint256(keccak256(abi.encode(uint256(registry), RECORDS)));
        uint256 byRecord = uint256(keccak256(abi.encode(uint256(record), byRegistry)));
        return uint256(keccak256(abi.encode(uint256(index), byRecord)));
    }

    /// Under 32 bytes a string sits in its slot with 2·length in the last byte; otherwise the
    /// slot holds 2·length + 1 and the bytes start at `keccak256(slot)`.
    function _string(uint256 slot) private view returns (string memory) {
        uint256 head = uint256(_at(slot));
        if (head & 1 == 0) {
            uint256 shortLen = (head & 0xff) / 2;
            bytes memory packed = new bytes(shortLen);
            for (uint256 i = 0; i < shortLen; i++) {
                packed[i] = bytes1(uint8(head >> (8 * (31 - i))));
            }
            return string(packed);
        }

        uint256 length = (head - 1) / 2;
        uint256 start = uint256(keccak256(abi.encode(slot)));
        bytes memory out = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            out[i] = bytes1(uint8(uint256(_at(start + i / 32)) >> (8 * (31 - (i % 32)))));
        }
        return string(out);
    }
}
