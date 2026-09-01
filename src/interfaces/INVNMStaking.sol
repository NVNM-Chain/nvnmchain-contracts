// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice The surface of `NVNMStaking` the fee-routing layer consumes.
interface INVNMStaking {
    function depositReward(address validator, uint256 amount) external;
    function rewardToken() external view returns (address);
    function stakeToken() external view returns (address);
    function totalShares(address validator) external view returns (uint256);
}
