// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

import {IAnchoring} from "../src/IAnchoring.sol";
import {AnchoringFixture} from "./support/AnchoringFixture.sol";

/// The read half: `queryServer.Records`' five shapes and three pages, and the `Registries` cursor.
contract AnchoringQueriesTest is AnchoringFixture {
    // ---- records: which shape ----

    function test_a_record_id_without_a_registry_is_refused() public {
        vm.expectRevert("record_id requires registry_id");
        anchoring.records(0, "", 1, 0, _page(0, 0));
    }

    function test_an_index_needs_something_to_index() public {
        vm.expectRevert("index requires registry_id and either record_id or checksum");
        anchoring.records(0, "", 0, 1, _page(0, 0));
        vm.expectRevert("index requires registry_id and either record_id or checksum");
        anchoring.records(1, "", 0, 1, _page(0, 0));
    }

    function test_a_checksum_inside_a_registry_resolves_to_its_record() public {
        uint64 id = _registryWith(3);
        (IAnchoring.Record[] memory got,) = anchoring.records(id, "c2", 0, 0, _page(0, 0));
        assertEq(got.length, 1);
        assertEq(got[0].recordId, 2);
        assertEq(got[0].checksum, "c2");
    }

    function test_a_checksum_that_was_never_anchored_is_not_found() public {
        uint64 id = _registryWith(1);
        vm.expectRevert("record does not exist");
        anchoring.records(id, "nope", 0, 0, _page(0, 0));
    }

    function test_an_index_past_the_last_version_is_not_found() public {
        uint64 id = _registryWith(1);
        vm.expectRevert("record does not exist");
        anchoring.records(id, "", 1, 2, _page(0, 0));
    }

    // ---- records: one registry ----

    function test_a_registry_scan_returns_the_newest_of_each() public {
        uint64 id = _registryWith(3);
        _add(id, "c2"); // a second version of the middle record

        (IAnchoring.Record[] memory got,) = anchoring.records(id, "", 0, 0, _page(0, 0));
        assertEq(got.length, 3, "records, not versions");
        assertEq(got[0].recordId, 1);
        assertEq(got[1].recordId, 2);
        assertEq(got[1].index, 2, "newest version");
        assertEq(got[2].recordId, 3);
    }

    function test_a_registry_scan_pages() public {
        uint64 id = _registryWith(5);

        (IAnchoring.Record[] memory first,) = anchoring.records(id, "", 0, 0, _page(0, 2));
        assertEq(first.length, 2);
        assertEq(first[0].checksum, "c1");
        assertEq(first[1].checksum, "c2");

        (IAnchoring.Record[] memory second,) = anchoring.records(id, "", 0, 0, _page(2, 2));
        assertEq(second[0].checksum, "c3");
        assertEq(second[1].checksum, "c4");

        (IAnchoring.Record[] memory third,) = anchoring.records(id, "", 0, 0, _page(4, 2));
        assertEq(third.length, 1, "a short last page");
        (IAnchoring.Record[] memory past,) = anchoring.records(id, "", 0, 0, _page(5, 2));
        assertEq(past.length, 0, "an offset past the end is empty, not an error");
    }

    // ---- records: one checksum across registries ----

    /// Ascending by registry, as the module's prefix scan returns it, whatever the write order.
    function test_a_checksum_scan_is_ordered_by_registry() public {
        uint64 one = _registry();
        uint64 two = _registry();
        uint64 three = _registry();

        _add(three, "shared");
        _add(one, "shared");
        _add(two, "shared");

        (IAnchoring.Record[] memory got,) = anchoring.records(0, "shared", 0, 0, _page(0, 0));
        assertEq(got.length, 3);
        assertEq(got[0].registryId, one);
        assertEq(got[1].registryId, two);
        assertEq(got[2].registryId, three);
    }

    function test_a_checksum_scan_pages() public {
        uint64 a = _registry();
        uint64 b = _registry();
        _registry();
        _add(a, "shared");
        _add(b, "shared");

        (IAnchoring.Record[] memory page,) = anchoring.records(0, "shared", 0, 0, _page(1, 1));
        assertEq(page.length, 1);
        assertEq(page[0].registryId, b);

        (IAnchoring.Record[] memory none,) = anchoring.records(0, "shared", 0, 0, _page(2, 1));
        assertEq(none.length, 0);
    }

    // ---- records: everything ----

    function test_an_empty_filter_walks_every_registry() public {
        uint64 a = _registryWith(2);
        _registry(); // empty
        uint64 c = _registryWith(3);

        (IAnchoring.Record[] memory got,) = anchoring.records(0, "", 0, 0, _page(0, 0));
        assertEq(got.length, 5);
        assertEq(got[0].registryId, a);
        assertEq(got[1].registryId, a);
        assertEq(got[2].registryId, c);
        assertEq(got[4].registryId, c);
    }

    /// A page can start inside one registry and run into the next.
    function test_an_empty_filter_pages_across_a_registry_boundary() public {
        uint64 a = _registryWith(2);
        uint64 b = _registryWith(2);

        (IAnchoring.Record[] memory got,) = anchoring.records(0, "", 0, 0, _page(1, 2));
        assertEq(got.length, 2);
        assertEq(got[0].registryId, a);
        assertEq(got[0].recordId, 2);
        assertEq(got[1].registryId, b);
        assertEq(got[1].recordId, 1);

        (IAnchoring.Record[] memory past,) = anchoring.records(0, "", 0, 0, _page(4, 2));
        assertEq(past.length, 0);
    }

    /// `defaultPageLimit`.
    function test_an_unasked_limit_is_fifty() public {
        _registryWith(60);
        (IAnchoring.Record[] memory got,) = anchoring.records(0, "", 0, 0, _page(0, 0));
        assertEq(got.length, 50);
    }

    // ---- registries ----

    function test_a_registry_id_returns_just_that_one() public {
        _registry();
        uint64 id = _registry();
        (IAnchoring.Registry[] memory got, IAnchoring.PageResponse memory page) = anchoring.registries(id, _page(0, 0));
        assertEq(got.length, 1);
        assertEq(got[0].id, id);
        assertEq(page.nextKey.length, 0, "a single lookup has no cursor");
    }

    function test_a_missing_registry_is_not_found() public {
        vm.expectRevert("registry does not exist");
        anchoring.registries(9, _page(0, 0));
    }

    /// The cursor is the next id, 8 bytes big-endian, as the SDK encodes a `uint64` key.
    function test_the_cursor_continues_where_the_page_stopped() public {
        for (uint256 i = 0; i < 5; i++) {
            _registry();
        }

        (IAnchoring.Registry[] memory first, IAnchoring.PageResponse memory page) = anchoring.registries(0, _page(0, 2));
        assertEq(first[0].id, 1);
        assertEq(first[1].id, 2);
        assertEq(page.nextKey, abi.encodePacked(uint64(3)));

        (IAnchoring.Registry[] memory second, IAnchoring.PageResponse memory more) =
            anchoring.registries(0, _cursor(page.nextKey, 2, false));
        assertEq(second[0].id, 3);
        assertEq(second[1].id, 4);
        assertEq(more.nextKey, abi.encodePacked(uint64(5)));

        (IAnchoring.Registry[] memory last, IAnchoring.PageResponse memory end) =
            anchoring.registries(0, _cursor(more.nextKey, 2, false));
        assertEq(last.length, 1);
        assertEq(last[0].id, 5);
        assertEq(end.nextKey.length, 0, "the last page has no cursor");
    }

    /// `reverse` applies here and not to `records`, as in the module.
    function test_registries_can_be_walked_backwards() public {
        for (uint256 i = 0; i < 5; i++) {
            _registry();
        }

        (IAnchoring.Registry[] memory got, IAnchoring.PageResponse memory page) =
            anchoring.registries(0, _cursor("", 2, true));
        assertEq(got[0].id, 5);
        assertEq(got[1].id, 4);
        assertEq(page.nextKey, abi.encodePacked(uint64(3)));

        (IAnchoring.Registry[] memory next,) = anchoring.registries(0, _cursor(page.nextKey, 2, true));
        assertEq(next[0].id, 3);
        assertEq(next[1].id, 2);
    }

    function test_an_offset_and_a_cursor_are_not_both_accepted() public {
        _registry();
        IAnchoring.PageRequest memory both = _cursor(abi.encodePacked(uint64(1)), 2, false);
        both.offset = 1;
        vm.expectRevert("invalid request, either offset or key is expected, got both");
        anchoring.registries(0, both);
    }

    function test_an_offset_past_the_last_registry_is_empty() public {
        _registry();
        (IAnchoring.Registry[] memory got,) = anchoring.registries(0, _page(5, 2));
        assertEq(got.length, 0);
    }

    /// `maxPageLimit`.
    function test_a_limit_over_the_ceiling_is_capped() public {
        for (uint256 i = 0; i < 205; i++) {
            _registry();
        }
        (IAnchoring.Registry[] memory got,) = anchoring.registries(0, _page(0, 1000));
        assertEq(got.length, 200);
    }

    // ---- registriesByName ----

    function test_an_exact_name_is_answered_on_chain() public {
        _named("us-ca1");
        uint64 second = _named("us-ca9");
        (IAnchoring.Registry[] memory got,) = anchoring.registriesByName("us-ca9", 0, _page(0, 0));
        assertEq(got.length, 1);
        assertEq(got[0].id, second);
        assertEq(got[0].name, "us-ca9");

        (IAnchoring.Registry[] memory again,) = anchoring.registriesByName("us-ca9", 1, _page(0, 0));
        assertEq(again[0].id, second, "mode 1 is exact match too");
    }

    /// Names are not unique (`8d6cbbd`), so the answer is a list.
    function test_a_name_can_belong_to_several_registries() public {
        uint64 a = _named("dup");
        uint64 b = _named("dup");
        (IAnchoring.Registry[] memory got,) = anchoring.registriesByName("dup", 0, _page(0, 0));
        assertEq(got.length, 2);
        assertEq(got[0].id, a);
        assertEq(got[1].id, b);

        (IAnchoring.Registry[] memory paged,) = anchoring.registriesByName("dup", 0, _page(1, 1));
        assertEq(paged.length, 1);
        assertEq(paged[0].id, b);
    }

    function test_an_unknown_name_is_empty_rather_than_an_error() public {
        _named("us-ca1");
        (IAnchoring.Registry[] memory got,) = anchoring.registriesByName("nope", 0, _page(0, 0));
        assertEq(got.length, 0);
    }

    /// Refused rather than answered with an empty page.
    function test_the_fuzzy_modes_are_refused_rather_than_answered() public {
        _named("us-ca1");
        for (uint8 mode = 2; mode <= 4; mode++) {
            vm.expectRevert("only exact match is on chain; search prefix/suffix/contains off chain");
            anchoring.registriesByName("us-", mode, _page(0, 0));
        }
    }

    function test_a_mode_outside_the_enum_is_refused() public {
        vm.expectRevert("invalid matchMode: want 0/1 exact, 2 prefix, 3 suffix, 4 contains");
        anchoring.registriesByName("us-ca1", 5, _page(0, 0));
    }

    // ---- helpers ----

    function _registry() internal returns (uint64) {
        return _named("us-ca1");
    }

    function _named(string memory name) internal returns (uint64) {
        _as(alice);
        return anchoring.addRegistry(name, "d", "{}");
    }

    /// A registry holding `n` records, checksummed `c1`..`cn`.
    function _registryWith(uint64 n) internal returns (uint64 id) {
        id = _registry();
        for (uint64 i = 1; i <= n; i++) {
            _add(id, string(abi.encodePacked("c", vm.toString(i))));
        }
    }

    function _add(uint64 registryId, string memory checksum) internal {
        _as(alice);
        anchoring.addRecord(_record(registryId, checksum));
    }

    function _cursor(bytes memory key, uint64 limit, bool reverse)
        internal
        pure
        returns (IAnchoring.PageRequest memory)
    {
        return IAnchoring.PageRequest({key: key, offset: 0, limit: limit, countTotal: false, reverse: reverse});
    }
}
