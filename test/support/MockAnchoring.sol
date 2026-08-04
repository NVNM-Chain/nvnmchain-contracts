// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { IAnchoring } from "../../src/interfaces/IAnchoring.sol";

/// @notice Test stand-in for the anchoring precompile, etched at its address so wrapper tests
///         run in a plain forge EVM. Reproduces the semantics the wrapper depends on: one head
///         per (caller, key), the no-op rule, and the self-verifying `anchorAndHash`.
contract MockAnchoring is IAnchoring {
    mapping(address => mapping(bytes32 => bytes32)) private heads;

    function anchor(bytes32 key, bytes32 commitment, bytes calldata metadata) public {
        if (heads[msg.sender][key] == commitment) revert CommitmentUnchanged();
        heads[msg.sender][key] = commitment;
        emit Anchored(msg.sender, key, commitment, metadata);
    }

    function anchorAndHash(bytes32 key, bytes calldata metadata) external {
        anchor(key, keccak256(metadata), metadata);
    }

    function latest(address namespace, bytes32 key) external view returns (bytes32) {
        return heads[namespace][key];
    }
}
