// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IValidatorConfigV2} from "../../src/interfaces/IValidatorConfigV2.sol";

/// @notice Stands in for the registry precompile: etched at its address, with a settable active set.
///         Entries are numbered as the registry numbers them: one that stays keeps its index, one
///         that returns after leaving is a new entry.
contract MockValidatorConfig {
    IValidatorConfigV2.Validator[] internal _active;
    mapping(address => uint64) public indexOf; // of the entry an address holds, while it is in the set
    mapping(address => bool) internal _seated;
    uint64 internal _next;

    function setActive(address[] calldata vals) external {
        for (uint256 i; i < _active.length; ++i) {
            address v = _active[i].validatorAddress;
            if (!_in(vals, v)) _seated[v] = false;
        }
        delete _active;
        for (uint256 i; i < vals.length; ++i) {
            address v = vals[i];
            if (!_seated[v]) (indexOf[v], _seated[v]) = (_next++, true);
            _active.push(
                IValidatorConfigV2.Validator({
                    publicKey: bytes32(uint256(indexOf[v]) + 1),
                    validatorAddress: v,
                    ingress: "",
                    egress: "",
                    feeRecipient: v,
                    index: indexOf[v],
                    addedAtHeight: 0,
                    deactivatedAtHeight: 0
                })
            );
        }
    }

    /// @notice Hand entry `pos` of the set to `to`, as `transferValidatorOwnership` does: the index stays.
    function transfer(uint256 pos, address to) external {
        IValidatorConfigV2.Validator storage v = _active[pos];
        (indexOf[to], _seated[to]) = (v.index, true);
        _seated[v.validatorAddress] = false;
        (v.validatorAddress, v.feeRecipient) = (to, to);
    }

    function getActiveValidators() external view returns (IValidatorConfigV2.Validator[] memory) {
        return _active;
    }

    function _in(address[] calldata vals, address v) private pure returns (bool) {
        for (uint256 i; i < vals.length; ++i) {
            if (vals[i] == v) return true;
        }
        return false;
    }
}
