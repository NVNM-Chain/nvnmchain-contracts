// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Bech32} from "../src/Bech32.sol";

/// The Solidity `encode` the assembly one replaced, kept as the fuzz's oracle.
library ReferenceBech32 {
    bytes32 internal constant CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

    function encode(string memory hrp, bytes20 data) internal pure returns (string memory) {
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

        bytes memory h = bytes(hrp);
        uint256 chk = 1;
        for (uint256 i = 0; i < h.length; i++) {
            chk = _step(chk, uint8(h[i]) >> 5);
        }
        chk = _step(chk, 0);
        for (uint256 i = 0; i < h.length; i++) {
            chk = _step(chk, uint8(h[i]) & 31);
        }
        for (uint256 i = 0; i < 32; i++) {
            chk = _step(chk, five[i]);
        }
        for (uint256 i = 0; i < 6; i++) {
            chk = _step(chk, 0);
        }
        chk ^= 1;

        bytes memory out = new bytes(h.length + 39);
        uint256 w;
        for (uint256 i = 0; i < h.length; i++) {
            out[w++] = h[i];
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

/// Vectors from cosmos-sdk's `bech32.ConvertAndEncode`. Addresses are `hex"..."` because solc
/// would demand EIP-55 casing of a 20-byte hex literal.
contract Bech32Test is Test {
    function testFuzz_matches_the_reference(string calldata hrp, bytes20 data) public pure {
        assertEq(Bech32.encode(hrp, data), ReferenceBech32.encode(hrp, data));
    }

    /// `MainnetRegistryAdmin`, the creator the chain's v1.2 seed wrote on every migrated registry.
    function test_encodes_the_address_the_seed_writes() public pure {
        assertEq(
            Bech32.encode("nvnm", hex"af639dc7632ed8be9718458ef74ded3204ba7ecb"),
            "nvnm14a3em3mr9mvta9ccgk80wn0dxgzt5lkt2r8trx"
        );
    }

    /// The chain's governance authority.
    function test_encodes_the_governance_authority() public pure {
        assertEq(
            Bech32.encode("nvnm", hex"0582bfb2e8561d48636e78f0e6b139d5a842be8f"),
            "nvnm1qkptlvhg2cw5scmw0rcwdvfe6k5y9050pymmm9"
        );
    }

    /// The hrp is inside the checksum: under `cosmos` the payload stays and all six checksum characters change.
    function test_the_hrp_is_inside_the_checksum() public pure {
        assertEq(
            Bech32.encode("cosmos", hex"af639dc7632ed8be9718458ef74ded3204ba7ecb"),
            "cosmos14a3em3mr9mvta9ccgk80wn0dxgzt5lktf9dw83"
        );
    }

    function test_the_edges_are_the_same_length_as_the_rest() public pure {
        assertEq(Bech32.encode("nvnm", bytes20(0)), "nvnm1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqs926r2");
        assertEq(Bech32.encode("nvnm", bytes20(type(uint160).max)), "nvnm1llllllllllllllllllllllllllllllllu5t4yq");
    }
}
