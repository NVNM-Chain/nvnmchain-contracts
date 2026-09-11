// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {GoTime} from "../src/GoTime.sol";

/// Expected strings are Go's `time.Unix(s, 0).UTC().String()`.
contract GoTimeTest is Test {
    function test_matches_go_across_the_calendar() public pure {
        assertEq(GoTime.format(0), "1970-01-01 00:00:00 +0000 UTC");
        assertEq(GoTime.format(1), "1970-01-01 00:00:01 +0000 UTC");
        assertEq(GoTime.format(86399), "1970-01-01 23:59:59 +0000 UTC");
        assertEq(GoTime.format(86400), "1970-01-02 00:00:00 +0000 UTC");
        assertEq(GoTime.format(68169600), "1972-02-29 00:00:00 +0000 UTC");
        // 2000 is a leap year and 2100 is not.
        assertEq(GoTime.format(951782400), "2000-02-29 00:00:00 +0000 UTC");
        assertEq(GoTime.format(4102444800), "2100-01-01 00:00:00 +0000 UTC");
        assertEq(GoTime.format(4107456000), "2100-02-28 00:00:00 +0000 UTC");
        assertEq(GoTime.format(1583020800), "2020-03-01 00:00:00 +0000 UTC");
        assertEq(GoTime.format(1709164800), "2024-02-29 00:00:00 +0000 UTC");
        assertEq(GoTime.format(1709251199), "2024-02-29 23:59:59 +0000 UTC");
        assertEq(GoTime.format(1757376000), "2025-09-09 00:00:00 +0000 UTC");
        assertEq(GoTime.format(GoTime.MAX), "9999-12-31 23:59:59 +0000 UTC");
    }

    /// 29 bytes fits a short string, so a timestamp costs one slot.
    function test_is_always_twenty_nine_bytes() public pure {
        assertEq(bytes(GoTime.format(0)).length, 29);
        assertEq(bytes(GoTime.format(GoTime.MAX)).length, 29);
    }

    function test_rejects_a_year_it_cannot_print() public {
        vm.expectRevert("GoTime: year out of range");
        this.format(GoTime.MAX + 1);
    }

    /// `expectRevert` needs an external call; a library's internal one is inlined.
    function format(uint256 unixSeconds) external pure returns (string memory) {
        return GoTime.format(unixSeconds);
    }

    /// The clock is the remainder of the day, and the date changes only at midnight.
    function testFuzz_the_clock_is_the_remainder_of_the_day(uint256 unixSeconds) public pure {
        unixSeconds = bound(unixSeconds, 0, GoTime.MAX);
        bytes memory s = bytes(GoTime.format(unixSeconds));
        uint256 rem = unixSeconds % 86400;
        assertEq(_num(s, 11, 2), rem / 3600, "hour");
        assertEq(_num(s, 14, 2), (rem / 60) % 60, "minute");
        assertEq(_num(s, 17, 2), rem % 60, "second");
        assertEq(
            keccak256(bytes(GoTime.format(unixSeconds - rem))),
            keccak256(abi.encodePacked(_slice(s, 0, 11), "00:00:00 +0000 UTC")),
            "midnight"
        );
    }

    function _num(bytes memory s, uint256 at, uint256 width) private pure returns (uint256 n) {
        for (uint256 i = 0; i < width; i++) {
            n = n * 10 + (uint8(s[at + i]) - 48);
        }
    }

    function _slice(bytes memory s, uint256 at, uint256 len) private pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = s[at + i];
        }
    }
}
