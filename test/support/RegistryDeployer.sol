// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { RegistryFactory } from "../../src/RegistryFactory.sol";

/// @notice One-shot deployer for local/e2e use: a single create tx deploys the factory with
///         the calling EOA as owner. Read it from `factory()`.
contract RegistryDeployer {
    RegistryFactory public immutable factory;

    constructor() {
        factory = new RegistryFactory(msg.sender);
    }
}
