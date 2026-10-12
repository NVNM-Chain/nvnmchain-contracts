// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {VALIDATOR_REGISTRY} from "../src/Constants.sol";
import {NVNMStaking} from "../src/NVNMStaking.sol";
import {IEquivocation} from "../src/interfaces/IEquivocation.sol";
import {NVNMStakingTestBase} from "./NVNMStaking.t.sol";
import {MockBondGateway} from "./support/MockBondGateway.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @dev Slashing on evidence of conflicting votes. The node's registry, a precompile, is mocked:
///      what it accepts as evidence is the node's to test.
contract NVNMStakingEquivocationTest is NVNMStakingTestBase {
    bytes32 constant KEY = keccak256("a consensus key");
    /// @dev Evidence opens with the key that signed. The rest stands in for its two votes.
    bytes EVIDENCE = bytes.concat(KEY, hex"e71de9ce");

    /// @dev A 100-ether bond under an election, with a tenth of it at stake.
    function _open() internal {
        _openRegistration(100 ether);
        _bond(validator, 100 ether);
        _startElection();
        vm.prank(owner);
        staking.setEquivocation(1000);
    }

    function test_anyone_slashes_on_evidence_the_registry_accepts() public {
        _open();
        _registryReads(EVIDENCE, validator, 7);

        vm.expectEmit();
        emit NVNMStaking.Equivocated(validator, 7, 3);
        vm.expectEmit();
        emit NVNMStaking.Slashed(validator, 1000, 10 ether);
        vm.prank(bob);
        assertEq(staking.slashEquivocation(EVIDENCE), 10 ether);

        assertEq(staking.bondOf(validator), 90 ether);
        assertEq(gateway.seized(validator), 0, "nothing asked of the bridge yet");
        assertEq(staking.seizedPendingOf(validator), 10 ether);
        assertEq(staking.sendSeized(validator), 10 ether);
        vm.expectRevert(NVNMStaking.NothingSeized.selector);
        staking.sendSeized(validator);
    }

    function test_a_slash_stands_whatever_the_bridge_does() public {
        _open();
        _registryReads(EVIDENCE, validator, 7);
        gateway.refuse(true);
        assertEq(staking.slashEquivocation(EVIDENCE), 10 ether, "the slash needs no bridge");
        assertEq(staking.bondOf(validator), 90 ether);

        vm.expectRevert(MockBondGateway.Refused.selector);
        staking.sendSeized(validator);
        gateway.refuse(false);
        vm.prank(bob);
        assertEq(staking.sendSeized(validator), 10 ether);
        assertEq(gateway.seized(validator), 10 ether, "seized on Ethereum once the bridge is back");
        assertEq(gateway.feePayer(), bob, "whoever sends it pays the bridge");
        assertEq(nvnm.balanceOf(address(staking)), 90 ether, "the seized tokens left with it");
    }

    function test_an_epoch_is_paid_for_once() public {
        _open();
        _registryReads(EVIDENCE, validator, 7);
        staking.slashEquivocation(EVIDENCE);

        // Evidence of another round of the epoch: a key that signs twice does so in many.
        bytes memory again = bytes.concat(KEY, hex"a9a1");
        bytes memory nextRound = abi.encode(validator, uint64(7), uint64(4));
        vm.mockCall(VALIDATOR_REGISTRY, abi.encodeCall(IEquivocation.equivocator, (again)), nextRound);
        vm.expectRevert(NVNMStaking.AlreadySlashed.selector);
        staking.slashEquivocation(again);
        assertEq(staking.bondOf(validator), 90 ether);

        // Another epoch is another offence, and another key's the same epoch is its own.
        bytes memory later = bytes.concat(KEY, hex"1a7e");
        _registryReads(later, validator, 8);
        assertEq(staking.slashEquivocation(later), 9 ether);
        bytes memory other = bytes.concat(keccak256("another key"), hex"e71de9ce");
        _bond(validator2, 100 ether);
        _registryReads(other, validator2, 7);
        assertEq(staking.slashEquivocation(other), 10 ether);
    }

    function test_an_epoch_is_paid_for_by_its_key_whatever_address_holds_it() public {
        _open();
        _registryReads(EVIDENCE, validator, 7);
        staking.slashEquivocation(EVIDENCE);

        // The registry's owner moves the entry: the same evidence now names another address.
        _bond(validator2, 100 ether);
        _registryReads(EVIDENCE, validator2, 7);
        vm.expectRevert(NVNMStaking.AlreadySlashed.selector);
        staking.slashEquivocation(EVIDENCE);
        assertEq(staking.bondOf(validator2), 100 ether);
    }

    function test_an_epoch_stays_open_until_there_is_a_bond_to_slash() public {
        _open();
        // In the registry and electable, but with no bond yet.
        _registryReads(EVIDENCE, validator2, 7);
        vm.expectRevert(NVNMStaking.NothingToSlash.selector);
        staking.slashEquivocation(EVIDENCE);

        _bond(validator2, 100 ether);
        assertEq(staking.slashEquivocation(EVIDENCE), 10 ether);
    }

    function test_what_the_registry_rejects_slashes_nobody() public {
        _open();
        bytes memory rejected = abi.encodeWithSignature("InvalidSignature()");
        vm.mockCallRevert(VALIDATOR_REGISTRY, abi.encodeCall(IEquivocation.equivocator, (EVIDENCE)), rejected);
        vm.expectRevert(rejected);
        staking.slashEquivocation(EVIDENCE);
        assertEq(staking.bondOf(validator), 100 ether);
    }

    function test_closed_until_set_and_before_the_election() public {
        _openRegistration(100 ether);
        _bond(validator, 100 ether);
        // Closed, the registry is not even asked: its answer here would be the revert.
        vm.mockCallRevert(VALIDATOR_REGISTRY, abi.encodeCall(IEquivocation.equivocator, (EVIDENCE)), "asked");

        // Unset, nothing is at stake.
        vm.expectRevert(NVNMStaking.SlashingClosed.selector);
        staking.slashEquivocation(EVIDENCE);

        // Set, the PoA phases still have no validator-level slashing.
        vm.prank(owner);
        staking.setEquivocation(1000);
        vm.expectRevert(NVNMStaking.SlashingClosed.selector);
        staking.slashEquivocation(EVIDENCE);

        // The epoch is still unpaid when the election opens it.
        _startElection();
        vm.clearMockedCalls();
        _registryReads(EVIDENCE, validator, 7);
        assertEq(staking.slashEquivocation(EVIDENCE), 10 ether);
    }

    function test_setEquivocation_ownerOnly_and_bounded() public {
        vm.prank(bob);
        vm.expectRevert(Ownable.Unauthorized.selector);
        staking.setEquivocation(1000);

        vm.startPrank(owner);
        vm.expectRevert(NVNMStaking.InvalidBps.selector);
        staking.setEquivocation(10_001);

        vm.expectEmit();
        emit NVNMStaking.EquivocationSet(10_000);
        staking.setEquivocation(10_000);
        assertEq(staking.equivocationBps(), 10_000);
        vm.stopPrank();
    }
}
