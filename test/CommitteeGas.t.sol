// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NVNMStakingTestBase} from "./NVNMStaking.t.sol";

/// The node runs `computeCommittee` as a system call under a fixed 250M gas limit and falls
/// back if it runs out. A registry in ascending weight is the worst case for the top-seats
/// selection, every entry displacing the lightest kept: about 2M for 256 entries.
contract CommitteeGasTest is NVNMStakingTestBase {
    uint256 constant REGISTRY = 256;
    uint256 constant MAX_SEATS = 21;
    uint256 constant BUDGET = 10_000_000; // a twenty-fifth of the node's limit

    function test_election_worstCaseFitsSystemCall() public {
        nvnm.mint(address(this), 1e30);
        nvnm.approve(address(staking), type(uint256).max);
        address[] memory eligible = new address[](REGISTRY);
        for (uint256 i; i < REGISTRY; ++i) {
            eligible[i] = address(uint160(0x1000 + i));
            staking.stake(eligible[i], (i + 1) * 1 ether);
        }
        vm.startPrank(owner);
        staking.setUnbondingPeriod(1 days);
        staking.setCommitteeConfig(MAX_SEATS, 1, 0);
        vm.stopPrank();

        uint256 before = gasleft();
        address[] memory vals = staking.computeCommittee(eligible);
        uint256 used = before - gasleft();

        assertEq(vals.length, MAX_SEATS);
        assertEq(vals[0], eligible[REGISTRY - 1], "heaviest first");
        assertLt(used, BUDGET, "computeCommittee outgrew the node's system-call budget");
    }
}
