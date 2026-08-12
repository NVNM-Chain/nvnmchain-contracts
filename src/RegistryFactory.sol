// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Ownable } from "solady/auth/Ownable.sol";

import { Registry } from "./Registry.sol";

/// @title RegistryFactory
/// @notice Deploys one {Registry} per registry and is the record of which ones exist.
/// @dev Registries are plain deployments, not proxies, and neither is this. Upgrading means
///      deploying a new registry and re-granting its roles: what a registry anchors is a
///      commitment, provable under the address that wrote it forever, so a replacement splits
///      the history across two addresses rather than invalidating any of it.
///
///      `owner` (a Safe) is the break-glass admin every registry reads back through {owner}.
///      Transferring it reaches every registry at once, because they read it live from here.
///
///      Registry metadata is *not* anchored. Name, description and metadata are descriptive
///      rather than a commitment, and they are set once at deployment, so `RegistryDeployed`
///      is the whole record — an indexer reads it straight from the log with no envelope to
///      decode. What gets anchored is what needs proving: the records themselves.
///
///      Nor is the set of registries kept on-chain. An array would be a second copy of what
///      the log already carries, and deployment order is canonical log order — the same
///      argument the precompile makes for not storing a version field. Enumeration is the
///      indexer's job. A contract caller keeps the address `deployRegistry` returns;
///      an EOA gets no return value and reads it from `RegistryDeployed`, like any
///      other consumer of the log.
contract RegistryFactory is Ownable {
    event RegistryDeployed(
        address indexed registry,
        address indexed creator,
        string name,
        string description,
        string metadata
    );
    error EmptyName();

    /// @param owner_ the break-glass admin every registry reads back through {owner}.
    constructor(address owner_) {
        _initializeOwner(owner_);
    }

    /// @notice Deploys a registry and makes the caller its admin. Permissionless, and `name`
    ///         is deliberately not unique — the address is the canonical reference.
    function deployRegistry(
        string calldata name,
        string calldata description,
        string calldata metadata
    ) external returns (address registry) {
        if (bytes(name).length == 0) revert EmptyName();

        registry = address(new Registry(msg.sender, address(this)));
        emit RegistryDeployed(registry, msg.sender, name, description, metadata);
    }
}
