// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

/// @title Bech32
/// @notice An address as the module writes `Registry.creator`: `sender.String()`, i.e. `nvnm1…`.
/// @dev Assembly, since every `addRegistry` encodes a creator.
library Bech32 {
    /// @notice `data` in bech32 under `hrp`, checksum included.
    function encode(string memory hrp, bytes20 data) internal pure returns (string memory out) {
        assembly ("memory-safe") {
            // BIP-173's polymod, one five-bit value at a time.
            function step(chk, value) -> next {
                let top := shr(25, chk)
                next := xor(shl(5, and(chk, 0x1ffffff)), value)
                next := xor(next, mul(0x3b6a57b2, and(top, 1)))
                next := xor(next, mul(0x26508e6d, and(shr(1, top), 1)))
                next := xor(next, mul(0x1ea119fa, and(shr(2, top), 1)))
                next := xor(next, mul(0x3d4233dd, and(shr(3, top), 1)))
                next := xor(next, mul(0x2a1462b3, and(shr(4, top), 1)))
            }

            let charset := "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
            let len := mload(hrp)
            let total := add(len, 39) // hrp, "1", 32 data characters, 6 checksum characters
            let src := add(hrp, 32)
            out := mload(0x40)
            mstore(out, total)
            let dst := add(out, 32)

            // The checksum opens over the hrp expanded: its high bits, a zero, its low bits.
            let chk := 1
            for { let i := 0 } lt(i, len) { i := add(i, 1) } {
                let c := byte(0, mload(add(src, i)))
                mstore8(add(dst, i), c)
                chk := step(chk, shr(5, c))
            }
            chk := step(chk, 0)
            for { let i := 0 } lt(i, len) { i := add(i, 1) } {
                chk := step(chk, and(byte(0, mload(add(src, i))), 31))
            }
            dst := add(dst, len)
            mstore8(dst, 0x31) // "1"
            dst := add(dst, 1)

            // 160 bits is exactly 32 five-bit groups, read off the top of the word.
            let bits := shr(96, data)
            for { let i := 0 } lt(i, 32) { i := add(i, 1) } {
                let group := and(shr(sub(155, mul(5, i)), bits), 31)
                chk := step(chk, group)
                mstore8(add(dst, i), byte(group, charset))
            }
            dst := add(dst, 32)

            // Six zeroes close the polymod; the checksum is its 30 bits, xor 1, six characters.
            for { let i := 0 } lt(i, 6) { i := add(i, 1) } { chk := step(chk, 0) }
            chk := xor(chk, 1)
            for { let i := 0 } lt(i, 6) { i := add(i, 1) } {
                mstore8(add(dst, i), byte(and(shr(mul(5, sub(5, i)), chk), 31), charset))
            }
            mstore(0x40, add(add(out, 32), and(add(total, 31), not(31))))
        }
    }
}
