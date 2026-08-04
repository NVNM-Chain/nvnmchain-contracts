// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { LibClone } from "solady/utils/LibClone.sol";

import { AnchoringRegistry } from "../../src/AnchoringRegistry.sol";

/// @notice One-shot deployer for local/e2e use: a single create tx deploys the impl + an
///         ERC-1967 proxy and initializes it with the calling EOA as owner. Read the proxy
///         from `registry()`. Production uses CreateX + a Safe instead.
contract AnchoringDeployer {
    AnchoringRegistry public immutable registry;

    constructor() {
        address impl = address(new AnchoringRegistry());
        AnchoringRegistry r = AnchoringRegistry(LibClone.deployERC1967(impl));
        r.initialize(msg.sender);
        registry = r;
    }
}
