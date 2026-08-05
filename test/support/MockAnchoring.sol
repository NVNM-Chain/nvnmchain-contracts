// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { IAnchoring } from "../../src/interfaces/IAnchoring.sol";

/// @notice Test stand-in for the anchoring precompile, etched at its address so wrapper tests
///         run in a plain forge EVM. Reproduces the semantics the wrapper depends on: one head
///         per (caller, key), the no-op rule, and the self-verifying `anchorAndHash`.
contract MockAnchoring is IAnchoring {
    mapping(address => mapping(bytes32 => bytes32)) private heads;
    /// @dev Test-only. The real precompile never stores metadata -- it only emits it -- but
    ///      keeping the last payload lets a test read an envelope without decoding logs.
    mapping(address => mapping(bytes32 => bytes)) private payloads;

    function anchor(bytes32 key, bytes32 commitment, bytes calldata metadata) public {
        if (heads[msg.sender][key] == commitment) revert CommitmentUnchanged();
        heads[msg.sender][key] = commitment;
        payloads[msg.sender][key] = metadata;
        emit Anchored(msg.sender, key, commitment, metadata);
    }

    function anchorAndHash(bytes32 key, bytes calldata metadata) external {
        anchor(key, keccak256(metadata), metadata);
    }

    function latest(address namespace, bytes32 key) external view returns (bytes32) {
        return heads[namespace][key];
    }

    /// @notice The envelope last anchored under ``(namespace, key)``. Test-only; see above.
    function metadataOf(address namespace, bytes32 key) external view returns (bytes memory) {
        return payloads[namespace][key];
    }
}
