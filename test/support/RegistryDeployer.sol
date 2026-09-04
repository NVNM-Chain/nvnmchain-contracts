// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { MMRVerifier } from "../../src/MMRVerifier.sol";
import { RegistryFactory } from "../../src/RegistryFactory.sol";

/// @notice One-shot deployer for local/e2e use: a single create tx deploys the factory with
///         the calling EOA as owner, and the chain-wide verifier beside it. Read them from
///         `factory()` and `verifier()`.
contract RegistryDeployer {
    RegistryFactory public immutable factory;
    MMRVerifier public immutable verifier;

    constructor() {
        factory = new RegistryFactory(msg.sender);
        verifier = new MMRVerifier();
    }
}
