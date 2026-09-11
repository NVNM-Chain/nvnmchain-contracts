// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

/// @title Bech32
/// @notice An address as the module writes `Registry.creator`: `sender.String()`, i.e. `nvnm1…`.
library Bech32 {
    /// 32 characters, so it fits a word and a lookup is an index, not a memory copy.
    bytes32 internal constant CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

    /// @notice `data` in bech32 under `hrp`, checksum included.
    function encode(string memory hrp, bytes20 data) internal pure returns (string memory) {
        // 160 bits is exactly 32 five-bit groups, so nothing is padded.
        uint8[] memory five = new uint8[](32);
        uint256 acc;
        uint256 bits;
        uint256 at;
        for (uint256 i = 0; i < 20; i++) {
            acc = (acc << 8) | uint8(data[i]);
            bits += 8;
            while (bits >= 5) {
                bits -= 5;
                five[at++] = uint8((acc >> bits) & 31);
            }
        }

        uint256 chk = _checksum(hrp, five);
        bytes memory hrpBytes = bytes(hrp);
        bytes memory out = new bytes(hrpBytes.length + 1 + 32 + 6);
        uint256 w;
        for (uint256 i = 0; i < hrpBytes.length; i++) {
            out[w++] = hrpBytes[i];
        }
        out[w++] = "1";
        for (uint256 i = 0; i < 32; i++) {
            out[w++] = CHARSET[five[i]];
        }
        for (uint256 i = 0; i < 6; i++) {
            out[w++] = CHARSET[(chk >> (5 * (5 - i))) & 31];
        }
        return string(out);
    }

    /// BIP-173's checksum over the expanded hrp, the payload and six zeroes.
    function _checksum(string memory hrp, uint8[] memory five) private pure returns (uint256) {
        bytes memory h = bytes(hrp);
        uint256 chk = 1;
        for (uint256 i = 0; i < h.length; i++) {
            chk = _step(chk, uint8(h[i]) >> 5);
        }
        chk = _step(chk, 0);
        for (uint256 i = 0; i < h.length; i++) {
            chk = _step(chk, uint8(h[i]) & 31);
        }
        for (uint256 i = 0; i < five.length; i++) {
            chk = _step(chk, five[i]);
        }
        for (uint256 i = 0; i < 6; i++) {
            chk = _step(chk, 0);
        }
        return chk ^ 1;
    }

    function _step(uint256 chk, uint256 value) private pure returns (uint256) {
        uint256 top = chk >> 25;
        chk = ((chk & 0x1ffffff) << 5) ^ value;
        if (top & 1 != 0) chk ^= 0x3b6a57b2;
        if (top & 2 != 0) chk ^= 0x26508e6d;
        if (top & 4 != 0) chk ^= 0x1ea119fa;
        if (top & 8 != 0) chk ^= 0x3d4233dd;
        if (top & 16 != 0) chk ^= 0x2a1462b3;
        return chk;
    }
}
