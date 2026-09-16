// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

/// @title GoTime
/// @notice A block time as the module prints it with `ctx.BlockTime().String()`:
///         `2025-09-09 00:00:00 +0000 UTC`.
/// @dev Always UTC and whole seconds: `block.timestamp` has no fraction, and Go prints a whole
///      second without one. Assembly, since every write stamps a row.
library GoTime {
    /// The last second with a four-digit year.
    uint256 internal constant MAX = 253402300799;

    function format(uint256 unixSeconds) internal pure returns (string memory out) {
        // A fifth year digit would not fit the 29 bytes; fail loudly instead of truncating.
        require(unixSeconds <= MAX, "GoTime: year out of range");

        (uint256 y, uint256 m, uint256 d) = _civil(unixSeconds / 86400);
        uint256 rem = unixSeconds % 86400;

        // The 29 bytes are one word: a template, each pair of digits or'ed into its zeroes.
        assembly ("memory-safe") {
            function two(w, at, v) -> r {
                r := or(w, or(shl(mul(8, sub(31, at)), div(v, 10)), shl(mul(8, sub(30, at)), mod(v, 10))))
            }
            let w := "0000-00-00 00:00:00 +0000 UTC"
            w := two(w, 0, div(y, 100))
            w := two(w, 2, mod(y, 100))
            w := two(w, 5, m)
            w := two(w, 8, d)
            w := two(w, 11, div(rem, 3600))
            w := two(w, 14, mod(div(rem, 60), 60))
            w := two(w, 17, mod(rem, 60))
            out := mload(0x40)
            mstore(out, 29)
            mstore(add(out, 32), w)
            mstore(0x40, add(out, 64))
        }
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
}
