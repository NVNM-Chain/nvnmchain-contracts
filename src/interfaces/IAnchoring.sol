// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice The anchoring precompile: one append-only Merkle Mountain Range per caller. State is
///         the leaf count and one peak per height, so an append needs no witness; `metadata`
///         is never stored, only emitted, and every event carries the peaks, so a proof needs
///         the log and nothing else.
///
///         A leaf is `keccak256("leaf" ‖ commitment)`, a merge `keccak256("merge" ‖ left ‖ right)`,
///         and the root bags the peaks highest first, `keccak256("bag" ‖ acc ‖ peak)`.
interface IAnchoring {
    /// @notice Appends one leaf to the caller's MMR.
    function appendLeaf(bytes32 commitment, bytes calldata metadata) external returns (bytes32 root);

    /// @notice An aligned perfect subtree to append: its root and height.
    struct Chunk {
        bytes32 root;
        uint8 height;
    }

    /// @notice Appends a batch as the roots of aligned perfect subtrees, in leaf order: a chunk
    ///         of height `h` merges only when the count is a multiple of `2^h`. An empty batch
    ///         changes nothing and returns the current root.
    function appendLeaves(Chunk[] calldata chunks, bytes calldata metadata)
        external
        returns (bytes32 root);

    /// @notice The root of `namespace`'s MMR, or zero if nothing was ever appended.
    function root(address namespace) external view returns (bytes32);

    /// @notice The leaf count and the peaks, highest first — what a proof is checked against.
    function state(address namespace) external view returns (uint256 count, bytes32[] memory peaks);

    /// @notice One leaf landed at `index`.
    event LeafAppended(
        address indexed namespace,
        uint256 indexed index,
        bytes32 commitment,
        bytes32[] peaks,
        bytes metadata
    );

    /// @notice A batch landed from `firstLeaf`, bringing the leaf count to `count`.
    event LeavesAppended(
        address indexed namespace,
        uint256 indexed firstLeaf,
        uint256 count,
        Chunk[] chunks,
        bytes32[] peaks,
        bytes metadata
    );

    /// @notice A chunk of `height` at `count`, which is not a multiple of its size.
    error ChunkNotAligned(uint256 count, uint256 height);
    /// @notice A zero chunk root, which nothing hashes to.
    error ZeroChunkRoot();
}

/// @dev Fixed at genesis.
address constant ANCHORING_ADDRESS = 0x0000000000000000000000000000000000000A00;
