// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Ownable } from "solady/auth/Ownable.sol";
import { Initializable } from "solady/utils/Initializable.sol";
import { UUPSUpgradeable } from "solady/utils/UUPSUpgradeable.sol";

import { Registry } from "./Registry.sol";

/// @title RegistryFactory
/// @notice Deploys one {Registry} per registry and is the record of which ones exist.
/// @dev Registries are beacon proxies: `implementation()` here is the single upgrade point
///      for every registry at once, which is what the one-proxy-for-everything design bought
///      and this keeps. `owner` (a Safe) is the upgrade authority, and every registry reads it
///      back as its break-glass admin.
///
///      Registry metadata is *not* anchored. Name, description and metadata are descriptive
///      rather than a commitment, and they are set once at deployment, so `RegistryDeployed`
///      is the whole record — an indexer reads it straight from the log with no envelope to
///      decode. What gets anchored is what needs proving: the records themselves.
contract RegistryFactory is UUPSUpgradeable, Initializable, Ownable {
    // -- beacon --------------------------------------------------------------
    /// @notice The implementation every registry proxy delegates to. Upgrading it upgrades
    ///         every registry in one transaction.
    address public implementation;

    /// @notice Registries in deployment order, so the set is enumerable on-chain as well as
    ///         from the log.
    address[] public registries;

    event RegistryDeployed(
        address indexed registry,
        address indexed creator,
        uint256 indexed index,
        string name,
        string description,
        string metadata
    );
    event ImplementationUpgraded(address indexed implementation);

    error EmptyName();
    /// @dev `delegatecall` to an account with no code *succeeds* with empty returndata, so
    ///      every registry behind such a beacon would return zeros instead of reverting.
    ///      A code check refuses the whole class -- zero, an EOA, a typo -- not just zero.
    error CodelessImplementation();

    function initialize(address owner_, address implementation_) external initializer {
        if (implementation_.code.length == 0) revert CodelessImplementation();
        _initializeOwner(owner_);
        implementation = implementation_;
        emit ImplementationUpgraded(implementation_);
    }

    /// @notice Deploys a registry and makes the caller its admin. Permissionless, and `name`
    ///         is deliberately not unique — the address is the canonical reference.
    function deployRegistry(
        string calldata name,
        string calldata description,
        string calldata metadata
    ) external returns (address registry) {
        if (bytes(name).length == 0) revert EmptyName();

        registry = address(new BeaconProxy(address(this)));
        Registry(registry).initialize(msg.sender, address(this));

        uint256 index = registries.length;
        registries.push(registry);
        emit RegistryDeployed(registry, msg.sender, index, name, description, metadata);
    }

    /// @notice Points every registry at a new implementation.
    function upgradeRegistries(address implementation_) external onlyOwner {
        if (implementation_.code.length == 0) revert CodelessImplementation();
        implementation = implementation_;
        emit ImplementationUpgraded(implementation_);
    }

    function registryCount() external view returns (uint256) {
        return registries.length;
    }

    function _authorizeUpgrade(address) internal override onlyOwner { }

    /// @dev Prevent the owner slot from being re-initialized on an upgradeable deployment.
    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }
}

/// @notice Minimal beacon proxy: reads its implementation from the factory on every call, so
///         one factory upgrade moves every registry.
/// @dev Deliberately tiny — the deploy cost per registry is this contract's bytecode, and a
///      registry is expected to be cheap to create.
contract BeaconProxy {
    /// @dev The beacon (the factory). Immutable, so it costs no storage read per call.
    address private immutable BEACON;

    constructor(address beacon) {
        BEACON = beacon;
    }

    fallback() external payable {
        address impl = RegistryFactory(BEACON).implementation();
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
