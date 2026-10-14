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

    /// An owner handed to zero can never be named again, so neither can new code.
    function test_without_an_owner_no_one_upgrades() public {
        _as(owner);
        anchoring.transferOwnership(address(0));
        address next = address(new Anchoring());
        _as(owner);
        vm.expectRevert("sender not the owner");
        anchoring.upgradeToAndCall(next, "");
    }

    /// Code that cannot take the next upgrade would strand the proxy.
    function test_an_upgrade_needs_a_uups_implementation() public {
        _as(owner);
        vm.expectRevert(UUPSUpgradeable.UpgradeFailed.selector);
        anchoring.upgradeToAndCall(address(0xDEAD), "");
    }

    /// At its own address the implementation has no owner and no corpus, so it takes no writes.
    function test_the_implementation_takes_no_writes() public {
        Anchoring impl = Anchoring(_implementation());
        assertEq(impl.proxiableUUID(), IMPLEMENTATION_SLOT);

        bytes[7] memory writes = [
            abi.encodeCall(impl.addRegistry, ("us-ca1", "First Circuit", "{}")),
            abi.encodeCall(impl.addRecord, (_record(1, "sha256:0"))),
            abi.encodeCall(impl.updateRecordStatus, (1, 1, 1, "revoked")),
            abi.encodeCall(impl.grantRole, (1, "", alice, "admin")),
            abi.encodeCall(impl.revokeRole, (1, "", alice, "admin")),
            abi.encodeCall(impl.transferOwnership, (alice)),
            abi.encodeCall(impl.upgradeToAndCall, (address(impl), ""))
        ];
        for (uint256 i = 0; i < writes.length; i++) {
            (bool ok, bytes memory reason) = address(impl).call(writes[i]);
            assertFalse(ok);
            assertEq(bytes4(reason), CallContextChecker.UnauthorizedCallContext.selector);
        }
    }

    function _implementation() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(anchoring), IMPLEMENTATION_SLOT))));
    }
}
