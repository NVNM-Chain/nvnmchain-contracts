// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice The L1 bridge gateway, as NVNMStaking uses it: it burns the bond NVNMStaking approves
///         it for and tells Ethereum to return or seize that much of the validator's bond there,
///         charging `feePayer` the message's fee in the endpoint's token.
interface IBondGateway {
    function returnBond(address validator, uint256 amount, address feePayer) external;
    function seize(address validator, uint256 amount, address feePayer) external;
}
