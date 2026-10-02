// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice The node's validator registry precompile, as much of it as `FeeLockbox` reads.
interface IValidatorConfigV2 {
    struct Validator {
        bytes32 publicKey;
        address validatorAddress;
        string ingress;
        string egress;
        address feeRecipient;
        uint64 index;
        uint64 addedAtHeight;
        uint64 deactivatedAtHeight;
    }

    function getActiveValidators() external view returns (Validator[] memory validators);
}
