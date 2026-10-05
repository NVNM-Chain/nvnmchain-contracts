// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice Tempo's FeeManager precompile, as much of it as `FeeRouter` uses.
interface IFeeManager {
    /// @notice The token fees are paid to the caller in. Refused in a block the caller is the
    ///         beneficiary of.
    function setValidatorToken(address token) external;
}
