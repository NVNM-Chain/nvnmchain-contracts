// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IAnchoring} from "../src/IAnchoring.sol";

/// The precompile's selectors and topics, copied from what go-abi generated into the chain's
/// `x/anchoring/precompile/anchoring.abi.go`, not hashed here from signatures this file spells.
contract SelectorsTest is Test {
    /// A selector hashes the whole signature, so this pins the structs too.
    function test_selectors_match_the_precompiles() public pure {
        assertEq(IAnchoring.addRegistry.selector, bytes4(0x318b38b1), "addRegistry");
        assertEq(IAnchoring.addRecord.selector, bytes4(0x64d25295), "addRecord");
        assertEq(IAnchoring.updateRecordStatus.selector, bytes4(0x97b40c25), "updateRecordStatus");
        assertEq(IAnchoring.records.selector, bytes4(0xc7be5e37), "records");
        assertEq(IAnchoring.registries.selector, bytes4(0x17bd3e65), "registries");
        assertEq(IAnchoring.registriesByName.selector, bytes4(0x5522e6c6), "registriesByName");
        assertEq(IAnchoring.grantRole.selector, bytes4(0xb8fdd1a7), "grantRole");
        assertEq(IAnchoring.revokeRole.selector, bytes4(0xacd58bc7), "revokeRole");
    }

    /// A wrong selector reverts; a wrong topic0 just stops log filters from matching.
    function test_event_topics_match_the_precompiles() public pure {
        assertEq(
            IAnchoring.AddRegistry.selector,
            bytes32(0x181791bc379acedd3615cf065d3c275dfa6a3c4614c9065d54c98773f576108d),
            "AddRegistry"
        );
        assertEq(
            IAnchoring.AddRecord.selector,
            bytes32(0x1a3295fa8cc0e28c95d21912c9e6958f3bc740231781f7640ad885c972a352fd),
            "AddRecord"
        );
        assertEq(
            IAnchoring.UpdateRecordStatus.selector,
            bytes32(0xd7b75457d41293eab4829975c951ce8c53106866f0c429d175fc6c91cdad5ade),
            "UpdateRecordStatus"
        );
        assertEq(
            IAnchoring.GrantRole.selector,
            bytes32(0x0f49e365baf90deb7d1f63e576637907e12d1ddc75d1ac68894a2bcd192b6ddb),
            "GrantRole"
        );
        assertEq(
            IAnchoring.RevokeRole.selector,
            bytes32(0x8236b76cce80eaf69b54d89268d00fda3dec9e5e054f1548ebbb1f8b20b3b08b),
            "RevokeRole"
        );
    }
}
