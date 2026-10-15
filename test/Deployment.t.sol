// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Anchoring} from "../src/Anchoring.sol";

/// Writes what Tempo deploys and places: the implementation's creation code, the address
/// Arachnid's factory (forge's, and in Tempo's genesis) gives it, the runtime there, which holds
/// that address, and the proxy's runtime. Regenerate with `make layout`.
contract DeploymentTest is Test {
    bytes32 internal constant SALT = bytes32(0);

    function test_write_the_deployment() public {
        bytes memory init = type(Anchoring).creationCode;
        (bool ok, bytes memory deployed) = CREATE2_FACTORY.call(abi.encodePacked(SALT, init));
        assertTrue(ok, "the factory deploys it");
        address impl = address(bytes20(deployed));
        assertEq(impl, vm.computeCreate2Address(SALT, keccak256(init), CREATE2_FACTORY));

        address proxy = LibClone.deployERC1967(impl);
        assertEq(keccak256(proxy.code), LibClone.ERC1967_CODE_HASH);

        _write("layout/anchoring.init.bin", init);
        _write("layout/anchoring.bin", impl.code);
        _write("layout/proxy.bin", proxy.code);
        string memory json = "deployment";
        vm.serializeAddress(json, "factory", CREATE2_FACTORY);
        vm.serializeBytes32(json, "salt", SALT);
        vm.writeJson(vm.serializeAddress(json, "implementation", impl), "layout/deployment.json");
    }

    function _write(string memory path, bytes memory code) private {
        vm.writeFile(path, string.concat(vm.toString(code), "\n"));
    }
}
