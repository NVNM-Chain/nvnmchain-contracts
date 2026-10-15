// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

import {CallContextChecker} from "solady/utils/CallContextChecker.sol";
import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {Anchoring} from "../src/Anchoring.sol";
import {AnchoringFixture} from "./support/AnchoringFixture.sol";

/// The owner swaps the code behind the proxy; the corpus is the proxy's storage and stays.
contract UpgradeTest is AnchoringFixture {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function test_the_owner_upgrades_and_the_corpus_stays() public {
        _as(alice);
        anchoring.addRegistry("us-ca1", "First Circuit", "{}");
        Anchoring next = new Anchoring();

        vm.expectEmit(address(anchoring));
        emit UUPSUpgradeable.Upgraded(address(next));
        _as(owner);
        anchoring.upgradeToAndCall(address(next), "");

        assertEq(_implementation(), address(next));
        assertEq(anchoring.owner(), owner);
        _as(bob);
        assertEq(anchoring.addRegistry("us-ca9", "Ninth Circuit", "{}"), 2, "the count came through");
    }

    function test_no_one_else_upgrades() public {
        address next = address(new Anchoring());
        _as(alice);
        vm.expectRevert("sender not the owner");
        anchoring.upgradeToAndCall(next, "");
    }

    /// A proxy without an owner, as T12 leaves one whose validator registry had none, takes no new
    /// code.
    function test_without_an_owner_no_one_upgrades() public {
        Anchoring unowned = _deploy();
        address next = address(new Anchoring());
        _as(owner);
        vm.expectRevert("sender not the owner");
        unowned.upgradeToAndCall(next, "");
    }

    /// Code that cannot take the next upgrade would strand the proxy.
    function test_an_upgrade_needs_a_uups_implementation() public {
        _as(owner);
        vm.expectRevert(UUPSUpgradeable.UpgradeFailed.selector);
        anchoring.upgradeToAndCall(address(0xDEAD), "");
    }

    /// At its own address the implementation has no owner and no corpus, so it answers nothing:
    /// a reader on the wrong address gets a revert, not an empty registry.
    function test_the_implementation_answers_nothing_at_its_own_address() public {
        Anchoring impl = Anchoring(_implementation());
        assertEq(impl.proxiableUUID(), IMPLEMENTATION_SLOT, "the one call an upgrade needs");

        bytes[14] memory calls = [
            abi.encodeCall(impl.addRegistry, ("us-ca1", "First Circuit", "{}")),
            abi.encodeCall(impl.addRecord, (_record(1, "sha256:0"))),
            abi.encodeCall(impl.updateRecordStatus, (1, 1, 1, "revoked")),
            abi.encodeCall(impl.grantRole, (1, "", alice, "admin")),
            abi.encodeCall(impl.revokeRole, (1, "", alice, "admin")),
            abi.encodeCall(impl.transferOwnership, (alice)),
            abi.encodeCall(impl.upgradeToAndCall, (address(impl), "")),
            abi.encodeCall(impl.owner, ()),
            abi.encodeCall(impl.hasRole, (bytes32(0), alice)),
            abi.encodeCall(impl.roleMemberCount, (bytes32(0))),
            abi.encodeCall(impl.getRoleAdmin, (bytes32(0))),
            abi.encodeCall(impl.records, (1, "", 0, 0, _page(0, 0))),
            abi.encodeCall(impl.registries, (1, _page(0, 0))),
            abi.encodeCall(impl.registriesByName, ("us-ca1", 1, _page(0, 0)))
        ];
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory reason) = address(impl).call(calls[i]);
            assertFalse(ok);
            assertEq(bytes4(reason), CallContextChecker.UnauthorizedCallContext.selector);
        }
    }

    function _implementation() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(anchoring), IMPLEMENTATION_SLOT))));
    }
}
