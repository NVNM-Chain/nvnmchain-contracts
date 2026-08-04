// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice The anchoring precompile: an append-only, caller-partitioned commitment log.
///         State is one word per (namespace, key) — the latest commitment; history and
///         payloads live in the `Anchored` event log. Re-writing the stored commitment
///         reverts `CommitmentUnchanged()`.
interface IAnchoring {
    /// @notice Anchors `commitment` under the caller's namespace at `key`.
    ///         `metadata` is never stored, only emitted.
    function anchor(bytes32 key, bytes32 commitment, bytes calldata metadata) external;

    /// @notice Anchors `keccak256(metadata)`, making the emitted event self-verifying.
    function anchorAndHash(bytes32 key, bytes calldata metadata) external;

    /// @notice The latest commitment for `(namespace, key)`, or zero if never anchored.
    function latest(address namespace, bytes32 key) external view returns (bytes32 commitment);

    event Anchored(address indexed caller, bytes32 indexed key, bytes32 commitment, bytes metadata);

    error CommitmentUnchanged();
}

/// @dev Fixed at genesis.
address constant ANCHORING_ADDRESS = 0x0000000000000000000000000000000000000A00;
