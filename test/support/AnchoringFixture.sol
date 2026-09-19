// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Anchoring} from "../../src/Anchoring.sol";
import {IAnchoring} from "../../src/IAnchoring.sol";

/// A fresh contract at a fixed block time, with the accounts and inputs the suites share.
/// The shipped build names no module admin, so a chain that wants one installs a build like this.
contract AnchoringWithAdmin is Anchoring {
    address private immutable ADMIN;

    constructor(address admin) {
        ADMIN = admin;
    }

    function _admin() internal view override returns (address) {
        return ADMIN;
    }
}

abstract contract AnchoringFixture is Test {
    Anchoring internal anchoring;

    address internal moduleAdmin = address(0xA0);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);

    uint256 internal constant AT = 1757376000; // 2025-09-09 00:00:00 +0000 UTC
    string internal constant URI = "https://www.courtlistener.com/opinion/8857414/richmond-v-atwood/"; // > 32 bytes

    function setUp() public virtual {
        anchoring = new AnchoringWithAdmin(moduleAdmin);
        vm.warp(AT);
    }

    /// Sender and origin both, as the EOA gate requires.
    function _as(address who) internal {
        vm.prank(who, who);
    }

    /// A record to submit. The chain sets the timestamp, ids and `isLatest`, so these are ignored.
    function _record(uint64 registryId, string memory checksum) internal pure returns (IAnchoring.Record memory) {
        return IAnchoring.Record({
            uri: URI,
            checksum: checksum,
            checksumAlgo: "cite-canonical-v1",
            metadata: '{"cluster":8857414}',
            timestamp: "whenever",
            status: "Active",
            recordId: 999,
            index: 999,
            isLatest: false,
            registryId: registryId
        });
    }

    function _page(uint64 offset, uint64 limit) internal pure returns (IAnchoring.PageRequest memory) {
        return IAnchoring.PageRequest({key: "", offset: offset, limit: limit, countTotal: false, reverse: false});
    }
}
