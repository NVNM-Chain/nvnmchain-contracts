// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NVNMStaking} from "../../src/NVNMStaking.sol";
import {LibClone} from "solady/utils/LibClone.sol";

/// @notice One create tx deploys an NVNMStaking proxy owned by the caller, over the tokens given.
///         Its own CREATEs run impl, then proxy, for callers that predict the proxy's address.
contract StakingDeployer {
    NVNMStaking public immutable staking;

    constructor(address stakeToken, address rewardToken) {
        NVNMStaking s = NVNMStaking(LibClone.deployERC1967(address(new NVNMStaking())));
        s.initialize(msg.sender, stakeToken, rewardToken);
        staking = s;
    }
}
