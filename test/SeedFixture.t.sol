// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Anchoring} from "../src/Anchoring.sol";
import {IAnchoring} from "../src/IAnchoring.sol";

/// Writes `layout/seed-fixture.json`: every slot the contract writes for a small corpus. The Go
/// dump writer must produce the same slots from the same inputs. Regenerate with `make layout`.
contract SeedFixtureTest is Test {
    Anchoring internal anchoring;

    address internal constant ALICE = 0x00000000000000000000000000000000000A11cE;
    address internal constant BOB = 0x0000000000000000000000000000000000000B0b;

    uint256 internal constant AT = 1757376000; // whole seconds, like the contract's own timestamps

    string internal constant OUT = "layout/seed-fixture.json";

    /// Chosen for what a writer gets wrong: a uri on each side of 32 bytes, a second version,
    /// one checksum in two registries, a duplicate name in another case, and empty strings.
    function test_write_the_seed_fixture() public {
        anchoring = new Anchoring();
        vm.warp(AT);

        vm.record();

        vm.prank(ALICE, ALICE);
        uint64 first = anchoring.addRegistry("us-ca1", "First Circuit", '{"tranche":1}');
        vm.prank(BOB, BOB);
        uint64 second = anchoring.addRegistry("us-ca9", "Ninth Circuit", "{}");

        vm.prank(ALICE, ALICE);
        anchoring.addRecord(_record(first, "1 C.C.A. 144", "https://www.courtlistener.com/opinion/8857414/x/"));
        // A second version, which clears isLatest on the first.
        vm.prank(ALICE, ALICE);
        anchoring.addRecord(_record(first, "1 C.C.A. 144", "https://www.courtlistener.com/opinion/8857414/y/"));
        // A 32-byte uri, where the string encoding switches.
        vm.prank(ALICE, ALICE);
        anchoring.addRecord(_record(first, "2 C.C.A. 7", "https://ex.test/0123456789abcdef"));
        // The same checksum in a second registry.
        vm.prank(BOB, BOB);
        anchoring.addRecord(_record(second, "1 C.C.A. 144", "https://ex.test/o"));

        // A duplicate name in another case, empty description and metadata, and no records.
        vm.prank(ALICE, ALICE);
        anchoring.addRegistry("US-CA1", "", "");

        vm.prank(ALICE, ALICE);
        anchoring.grantRole(first, "", BOB, "editor");
        vm.prank(ALICE, ALICE);
        anchoring.grantRole(first, "1 C.C.A. 144", BOB, "admin");

        (, bytes32[] memory writes) = vm.accesses(address(anchoring));
        _dump(_sortedUnique(writes));
    }

    function _record(uint64 registryId, string memory checksum, string memory uri)
        private
        pure
        returns (IAnchoring.Record memory)
    {
        return IAnchoring.Record({
            uri: uri,
            checksum: checksum,
            checksumAlgo: "cite-canonical-v1",
            metadata: '{"cluster":8857414,"name":"Richmond v. Atwood"}',
            timestamp: "",
            status: "Active",
            recordId: 0,
            index: 0,
            isLatest: false,
            registryId: registryId
        });
    }

    /// Sorted and deduplicated, so the file depends on the state, not on the order of writes.
    function _sortedUnique(bytes32[] memory slots) private pure returns (bytes32[] memory out) {
        for (uint256 i = 1; i < slots.length; i++) {
            bytes32 key = slots[i];
            uint256 j = i;
            while (j > 0 && uint256(slots[j - 1]) > uint256(key)) {
                slots[j] = slots[j - 1];
                j--;
            }
            slots[j] = key;
        }

        out = new bytes32[](slots.length);
        uint256 n = 0;
        for (uint256 i = 0; i < slots.length; i++) {
            if (n == 0 || out[n - 1] != slots[i]) {
                out[n++] = slots[i];
            }
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    /// A flat slot => value object.
    function _dump(bytes32[] memory slots) private {
        string memory json = "seed";
        string memory body;
        for (uint256 i = 0; i < slots.length; i++) {
            bytes32 value = vm.load(address(anchoring), slots[i]);
            if (value == bytes32(0)) continue; // written, then cleared: nothing to seed
            body = vm.serializeBytes32(json, vm.toString(slots[i]), value);
        }
        vm.writeJson(body, OUT);
    }
}
