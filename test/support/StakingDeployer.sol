// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NVNMStaking} from "../../src/NVNMStaking.sol";
import {LibClone} from "solady/utils/LibClone.sol";

/// @notice One create deploys an NVNMStaking proxy owned by `owner`, over the tokens given. The
///         owner is named, not the caller, which under a CREATE3 factory is a throwaway proxy.
///         Its own CREATEs run impl, then proxy, for callers that predict the proxy's address.
contract StakingDeployer {
    NVNMStaking public immutable staking;

    constructor(address owner, address stakeToken, address rewardToken) {
        NVNMStaking s = NVNMStaking(LibClone.deployERC1967(address(new NVNMStaking())));
        s.initialize(owner, stakeToken, rewardToken);
        staking = s;
    }
}
