// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

/// @title Roles
/// @notice The role ids `x/anchoring/rbac` uses: keccak of the string the keeper formats, so a
///         migrated grant keeps its `bytes32`.
/// @dev `%d` is plain decimal. `%x` hex-encodes the checksum and role, so a colon in either
///      cannot read as a separator. Both are assembly, since every write derives a role.
library Roles {
    string internal constant ADMIN = "admin";
    string internal constant EDITOR = "editor";

    /// @notice `keeper.RegistryRole`: `registry:<id>:<role>`.
    function forRegistry(uint64 registryId, string memory role) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("registry:", _decimal(registryId), ":", role));
    }

    /// @notice `keeper.RecordRole`: `record:<id>:<checksum hex>:<role hex>`.
    function forRecord(uint64 registryId, string memory checksum, string memory role) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("record:", _decimal(registryId), ":", _hex(checksum), ":", _hex(role)));
    }

    /// `ADMIN` and `EDITOR` hex-encoded; `Roles.t.sol` holds the pair forms to the singular ones.
    string private constant ADMIN_HEX = "61646d696e";
    string private constant EDITOR_HEX = "656469746f72";

    /// @notice Both registry roles, formatting the id once.
    function bothForRegistry(uint64 registryId) internal pure returns (bytes32 admin, bytes32 editor) {
        bytes memory prefix = abi.encodePacked("registry:", _decimal(registryId), ":");
        return (keccak256(abi.encodePacked(prefix, ADMIN)), keccak256(abi.encodePacked(prefix, EDITOR)));
    }

    /// @notice Both record roles, hex-encoding the checksum once.
    function bothForRecord(uint64 registryId, string memory checksum)
        internal
        pure
        returns (bytes32 admin, bytes32 editor)
    {
        bytes memory prefix = abi.encodePacked("record:", _decimal(registryId), ":", _hex(checksum), ":");
        return (keccak256(abi.encodePacked(prefix, ADMIN_HEX)), keccak256(abi.encodePacked(prefix, EDITOR_HEX)));
    }

    /// Go's `%d`, so zero is "0".
    function _decimal(uint64 value) private pure returns (string memory out) {
        assembly ("memory-safe") {
            let width := 1
            for { let v := div(value, 10) } v { v := div(v, 10) } { width := add(width, 1) }
            out := mload(0x40)
            mstore(out, width)
            let p := add(add(out, 32), width)
            for { let v := value } 1 {} {
                p := sub(p, 1)
                mstore8(p, add(48, mod(v, 10)))
                v := div(v, 10)
                if iszero(v) { break }
            }
            mstore(0x40, add(out, 64))
        }
    }

    /// Go's `%x` over a string: two lowercase hex digits a byte.
    function _hex(string memory s) private pure returns (string memory out) {
        assembly ("memory-safe") {
            let digits := "0123456789abcdef"
            let len := mload(s)
            let total := mul(len, 2)
            out := mload(0x40)
            mstore(out, total)
            let src := add(s, 32)
            let dst := add(out, 32)
            for { let i := 0 } lt(i, len) { i := add(i, 1) } {
                let b := byte(0, mload(add(src, i)))
                mstore8(dst, byte(shr(4, b), digits))
                mstore8(add(dst, 1), byte(and(b, 0x0f), digits))
                dst := add(dst, 2)
            }
            mstore(0x40, add(add(out, 32), and(add(total, 31), not(31))))
        }
    }
}
