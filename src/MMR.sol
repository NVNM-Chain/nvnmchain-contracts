// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title MMR
/// @notice The anchoring precompile's Merkle Mountain Range, for what has to agree with it off
///         the chain's own path: {MMRVerifier} checks a proof against a root, and the test
///         stand-in for the precompile appends the way the precompile does. The peaks travel
///         highest first, and the leaf count is their heights read as bits.
/// @dev A chunk is a perfect subtree's root, `hashLeaf` at height 0. A chunk of height `h` merges
///      only when the count is a multiple of `2^h`: subtrees are aligned to leaf positions, and
///      that check is what makes a batch reach the root the same leaves reach one by one.
library MMR {
    error PeaksDoNotMatch(bytes32 root);
    error ChunkNotAligned(uint256 count, uint256 height);

    function hashLeaf(bytes32 commitment) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("leaf", commitment));
    }

    function hashMerge(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("merge", left, right));
    }

    /// @notice The first `len` peaks bagged from the highest down; zero when none.
    function bag(bytes32[] memory peaks, uint256 len) internal pure returns (bytes32 out) {
        if (len == 0) return bytes32(0);
        out = peaks[0];
        for (uint256 i = 1; i < len; i++) {
            out = keccak256(abi.encodePacked("bag", out, peaks[i]));
        }
    }

    function popcount(uint256 x) internal pure returns (uint256 n) {
        for (; x != 0; n++) {
            x &= x - 1;
        }
    }

    /// @notice That the first `len` of `peaks` are the MMR `root` describes, holding `count`.
    function check(bytes32 root, bytes32[] memory peaks, uint256 len, uint256 count) internal pure {
        if (len != popcount(count) || bag(peaks, len) != root) revert PeaksDoNotMatch(root);
    }

    /// @notice Merges `node`, a perfect subtree of `height`, at the low end of `peaks` — an
    ///         array with room, `len` of it live — carrying through every peak of consecutive
    ///         height. Returns the live length and count afterwards.
    /// @dev    The precompile's own append, in Solidity: nothing in `src` calls it, and the
    ///         stand-in and the tests that predict a root are what it is here for.
    function push(bytes32[] memory peaks, uint256 len, uint256 count, uint256 height, bytes32 node)
        internal
        pure
        returns (uint256, uint256)
    {
        uint256 size = 1 << height;
        if (count & (size - 1) != 0) revert ChunkNotAligned(count, height);
        while ((count >> height) & 1 == 1) {
            node = hashMerge(peaks[--len], node);
            height++;
        }
        peaks[len++] = node;
        return (len, count + size);
    }

    /// @notice Whether `commitment` is leaf `index` of the MMR `peaks` and `count` describe:
    ///         `siblings` climb from the leaf, lowest first, and must reach its peak.
    function verify(
        bytes32[] memory peaks,
        uint256 count,
        uint256 index,
        bytes32 commitment,
        bytes32[] memory siblings
    ) internal pure returns (bool) {
        if (index >= count) return false;
        // The peak holding the leaf: walk them highest first, each covering 2^h leaves.
        uint256 start = 0;
        uint256 which = 0;
        uint256 height = 0;
        for (uint256 h = 256; h > 0;) {
            h--;
            if ((count >> h) & 1 == 0) continue;
            if (index < start + (1 << h)) {
                height = h;
                break;
            }
            start += 1 << h;
            which++;
        }
        if (siblings.length != height) return false;

        bytes32 node = hashLeaf(commitment);
        uint256 at = index - start;
        for (uint256 level = 0; level < height; level++) {
            node = (at >> level) & 1 == 1
                ? hashMerge(siblings[level], node)
                : hashMerge(node, siblings[level]);
        }
        return node == peaks[which];
    }
}
