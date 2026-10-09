// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice The node's validator registry, as NVNMStaking uses it: once consensus votes carry
///         their signer's signature, it checks evidence that one key signed conflicting votes in
///         a round. It reverts unless the votes conflict, the key signed both on this chain, and
///         the registry held the key in that epoch.
interface IEquivocation {
    /// @notice The address the registry holds the key under, where its bond is; the round the
    ///         votes are for; and how many epochs before this block's that round was.
    function equivocator(bytes calldata evidence)
        external
        view
        returns (address validator, uint64 epoch, uint64 viewNumber, uint64 epochsAgo);
}
