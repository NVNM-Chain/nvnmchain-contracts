// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

/// @title Roles
/// @notice The role ids `x/anchoring/rbac` uses: keccak of the string the keeper formats, so a
///         migrated grant keeps its `bytes32`.
/// @dev `%d` is plain decimal. `%x` hex-encodes the checksum and role, so a colon in either
///      cannot read as a separator.
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
    function _decimal(uint64 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 width;
        for (uint64 v = value; v != 0; v /= 10) {
            width++;
        }
        bytes memory out = new bytes(width);
        for (uint256 i = width; i > 0; i--) {
            out[i - 1] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(out);
    }

    /// Go's `%x` over a string: two lowercase hex digits a byte.
    function _hex(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(b.length * 2);
        for (uint256 i = 0; i < b.length; i++) {
            out[2 * i] = _nibble(uint8(b[i]) >> 4);
            out[2 * i + 1] = _nibble(uint8(b[i]) & 0x0f);
        }
        return string(out);
    }

    function _nibble(uint8 v) private pure returns (bytes1) {
        return bytes1(v < 10 ? 48 + v : 87 + v);
    }
}
