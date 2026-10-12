// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {VALIDATOR_REGISTRY} from "../src/Constants.sol";
import {NVNMStaking} from "../src/NVNMStaking.sol";
import {IEquivocation} from "../src/interfaces/IEquivocation.sol";
import {NVNMStakingTestBase} from "./NVNMStaking.t.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @dev Slashing on evidence of conflicting votes. The node's registry, a precompile, is mocked:
///      what it accepts as evidence is the node's to test.
contract NVNMStakingEquivocationTest is NVNMStakingTestBase {
    bytes32 constant KEY = keccak256("a consensus key");
    /// @dev Evidence opens with the key that signed. The rest stands in for its two votes.
    bytes EVIDENCE = bytes.concat(KEY, hex"e71de9ce");

    /// @dev A 100-ether bond under an election, with a tenth of it at stake for five epochs.
    function _open() internal {
        _openRegistration(100 ether);
        _bond(validator, 100 ether);
        _startElection();
        vm.prank(owner);
        staking.setEquivocation(1000, 5);
    }

    /// @dev The registry reads `evidence` as `who` signing twice in `epoch`'s view 3, `age` ago.
    function _registryReads(bytes memory evidence, address who, uint64 epoch, uint64 age) internal {
        vm.mockCall(
            VALIDATOR_REGISTRY,
            abi.encodeCall(IEquivocation.equivocator, (evidence)),
            abi.encode(who, epoch, uint64(3), age)
        );
    }

    function test_anyone_slashes_on_evidence_the_registry_accepts() public {
        _open();
        _registryReads(EVIDENCE, validator, 7, 0);

        vm.expectEmit();
        emit NVNMStaking.Equivocated(validator, 7, 3);
        vm.expectEmit();
        emit NVNMStaking.Slashed(validator, 1000, 10 ether);
        vm.prank(bob);
        assertEq(staking.slashEquivocation(EVIDENCE), 10 ether);

        assertEq(staking.bondOf(validator), 90 ether);
        assertEq(gateway.seized(validator), 10 ether, "and seized on Ethereum");
        assertEq(gateway.feePayer(), bob, "whoever brings it pays the bridge");
    }

    function test_an_epoch_is_paid_for_once() public {
        _open();
        _registryReads(EVIDENCE, validator, 7, 0);
        staking.slashEquivocation(EVIDENCE);

        // Evidence of another round of the epoch: a key that signs twice does so in many.
        bytes memory again = bytes.concat(KEY, hex"a9a1");
        bytes memory nextRound = abi.encode(validator, uint64(7), uint64(4), uint64(1));
        vm.mockCall(VALIDATOR_REGISTRY, abi.encodeCall(IEquivocation.equivocator, (again)), nextRound);
        vm.expectRevert(NVNMStaking.AlreadySlashed.selector);
        staking.slashEquivocation(again);
        assertEq(staking.bondOf(validator), 90 ether);

        // Another epoch is another offence, and another key's the same epoch is its own.
        bytes memory later = bytes.concat(KEY, hex"1a7e");
        _registryReads(later, validator, 8, 0);
        assertEq(staking.slashEquivocation(later), 9 ether);
        bytes memory other = bytes.concat(keccak256("another key"), hex"e71de9ce");
        _bond(validator2, 100 ether);
        _registryReads(other, validator2, 7, 0);
        assertEq(staking.slashEquivocation(other), 10 ether);
    }

    function test_an_epoch_is_paid_for_by_its_key_whatever_address_holds_it() public {
        _open();
        _registryReads(EVIDENCE, validator, 7, 0);
        staking.slashEquivocation(EVIDENCE);

        // The registry's owner moves the entry: the same evidence now names another address.
        _bond(validator2, 100 ether);
        _registryReads(EVIDENCE, validator2, 7, 0);
        vm.expectRevert(NVNMStaking.AlreadySlashed.selector);
        staking.slashEquivocation(EVIDENCE);
        assertEq(staking.bondOf(validator2), 100 ether);
    }

    function test_an_epoch_stays_open_until_there_is_a_bond_to_slash() public {
        _open();
        // In the registry and electable, but with no bond yet.
        _registryReads(EVIDENCE, validator2, 7, 0);
        vm.expectRevert(NVNMStaking.NothingToSlash.selector);
        staking.slashEquivocation(EVIDENCE);

        _bond(validator2, 100 ether);
        assertEq(staking.slashEquivocation(EVIDENCE), 10 ether);
    }

    function test_evidence_counts_for_evidenceEpochs() public {
        _open();
        _registryReads(EVIDENCE, validator, 7, 6);
        vm.expectRevert(NVNMStaking.EvidenceExpired.selector);
        staking.slashEquivocation(EVIDENCE);

        _registryReads(EVIDENCE, validator, 7, 5);
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
        staking.setEquivocation(1000, 5);
        vm.expectRevert(NVNMStaking.SlashingClosed.selector);
        staking.slashEquivocation(EVIDENCE);

        // The epoch is still unpaid when the election opens it.
        _startElection();
        vm.clearMockedCalls();
        _registryReads(EVIDENCE, validator, 7, 0);
        assertEq(staking.slashEquivocation(EVIDENCE), 10 ether);
    }

    function test_setEquivocation_ownerOnly_and_bounded() public {
        vm.prank(bob);
        vm.expectRevert(Ownable.Unauthorized.selector);
        staking.setEquivocation(1000, 5);

        vm.startPrank(owner);
        vm.expectRevert(NVNMStaking.InvalidBps.selector);
        staking.setEquivocation(10_001, 5);

        vm.expectEmit();
        emit NVNMStaking.EquivocationSet(10_000, 5);
        staking.setEquivocation(10_000, 5);
        assertEq(staking.equivocationBps(), 10_000);
        assertEq(staking.evidenceEpochs(), 5);

        // The event says what was stored.
        vm.expectEmit();
        emit NVNMStaking.EquivocationSet(10_000, type(uint64).max);
        staking.setEquivocation(10_000, type(uint256).max);
        assertEq(staking.evidenceEpochs(), type(uint64).max);
        vm.stopPrank();
    }
}
