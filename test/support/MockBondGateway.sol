// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NVNMStaking} from "../../src/NVNMStaking.sol";
import {IBondGateway} from "../../src/interfaces/IBondGateway.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev The L1 bridge gateway as NVNMStaking sees it: delivers bonds by minting them to staking,
///      and takes what staking approves on a return or a seizure, as its burn would.
contract MockBondGateway is IBondGateway {
    MockERC20 public immutable TOKEN;
    mapping(address => uint256) public returned;
    mapping(address => uint256) public seized;
    address public feePayer;

    constructor(MockERC20 token) {
        TOKEN = token;
    }

    function deliverBond(NVNMStaking staking, address validator, uint256 amount) external {
        TOKEN.mint(address(staking), amount);
        staking.bondFromBridge(validator, amount);
    }

    function returnBond(address validator, uint256 amount, address feePayer_) external {
        TOKEN.transferFrom(msg.sender, address(this), amount);
        returned[validator] += amount;
        feePayer = feePayer_;
    }

    function seize(address validator, uint256 amount, address feePayer_) external {
        TOKEN.transferFrom(msg.sender, address(this), amount);
        seized[validator] += amount;
        feePayer = feePayer_;
    }
}
