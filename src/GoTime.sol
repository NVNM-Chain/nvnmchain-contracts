// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

/// @title GoTime
/// @notice A block time as the module prints it with `ctx.BlockTime().String()`:
///         `2025-09-09 00:00:00 +0000 UTC`.
/// @dev Always UTC and whole seconds: `block.timestamp` has no fraction, and Go prints a whole
///      second without one.
library GoTime {
    /// The last second with a four-digit year.
    uint256 internal constant MAX = 253402300799;

    function format(uint256 unixSeconds) internal pure returns (string memory) {
        // A fifth year digit would not fit the 29 bytes; fail loudly instead of truncating.
        require(unixSeconds <= MAX, "GoTime: year out of range");

        (uint256 y, uint256 m, uint256 d) = _civil(unixSeconds / 86400);
        uint256 rem = unixSeconds % 86400;

        bytes memory out = new bytes(29);
        _digits(out, 0, y, 4);
        out[4] = "-";
        _digits(out, 5, m, 2);
        out[7] = "-";
        _digits(out, 8, d, 2);
        out[10] = " ";
        _digits(out, 11, rem / 3600, 2);
        out[13] = ":";
        _digits(out, 14, (rem / 60) % 60, 2);
        out[16] = ":";
        _digits(out, 17, rem % 60, 2);

        // The UTC offset, then the zone's name.
        bytes memory zone = " +0000 UTC";
        for (uint256 i = 0; i < zone.length; i++) {
            out[19 + i] = zone[i];
        }
        return string(out);
    }

    /// Howard Hinnant's `civil_from_days`: the date `daysSinceEpoch` days after 1970-01-01.
    function _civil(uint256 daysSinceEpoch) private pure returns (uint256 y, uint256 m, uint256 d) {
        uint256 z = daysSinceEpoch + 719468;
        uint256 era = z / 146097;
        uint256 doe = z % 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        d = doy - (153 * mp + 2) / 5 + 1;
        m = mp < 10 ? mp + 3 : mp - 9;
        y = yoe + era * 400 + (m <= 2 ? 1 : 0);
    }

    /// `value` in `width` zero-padded digits.
    function _digits(bytes memory out, uint256 at, uint256 value, uint256 width) private pure {
        for (uint256 i = width; i > 0; i--) {
            out[at + i - 1] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
    }
}
