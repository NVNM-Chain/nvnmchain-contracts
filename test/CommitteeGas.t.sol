// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NVNMStakingTestBase} from "./NVNMStaking.t.sol";

/// The node runs `computeCommittee` as a system call under a fixed 250M gas limit and falls
/// back if it runs out. A full list in ascending weight, every candidate eligible, is the worst
/// case for the eligibility scan and the insertion sort: 33M when written.
contract CommitteeGasTest is NVNMStakingTestBase {
    uint256 constant MAX_CANDIDATES = 256;
    uint256 constant BUDGET = 50_000_000; // a fifth of the node's limit

    function test_election_worstCaseFitsSystemCall() public {
        nvnm.mint(address(this), 1e30);
        nvnm.approve(address(staking), type(uint256).max);
        for (uint256 i; i < MAX_CANDIDATES; ++i) {
            address c = address(uint160(0x1000 + i));
            vm.prank(owner);
            staking.setCandidate(c, true);
            staking.stake(c, (i + 1) * 1 ether);
        }
        vm.startPrank(owner);
        staking.setUnbondingPeriod(1 days);
        staking.setCommitteeConfig(MAX_CANDIDATES, 1, 0);
        vm.stopPrank();

        uint256 before = gasleft();
        address[] memory vals = _committee();
        uint256 used = before - gasleft();

        assertEq(vals.length, MAX_CANDIDATES);
        assertLt(used, BUDGET, "computeCommittee outgrew the node's system-call budget");
    }
}
