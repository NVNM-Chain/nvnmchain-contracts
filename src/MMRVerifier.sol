// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { MMR } from "./MMR.sol";

/// @title MMRVerifier
/// @notice Inclusion proofs against any MMR root: deployed once, not per registry, since
///         verifying is pure and the root is the only input that differs. A registry's root is
///         its `mmrRoot()`.
contract MMRVerifier {
    function verify(
        bytes32 root,
        bytes32 commitment,
        uint256 index,
        bytes32[] calldata siblings,
        bytes32[] calldata peaks,
        uint256 count
    ) external pure returns (bool) {
        MMR.check(root, peaks, peaks.length, count);
        return MMR.verify(peaks, count, index, commitment, siblings);
    }
}
