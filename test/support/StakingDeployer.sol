// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { NVNMStaking } from "../../src/NVNMStaking.sol";
import { MockERC20 } from "./MockERC20.sol";
import { LibClone } from "solady/utils/LibClone.sol";

/// @notice One-shot deployer for local/e2e: a single create tx deploys a mock NVNM stake token
///         and an NVNMStaking proxy (owner = caller), minting the caller a stake balance.
///         `rewardToken_` selects the reward leg: zero deploys a mock (also minted to the caller),
///         a real address (e.g. the fee stablecoin) is used as-is. Read addresses from
///         `staking()` / `nvnm()` / `usd()`.
contract StakingDeployer {
    NVNMStaking public immutable staking;
    MockERC20 public immutable nvnm; // stake token
    address public immutable usd; // reward token

    constructor(address rewardToken_) {
        address caller = msg.sender;
        MockERC20 n = new MockERC20("NVNM", "NVNM");
        n.mint(caller, 1000 ether);

        address r = rewardToken_;
        if (r == address(0)) {
            MockERC20 u = new MockERC20("nvmnUSD", "nvmnUSD");
            u.mint(caller, 1000 ether);
            r = address(u);
        }

        NVNMStaking s = NVNMStaking(LibClone.deployERC1967(address(new NVNMStaking())));
        s.initialize(caller, address(n), r);

        staking = s;
        nvnm = n;
        usd = r;
    }
}
