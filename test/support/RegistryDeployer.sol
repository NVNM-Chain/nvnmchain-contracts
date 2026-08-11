// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { LibClone } from "solady/utils/LibClone.sol";

import { Registry } from "../../src/Registry.sol";
import { RegistryFactory } from "../../src/RegistryFactory.sol";

/// @notice One-shot deployer for local/e2e use: a single create tx deploys the registry
///         implementation, the factory implementation + an ERC-1967 proxy over it, and
///         initializes the factory with the calling EOA as owner. Read the factory from
///         `factory()`. Production uses CreateX + a Safe instead.
contract RegistryDeployer {
    RegistryFactory public immutable factory;

    constructor() {
        address registryImpl = address(new Registry());
        address factoryImpl = address(new RegistryFactory());
        RegistryFactory f = RegistryFactory(LibClone.deployERC1967(factoryImpl));
        f.initialize(msg.sender, registryImpl);
        factory = f;
    }
}
