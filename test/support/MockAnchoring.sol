// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { MMR } from "../../src/MMR.sol";
import { IAnchoring } from "../../src/interfaces/IAnchoring.sol";

/// @notice Test stand-in for the anchoring precompile, etched at its address so wrapper tests
///         run in a plain forge EVM. Reproduces the semantics the wrapper depends on: one MMR
///         per caller, its count and peaks kept, chunks aligned to the count, and the peaks
///         emitted, nothing returned.
contract MockAnchoring is IAnchoring {
    mapping(address => uint256) private counts;
    /// @dev height => peak. A merged-away peak is left in place, as the precompile leaves it;
    ///      the count's bits say which are live.
    mapping(address => mapping(uint256 => bytes32)) private peakAt;

    /// @dev Test-only: the last leaf a caller appended, so a test reads an envelope without
    ///      decoding logs. The real precompile stores no payload.
    mapping(address => bytes32) private lastCommitment;
    mapping(address => bytes) private lastMetadata;

    function root(address namespace) external view returns (bytes32) {
        bytes32[] memory peaks = _open(namespace, counts[namespace], 0);
        return MMR.bag(peaks, peaks.length);
    }

    function state(address namespace)
        external
        view
        returns (uint256 count, bytes32[] memory peaks)
    {
        count = counts[namespace];
        peaks = _open(namespace, count, 0);
    }

    function appendLeaf(bytes32 commitment, bytes calldata metadata) external {
        uint256 first = counts[msg.sender];
        bytes32[] memory live = _open(msg.sender, first, 1);
        (, uint256 total) = MMR.push(live, live.length - 1, first, 0, MMR.hashLeaf(commitment));
        bytes32[] memory peaks = _close(msg.sender, live, total);
        lastCommitment[msg.sender] = commitment;
        lastMetadata[msg.sender] = metadata;
        emit LeafAppended(msg.sender, first, commitment, peaks, metadata);
    }

    function appendLeaves(Chunk[] calldata chunks, bytes calldata metadata) external {
        if (chunks.length == 0) return; // a no-op, as the precompile has it
        // Every root before any height, as the precompile checks them.
        for (uint256 i = 0; i < chunks.length; i++) {
            if (chunks[i].root == bytes32(0)) revert ZeroChunkRoot();
        }
        uint256 first = counts[msg.sender];
        bytes32[] memory live = _open(msg.sender, first, chunks.length);
        (uint256 len, uint256 total) = (live.length - chunks.length, first);
        for (uint256 i = 0; i < chunks.length; i++) {
            (len, total) = MMR.push(live, len, total, chunks[i].height, chunks[i].root);
        }
        bytes32[] memory peaks = _close(msg.sender, live, total);
        lastMetadata[msg.sender] = metadata;
        emit LeavesAppended(msg.sender, first, total, chunks, peaks, metadata);
    }

    /// @notice What the last `appendLeaf` from `namespace` carried. Test-only; see above.
    function lastLeaf(address namespace)
        external
        view
        returns (bytes32 commitment, bytes memory metadata)
    {
        return (lastCommitment[namespace], lastMetadata[namespace]);
    }

    /// @dev The live peaks, highest first — one per set bit of `count` — with `room` spare
    ///      slots after them for what an append is about to merge in.
    function _open(address namespace, uint256 count, uint256 room)
        private
        view
        returns (bytes32[] memory live)
    {
        live = new bytes32[](MMR.popcount(count) + room);
        uint256 at;
        for (uint256 h = 256; h > 0;) {
            h--;
            if ((count >> h) & 1 == 1) live[at++] = peakAt[namespace][h];
        }
    }

    /// @dev Stores the count, and the peaks `live` now holds at the heights `total` names.
    ///      A height `total` no longer names keeps whatever it held: the precompile leaves a
    ///      merged-away peak in place too, so a height's slot is only ever created once.
    function _close(address namespace, bytes32[] memory live, uint256 total)
        private
        returns (bytes32[] memory peaks)
    {
        counts[namespace] = total;
        peaks = new bytes32[](MMR.popcount(total));
        uint256 at;
        for (uint256 h = 256; h > 0;) {
            h--;
            if ((total >> h) & 1 == 1) {
                peaks[at] = live[at];
                peakAt[namespace][h] = live[at];
                at++;
            }
        }
    }
}
