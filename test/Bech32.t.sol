// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Bech32} from "../src/Bech32.sol";

/// Vectors from cosmos-sdk's `bech32.ConvertAndEncode`. Addresses are `hex"..."` because solc
/// would demand EIP-55 casing of a 20-byte hex literal.
contract Bech32Test is Test {
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
