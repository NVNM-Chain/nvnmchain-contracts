// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NVNMStaking} from "../src/NVNMStaking.sol";
import {NVNMStakingTestBase} from "./NVNMStaking.t.sol";

/// @dev A slash the lockbox's own slasher made on Ethereum, as the gateway brings it here.
contract NVNMStakingSlashFromBridgeTest is NVNMStakingTestBase {
    function test_a_slash_on_ethereum_drops_the_bond_and_its_weight() public {
        _openRegistration(50 ether);
        _bond(validator, 100 ether);
        _startElection();
        address[] memory who = new address[](1);
        who[0] = validator;
        uint256 weight = staking.electionWeight(who)[0];

        vm.expectEmit();
        emit NVNMStaking.Slashed(validator, 2500, 25 ether);
        assertEq(gateway.deliverSlash(staking, validator, 25 ether), 25 ether);

        assertEq(staking.bondOf(validator), 75 ether);
        assertEq(gateway.burned(validator), 25 ether, "the gateway burns what staking let go");
        assertEq(nvnm.balanceOf(address(staking)), 75 ether);
        assertEq(staking.electionWeight(who)[0], weight * 3 / 4);
    }

    function test_it_clamps_to_the_bond_and_never_reverts() public {
        _openRegistration(100 ether);
        _bond(validator, 100 ether);

        // Before the election too: Ethereum has seized, whatever this side has configured.
        assertEq(gateway.deliverSlash(staking, validator, 250 ether), 100 ether, "only what is left");
        assertEq(gateway.deliverSlash(staking, validator, 1 ether), 0, "nothing left, and no revert");
        assertEq(staking.bondOf(validator), 0);
        assertEq(nvnm.balanceOf(address(staking)), 0);
    }

    function test_it_reaches_an_unbonding_bond() public {
        _openRegistration(100 ether);
        _bond(validator, 100 ether);
        vm.prank(validator);
        staking.resignCandidate();

        gateway.deliverSlash(staking, validator, 40 ether);

        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(validator);
        assertEq(staking.withdrawBond(), 60 ether);
        assertEq(gateway.returned(validator), 60 ether, "what is left goes home");
    }

    function test_only_the_gateway_brings_it() public {
        _openRegistration(100 ether);
        _bond(validator, 100 ether);

        vm.prank(bob);
        vm.expectRevert(NVNMStaking.NotBondGateway.selector);
        staking.slashFromBridge(validator, 100 ether);
    }
}
