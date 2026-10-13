// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice The node's validator registry, as NVNMStaking uses it: once consensus votes carry
///         their signer's signature, it checks evidence that one key signed conflicting votes in
///         a round. It reverts unless the votes conflict, the key signed both on this chain, and
///         the registry held the key in that epoch, or had retired it a few epochs before at most.
interface IEquivocation {
    /// @notice The address the registry holds the key under, where its bond is, and the round
    ///         the votes are for.
    function equivocator(bytes calldata evidence)
        external
        view
        returns (address validator, uint64 epoch, uint64 viewNumber);
}
