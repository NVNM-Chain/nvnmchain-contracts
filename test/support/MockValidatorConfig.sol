// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IValidatorConfigV2} from "../../src/interfaces/IValidatorConfigV2.sol";

/// @notice Stands in for the registry precompile: etched at its address, with a settable active set.
contract MockValidatorConfig {
    IValidatorConfigV2.Validator[] internal _active;

    function setActive(address[] calldata vals) external {
        delete _active;
        for (uint256 i; i < vals.length; ++i) {
            _active.push(
                IValidatorConfigV2.Validator({
                    publicKey: bytes32(i + 1),
                    validatorAddress: vals[i],
                    ingress: "",
                    egress: "",
                    feeRecipient: vals[i],
                    index: uint64(i),
                    addedAtHeight: 0,
                    deactivatedAtHeight: 0
                })
            );
        }
    }

    function getActiveValidators() external view returns (IValidatorConfigV2.Validator[] memory) {
        return _active;
    }
}
