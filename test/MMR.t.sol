// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Test } from "forge-std/Test.sol";

import { MMR } from "../src/MMR.sol";
import { MMRVerifier } from "../src/MMRVerifier.sol";
import { Registry } from "../src/Registry.sol";
import { RegistryFactory } from "../src/RegistryFactory.sol";
import { ANCHORING_ADDRESS, IAnchoring } from "../src/interfaces/IAnchoring.sol";
import { MockAnchoring } from "./support/MockAnchoring.sol";
import { RegistryDeployer } from "./support/RegistryDeployer.sol";

/// Roots and a proof computed independently, in Python with keccak, over the commitments
/// `bytes32(1)`, `bytes32(2)`, … appended in that order. The precompile's own suite pins the
/// same sixteen; the stand-in here has to reproduce them, which is what stops the library from
/// only agreeing with itself. Against a real registry, deployed through the factory, so the
/// roles are the ones a migration meets and the appends go through its forwarding.
contract MMRTest is Test {
    Registry a;
    MMRVerifier verifier;
    IAnchoring anchoring = IAnchoring(ANCHORING_ADDRESS);
    address owner = makeAddr("safe");
    address creator = makeAddr("creator");
    address editor = makeAddr("editor");
    address stranger = makeAddr("stranger");

    bytes32[16] internal ROOTS = [
        bytes32(0x5786039c2502cb1b5ff9a9f0b0b6957bb8b3f6489d20080f677236b2dd590dcd),
        bytes32(0x9950fe45570c3e4c9c0241de506d53ba63bb5b4ceb7b3c0032148e32f1ab3d9d),
        bytes32(0x036e11a04c28d071bc9b3961be683ff7eac4aad9234b6a21904de44b952cb3c9),
        bytes32(0x9a444d98cfab773b89efcfe3749342cd1b072e8f2276f9f822fb1e19edabb77b),
        bytes32(0xbbd0ad9fcc22a20f7adc962f214aba7710aed4d06063e7d722d65d07920a269d),
        bytes32(0x950d9243a18618ebce2f7906ead2e5c9cfe719359d7b8635cf52ee4995c53631),
        bytes32(0x237757481f6015968d2dd6b7784aa544f822d29f6a520bfae222c79c16051c14),
        bytes32(0x2a43055cc8a7bb9202beebc4603c13e920c9c7f7e3bf26ca5178aad751d5b29e),
        bytes32(0x8948ab91036932c2798daf8808b183438f08a6acb56cae4fe3d0db2ff999fd11),
        bytes32(0x0dcc0e544f9c3d0d78a0b030257eb964bc1756e786ede2c565c24817885bee6c),
        bytes32(0xbbe8d27929385c3988405fe38bf7a82136581ef7ea7a2f71634d9785eddaf1d7),
        bytes32(0xd3ebf5629b714dde40059d9dd0bb940d3748ead5953aa63d5d7cc867354b28fa),
        bytes32(0xbc438a6c52d1d3f2abea81fdd299bdfb9c8961b03e2adbeeff075db74971b2ae),
        bytes32(0xd41583f4d63289dafc25e7b5beaefe0f1e453fe2b9f0ba50cdfa96e27689c9fe),
        bytes32(0x7d75dea0b9798ddaa25f8a0d0e6222784f6ad299617a9128e7d75af3bf5eb81e),
        bytes32(0xc60e652673b4bff570b066c5513bf939b9a69b21c5ad6802f3579166b660c2c2)
    ];

    function setUp() public {
        vm.etch(ANCHORING_ADDRESS, address(new MockAnchoring()).code);
        vm.prank(owner);
        RegistryFactory factory = new RegistryDeployer().factory();
        vm.prank(creator);
        a = Registry(factory.deployRegistry("docs", "", ""));
        verifier = new MMRVerifier();
        vm.startPrank(creator); // the admin appends throughout; the roles test pranks its own
    }

    // -- helpers --------------------------------------------------------------

    function c(uint256 i) internal pure returns (bytes32) {
        return bytes32(i);
    }

    /// `peaks` after `node` is pushed, computed through the library as a prover would.
    function pushed(bytes32[] memory peaks, uint256 count, uint256 height, bytes32 node)
        internal
        pure
        returns (bytes32[] memory live)
    {
        bytes32[] memory room = new bytes32[](peaks.length + 1);
        for (uint256 i = 0; i < peaks.length; i++) {
            room[i] = peaks[i];
        }
        (uint256 len,) = MMR.push(room, peaks.length, count, height, node);
        live = new bytes32[](len);
        for (uint256 i = 0; i < len; i++) {
            live[i] = room[i];
        }
    }

    /// The root of a perfect tree over commitments `from .. from+size`, as a caller cuts a batch.
    function perfect(uint256 from, uint256 size) internal pure returns (bytes32) {
        bytes32[] memory nodes = new bytes32[](size);
        for (uint256 i = 0; i < size; i++) {
            nodes[i] = MMR.hashLeaf(c(from + i));
        }
        for (uint256 len = size; len > 1; len /= 2) {
            for (uint256 i = 0; i < len / 2; i++) {
                nodes[i] = MMR.hashMerge(nodes[2 * i], nodes[2 * i + 1]);
            }
        }
        return nodes[0];
    }

    function appendAll(uint256 upTo) internal {
        for (uint256 i = 1; i <= upTo; i++) {
            a.appendLeaf(c(i), "");
        }
    }

    // -- tests ----------------------------------------------------------------

    function test_sequential_appends_reach_the_reference_roots() public {
        for (uint256 i = 1; i <= 16; i++) {
            bytes32 root = a.appendLeaf(c(i), "");
            assertEq(root, ROOTS[i - 1], "root after leaf i, as returned");
            assertEq(a.mmrRoot(), ROOTS[i - 1], "root after leaf i, as read");
            (uint256 count, bytes32[] memory peaks) = anchoring.state(address(a));
            assertEq(count, i);
            assertEq(peaks.length, MMR.popcount(i), "one peak per set bit");
            assertEq(MMR.bag(peaks, peaks.length), a.mmrRoot(), "the peaks bag to the root");
        }
    }

    function test_a_batch_from_empty_reaches_the_sequential_root() public {
        // 13 leaves cut aligned from zero: sizes 8, 4, 1.
        bytes32[] memory roots = new bytes32[](3);
        uint8[] memory heights = new uint8[](3);
        (roots[0], heights[0]) = (perfect(1, 8), 3);
        (roots[1], heights[1]) = (perfect(9, 4), 2);
        (roots[2], heights[2]) = (perfect(13, 1), 0);
        bytes32 root = a.appendLeaves(roots, heights, "");
        assertEq(root, ROOTS[12], "one transaction, thirteen leaves");
        assertEq(a.mmrRoot(), ROOTS[12]);
    }

    function test_a_batch_after_a_prefix_is_cut_to_the_alignment() public {
        // Five leaves one by one, then eight more: [5,6) h0, [6,8) h1, [8,12) h2, [12,13) h0.
        appendAll(5);
        bytes32[] memory roots = new bytes32[](4);
        uint8[] memory heights = new uint8[](4);
        (roots[0], heights[0]) = (perfect(6, 1), 0);
        (roots[1], heights[1]) = (perfect(7, 2), 1);
        (roots[2], heights[2]) = (perfect(9, 4), 2);
        (roots[3], heights[3]) = (perfect(13, 1), 0);
        a.appendLeaves(roots, heights, "");
        assertEq(a.mmrRoot(), ROOTS[12], "sizes rise to the boundary and fall after it");
    }

    /// The precompile's refusals come back through the registry as they were raised.
    function test_a_chunk_off_the_alignment_is_refused() public {
        appendAll(5);
        bytes32[] memory roots = new bytes32[](1);
        uint8[] memory heights = new uint8[](1);
        (roots[0], heights[0]) = (perfect(6, 2), 1); // a pair at count 5: 5 % 2 != 0
        vm.expectRevert(abi.encodeWithSelector(IAnchoring.ChunkNotAligned.selector, 5, 1));
        a.appendLeaves(roots, heights, "");
        assertEq(a.mmrRoot(), ROOTS[4]);
    }

    function test_appending_takes_a_registry_writer() public {
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(Registry.Unauthorized.selector);
        a.appendLeaf(c(1), "");

        bytes32 role = a.ROLE_EDITOR(); // read first: a prank binds to the next call, and this is one
        vm.prank(creator);
        a.grantRole("", editor, role);
        vm.prank(editor);
        a.appendLeaf(c(1), "");
        assertEq(a.mmrRoot(), ROOTS[0], "an editor at registry scope appends");
    }

    /// What the log says: the registry is the namespace, and the event carries the peaks a
    /// prover needs and the metadata the caller attached.
    function test_the_event_carries_the_mmr_state() public {
        appendAll(5);
        (uint256 count, bytes32[] memory peaks) = anchoring.state(address(a));
        bytes32[] memory next = pushed(peaks, count, 0, MMR.hashLeaf(c(6)));

        vm.expectEmit(true, true, true, true, ANCHORING_ADDRESS);
        emit IAnchoring.LeafAppended(address(a), 5, c(6), ROOTS[5], next, "provenance");
        a.appendLeaf(c(6), "provenance");

        (count, peaks) = anchoring.state(address(a));
        assertEq(count, 6);
        assertEq(peaks, next, "what a proof is checked against");
    }

    function test_a_leaf_proves_against_the_root_and_a_wrong_one_does_not() public {
        appendAll(13);
        (uint256 count, bytes32[] memory peaks) = anchoring.state(address(a));
        // Leaf index 9 (commitment 10) sits in the height-2 peak; two siblings, from Python.
        bytes32[] memory siblings = new bytes32[](2);
        siblings[0] = 0xe8e9907a49e52d2764dc614a451816a79a3862c56e07472b7c7ef1f8b5b1246c;
        siblings[1] = 0x5d138ec8c7c0d75b7be3bda0c10ee681058499b7d781c9bf2680892e324da794;
        assertTrue(
            verifier.verify(a.mmrRoot(), c(10), 9, siblings, peaks, count), "the pinned proof"
        );
        assertFalse(
            verifier.verify(a.mmrRoot(), c(11), 9, siblings, peaks, count),
            "another commitment at that index"
        );
        assertFalse(
            verifier.verify(a.mmrRoot(), c(10), 8, siblings, peaks, count),
            "the right commitment at the wrong index"
        );
        siblings[1] = bytes32(uint256(siblings[1]) ^ 1);
        assertFalse(
            verifier.verify(a.mmrRoot(), c(10), 9, siblings, peaks, count), "a tampered sibling"
        );
    }
}
