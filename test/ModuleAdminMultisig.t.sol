// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Anchoring} from "../src/Anchoring.sol";
import {IAnchoring} from "../src/IAnchoring.sol";
import {ModuleAdminMultisig} from "../src/ModuleAdminMultisig.sol";
import {Roles} from "../src/Roles.sol";

/// Any contract that is not the module admin, to show the gate still stands for one.
contract StrangerContract {
    function grant(uint64 registryId, address account) external {
        IAnchoring(0x0000000000000000000000000000000000000A00).grantRole(registryId, "", account, Roles.ADMIN);
    }
}

/// Both contracts sit where genesis places them, `Anchoring` at `0x…0a00` and the multisig at the
/// old chain's admin address, with the owners written into its slots 0..2 as the alloc does.
contract ModuleAdminMultisigTest is Test {
    address internal constant MULTISIG = 0x0582bFB2e8561D48636E78f0e6b139d5a842be8f;
    address internal constant ANCHORING = 0x0000000000000000000000000000000000000A00;

    address internal constant OWNER_A = address(0xA);
    address internal constant OWNER_B = address(0xB);
    address internal constant OWNER_C = address(0xC);

    address internal constant OUTSIDER = address(0xBAD);
    address internal constant SEEDED_ADMIN = address(0xA11CE);

    address internal constant VALIDATOR_CONFIG = 0xCcCCCCcC00000000000000000000000000000001;
    address internal constant RECOVERY = address(0xADD);
    address internal constant OWNER_D = address(0xD);
    address internal constant OWNER_E = address(0xE);
    address internal constant OWNER_F = address(0xF);

    ModuleAdminMultisig internal multisig;
    Anchoring internal anchoring;

    uint64 internal registryId;

    function setUp() public {
        // `Anchoring`'s constructor names the multisig as the module admin, which on the chain
        // the migration writes into the slot instead.
        deployCodeTo("Anchoring.sol", abi.encode(MULTISIG), ANCHORING);
        deployCodeTo("ModuleAdminMultisig.sol", MULTISIG);
        anchoring = Anchoring(ANCHORING);
        multisig = ModuleAdminMultisig(MULTISIG);
        for (uint256 i = 0; i < 3; i++) {
            vm.store(MULTISIG, bytes32(i), bytes32(uint256(uint160([OWNER_A, OWNER_B, OWNER_C][i]))));
        }
        // Genesis names who may replace the owners outright; slot 7 is where it writes it.
        vm.store(MULTISIG, bytes32(uint256(7)), bytes32(uint256(uint160(RECOVERY))));

        // A registry whose creator is a stranger, so only the module admin can seed an admin.
        vm.prank(OUTSIDER, OUTSIDER);
        registryId = anchoring.addRegistry("reg", "desc", "{}");
    }

    function grantAdminCall() internal view returns (bytes memory) {
        return abi.encodeCall(IAnchoring.grantRole, (registryId, "", SEEDED_ADMIN, Roles.ADMIN));
    }

    function adminRole() internal view returns (bytes32) {
        return Roles.forRegistry(registryId, Roles.ADMIN);
    }

    /// The point of the contract: two owners seed a registry admin through the break-glass
    /// branch, which compares `msg.sender` against the module admin and lets it past the gate.
    function test_two_owners_seed_a_registry_admin() public {
        vm.prank(OWNER_A);
        uint256 id = multisig.propose(grantAdminCall());

        assertFalse(anchoring.hasRole(adminRole(), SEEDED_ADMIN), "granted before the second owner");

        vm.prank(OWNER_B);
        multisig.confirm(id);

        assertTrue(anchoring.hasRole(adminRole(), SEEDED_ADMIN), "the grant did not land");
        (, uint8 confirmations, bool executed) = multisig.proposal(id);
        assertEq(confirmations, 2);
        assertTrue(executed);
    }

    /// One owner is under the threshold, and a proposal alone changes nothing on `Anchoring`.
    function test_one_owner_cannot_seed_a_registry_admin() public {
        vm.prank(OWNER_A);
        uint256 id = multisig.propose(grantAdminCall());

        (, uint8 confirmations, bool executed) = multisig.proposal(id);
        assertEq(confirmations, 1);
        assertFalse(executed);
        assertFalse(anchoring.hasRole(adminRole(), SEEDED_ADMIN));
    }

    /// Any two of the three.
    function test_any_two_of_the_three_owners_suffice() public {
        vm.prank(OWNER_B);
        uint256 id = multisig.propose(grantAdminCall());
        vm.prank(OWNER_C);
        multisig.confirm(id);

        assertTrue(anchoring.hasRole(adminRole(), SEEDED_ADMIN));
    }

    /// Confirming twice is one owner, not two, or a single key would be a threshold of one.
    function test_an_owner_cannot_confirm_twice() public {
        vm.prank(OWNER_A);
        uint256 id = multisig.propose(grantAdminCall());

        vm.prank(OWNER_A);
        vm.expectRevert(abi.encodeWithSelector(ModuleAdminMultisig.AlreadyConfirmed.selector, id, OWNER_A));
        multisig.confirm(id);

        assertFalse(anchoring.hasRole(adminRole(), SEEDED_ADMIN));
    }

    function test_a_stranger_can_neither_propose_nor_confirm() public {
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(ModuleAdminMultisig.NotAnOwner.selector, OUTSIDER));
        multisig.propose(grantAdminCall());

        vm.prank(OWNER_A);
        uint256 id = multisig.propose(grantAdminCall());

        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(ModuleAdminMultisig.NotAnOwner.selector, OUTSIDER));
        multisig.confirm(id);
    }

    /// An owner slot the genesis left empty admits nobody, the zero address included.
    function test_an_unset_owner_slot_admits_nobody() public {
        vm.store(MULTISIG, bytes32(uint256(2)), bytes32(0));
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(ModuleAdminMultisig.NotAnOwner.selector, address(0)));
        multisig.propose(grantAdminCall());
    }

    /// A proposal runs once. Re-confirming an executed one is refused rather than repeating it.
    function test_a_proposal_runs_once() public {
        vm.prank(OWNER_A);
        uint256 id = multisig.propose(grantAdminCall());
        vm.prank(OWNER_B);
        multisig.confirm(id);

        vm.prank(OWNER_C);
        vm.expectRevert(abi.encodeWithSelector(ModuleAdminMultisig.AlreadyExecuted.selector, id));
        multisig.confirm(id);
    }

    function test_an_unknown_proposal_is_refused() public {
        vm.prank(OWNER_A);
        vm.expectRevert(abi.encodeWithSelector(ModuleAdminMultisig.NoSuchProposal.selector, uint256(7)));
        multisig.confirm(7);
    }

    /// The exemption from the gate buys the admin nothing else: a role that is not an admin
    /// role goes through `_grantRole`, which asks the multisig for a role it does not hold, and
    /// `Anchoring` reverting is not swallowed.
    function test_the_admin_gains_nothing_beyond_the_break_glass_grant() public {
        bytes memory data = abi.encodeCall(IAnchoring.grantRole, (registryId, "", SEEDED_ADMIN, Roles.EDITOR));
        vm.prank(OWNER_A);
        uint256 id = multisig.propose(data);

        vm.prank(OWNER_B);
        vm.expectRevert();
        multisig.confirm(id);
        assertFalse(anchoring.hasRole(Roles.forRegistry(registryId, Roles.EDITOR), SEEDED_ADMIN));
    }

    /// The gate is lifted for the module admin alone. Another contract, even one the registry's
    /// creator calls, is still refused as it was on the old chain.
    function test_the_gate_still_stands_for_any_other_contract() public {
        StrangerContract stranger = new StrangerContract();
        vm.prank(OUTSIDER, OUTSIDER);
        vm.expectRevert("sender not an eoa");
        stranger.grant(registryId, SEEDED_ADMIN);
    }

    /// What genesis wrote, so an alloc can be checked against it.
    function test_owners_are_read_from_the_slots_genesis_writes() public view {
        (address[3] memory owned, uint8 threshold) = multisig.owners();
        assertEq(owned[0], OWNER_A);
        assertEq(owned[1], OWNER_B);
        assertEq(owned[2], OWNER_C);
        assertEq(threshold, 2);
    }

    /// The way back when member keys are lost: the validator admin names new owners, the old
    /// ones are out, and the new pair can seed an admin as before.
    function test_the_validator_admin_recovers_the_owners() public {
        vm.prank(RECOVERY);
        multisig.recover([OWNER_D, OWNER_E, OWNER_F]);

        (address[3] memory owned,) = multisig.owners();
        assertEq(owned[0], OWNER_D);
        assertEq(owned[1], OWNER_E);
        assertEq(owned[2], OWNER_F);

        vm.prank(OWNER_A);
        vm.expectRevert(abi.encodeWithSelector(ModuleAdminMultisig.NotAnOwner.selector, OWNER_A));
        multisig.propose(grantAdminCall());

        vm.prank(OWNER_D);
        uint256 id = multisig.propose(grantAdminCall());
        vm.prank(OWNER_E);
        multisig.confirm(id);
        assertTrue(anchoring.hasRole(adminRole(), SEEDED_ADMIN));
    }

    /// Not an owner's power, and not a stranger's: only the address the validator config names.
    function test_only_the_validator_admin_recovers() public {
        vm.prank(OWNER_A);
        vm.expectRevert(abi.encodeWithSelector(ModuleAdminMultisig.NotRecoveryAuthority.selector, OWNER_A));
        multisig.recover([OWNER_D, OWNER_E, OWNER_F]);

        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(ModuleAdminMultisig.NotRecoveryAuthority.selector, OUTSIDER));
        multisig.recover([OWNER_D, OWNER_E, OWNER_F]);

        (address[3] memory owned,) = multisig.owners();
        assertEq(owned[0], OWNER_A);
    }

    /// A zero or repeated owner could leave the threshold unreachable, so neither is accepted.
    function test_recovery_refuses_a_zero_or_repeated_owner() public {
        vm.prank(RECOVERY);
        vm.expectRevert(abi.encodeWithSelector(ModuleAdminMultisig.BadOwner.selector, address(0)));
        multisig.recover([OWNER_D, address(0), OWNER_F]);

        vm.prank(RECOVERY);
        vm.expectRevert(abi.encodeWithSelector(ModuleAdminMultisig.BadOwner.selector, OWNER_D));
        multisig.recover([OWNER_D, OWNER_E, OWNER_D]);
    }

    /// The reason recovery exists is a leaked key, and a leaked key can leave confirmations
    /// behind. A proposal from before the change is dead, whoever confirms it next.
    function test_recovery_supersedes_the_proposals_before_it() public {
        vm.prank(OWNER_A);
        uint256 stale = multisig.propose(grantAdminCall());

        vm.prank(RECOVERY);
        multisig.recover([OWNER_D, OWNER_E, OWNER_F]);

        vm.prank(OWNER_D);
        vm.expectRevert(abi.encodeWithSelector(ModuleAdminMultisig.Superseded.selector, stale));
        multisig.confirm(stale);
        assertFalse(anchoring.hasRole(adminRole(), SEEDED_ADMIN));

        // A proposal the new owners raise themselves is unaffected.
        vm.prank(OWNER_D);
        uint256 fresh = multisig.propose(grantAdminCall());
        vm.prank(OWNER_E);
        multisig.confirm(fresh);
        assertTrue(anchoring.hasRole(adminRole(), SEEDED_ADMIN));
    }

    /// A chain that named no authority has no `recover` at all: rotation is the only way.
    function test_without_a_named_authority_nobody_recovers() public {
        vm.store(MULTISIG, bytes32(uint256(7)), bytes32(0));
        assertEq(multisig.recoveryAuthority(), address(0));

        vm.prank(RECOVERY);
        vm.expectRevert(abi.encodeWithSelector(ModuleAdminMultisig.NotRecoveryAuthority.selector, RECOVERY));
        multisig.recover([OWNER_D, OWNER_E, OWNER_F]);
    }

    /// What the old chain's `MsgUpdateParams` did: two of the three replace the three, by
    /// transaction, with no authority above them.
    function test_two_owners_rotate_the_owners() public {
        vm.prank(OWNER_A);
        uint256 id = multisig.proposeRotation([OWNER_A, OWNER_B, OWNER_D]);

        (address[3] memory before,) = multisig.owners();
        assertEq(before[2], OWNER_C, "one confirmation is not a rotation");

        vm.prank(OWNER_B);
        multisig.confirm(id);

        (address[3] memory owned,) = multisig.owners();
        assertEq(owned[2], OWNER_D);
        vm.prank(OWNER_C);
        vm.expectRevert(abi.encodeWithSelector(ModuleAdminMultisig.NotAnOwner.selector, OWNER_C));
        multisig.propose(grantAdminCall());
    }

    /// A rotation kills what came before it, the same way recovery does.
    function test_a_rotation_supersedes_the_proposals_before_it() public {
        vm.prank(OWNER_A);
        uint256 stale = multisig.propose(grantAdminCall());

        vm.prank(OWNER_A);
        uint256 id = multisig.proposeRotation([OWNER_A, OWNER_B, OWNER_D]);
        vm.prank(OWNER_B);
        multisig.confirm(id);

        vm.prank(OWNER_D);
        vm.expectRevert(abi.encodeWithSelector(ModuleAdminMultisig.Superseded.selector, stale));
        multisig.confirm(stale);
    }

    /// The rotation itself is checked when raised, not left to fail at the threshold.
    function test_a_rotation_to_a_repeated_owner_is_refused() public {
        vm.prank(OWNER_A);
        vm.expectRevert(abi.encodeWithSelector(ModuleAdminMultisig.BadOwner.selector, OWNER_A));
        multisig.proposeRotation([OWNER_A, OWNER_B, OWNER_A]);
    }
}
