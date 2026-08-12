// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Initializable } from "solady/utils/Initializable.sol";

import { ANCHORING_ADDRESS, IAnchoring } from "./interfaces/IAnchoring.sol";

/// @dev Just enough of the factory to read its owner, so the two contracts do not import
///      each other.
interface IOwned {
    function owner() external view returns (address);
}

/// @title Registry
/// @notice One registry of checksum records, versioned per checksum, with scoped RBAC —
///         anchored through the anchoring precompile rather than stored here. This contract
///         keeps only what authorization and id assignment need (counters and role
///         membership); every record version and status is committed into the precompile's
///         log under *this contract's* address, so `IAnchoring.latest(address(this), key)` is
///         the on-chain source of truth.
/// @dev One deployment per registry, from {RegistryFactory}. That is the whole reason this
///      contract has no `registryId`: the precompile is a caller-partitioned log, so the
///      deployment address *is* the partition, and a payload is only meaningful with the
///      namespace it was anchored under beside it.
///
///      Roles are registry-scoped (this whole contract — the role is its own id, no derivation)
///      or record-scoped (one checksum within it), over `admin` and `editor`. They are *not*
///      anchored: membership is this contract's state, history is `RoleGranted`/`RoleRevoked`,
///      and a third copy in the anchored log would only be something to drift.
///
///      There is no record-count getter. `recordCount` mints ids and nothing else reads it:
///      "how many records" and "list them in order" are `RecordAdded` replayed by an indexer,
///      the same split the factory makes for the set of registries.
///
///      Behind a beacon proxy, so the factory upgrades every registry at once. Break-glass
///      admin is read through the factory rather than copied here, so transferring ownership
///      moves it for every registry instead of only for the ones deployed afterwards.
///      Storage is ERC-7201-namespaced.
contract Registry is Initializable {
    // -- roles ---------------------------------------------------------------
    bytes32 public constant ROLE_ADMIN = "admin";
    bytes32 public constant ROLE_EDITOR = "editor";

    // -- envelope kinds ------------------------------------------------------
    bytes32 public constant KIND_RECORD = "record";
    bytes32 public constant KIND_STATUS = "status";

    /// @notice The `checksumHash` a registry-scoped role is announced under: `keccak256("")`,
    ///         which is what an empty checksum hashes to.
    bytes32 public constant REGISTRY_SCOPE = keccak256("");

    // -- ERC-7201 namespaced storage -----------------------------------------
    /// @custom:storage-location erc7201:anchoring.registry.instance.storage
    struct RegistryStorage {
        // the factory, read for `owner()` — its owner is the break-glass admin
        address factory;
        // 1-based recordId
        uint256 recordCount;
        // keccak(checksum) => recordId (0 = none)
        mapping(bytes32 => uint256) recordIdByChecksum;
        // recordId => latest index (1-based)
        mapping(uint256 => uint256) versionCount;
        // roleId => account => member
        mapping(bytes32 => mapping(address => bool)) member;
        // registry-level admin count, so last-admin protection is O(1)
        uint256 adminCount;
        // discriminator for status envelopes, so idempotent re-assertions never
        // collide with the precompile's no-op rule
        uint256 seq;
    }

    // keccak256(abi.encode(uint256(keccak256("anchoring.registry.instance.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SLOT =
        0xb5d5cee421de9184cedcdbf1c135f75de55ad252b6bdc4430a441446fc45c900;

    function _s() private pure returns (RegistryStorage storage $) {
        assembly {
            $.slot := SLOT
        }
    }

    // -- events --------------------------------------------------------------
    event RecordAdded(uint256 indexed recordId, uint256 index, string checksum);
    event RecordStatusUpdated(uint256 indexed recordId, uint256 index, string status);
    event RoleGranted(bytes32 indexed checksumHash, address indexed account, bytes32 role);
    event RoleRevoked(bytes32 indexed checksumHash, address indexed account, bytes32 role);

    // -- errors --------------------------------------------------------------
    error EmptyChecksum();
    error EmptyUri();
    error RecordNotFound(uint256 recordId, uint256 index);
    error NoRecordForChecksum(bytes32 checksumHash);
    error InvalidRole(bytes32 role);
    error MissingRole(address account, bytes32 role);
    error LastAdmin();
    error Unauthorized();

    /// @notice Initializes the registry with its first admin. Called by the factory in the
    ///         same transaction as the deployment.
    function initialize(address admin, address factory_) external initializer {
        RegistryStorage storage $ = _s();
        $.factory = factory_;
        $.member[ROLE_ADMIN][admin] = true;
        $.adminCount = 1;
        emit RoleGranted(REGISTRY_SCOPE, admin, ROLE_ADMIN);
    }

    // -- keys ----------------------------------------------------------------
    /// @notice The key a record stream is anchored under. No registry id: this contract is
    ///         the registry, and `latest(address(this), key)` is already scoped to it.
    function recordKey(uint256 recordId) public pure returns (bytes32) {
        return keccak256(abi.encode("record", recordId));
    }

    function statusKey(uint256 recordId, uint256 index) public pure returns (bytes32) {
        return keccak256(abi.encode("status", recordId, index));
    }

    /// @notice Record-level role id, scoped by record stream. Registry-level roles need no
    ///         derivation — the role *is* the id — so there is no `registryRole`.
    function recordRole(uint256 recordId, bytes32 role) public pure returns (bytes32) {
        return keccak256(abi.encode("role:record", recordId, role));
    }

    // -- records -------------------------------------------------------------
    /// @notice Appends a version to `checksum`, creating the stream on first use. Requires
    ///         `admin` or `editor` at record or registry scope. The version `index` inside the
    ///         anchored envelope makes every version's digest distinct, so re-anchoring
    ///         identical content is a new version, never a no-op revert.
    function addRecord(
        string calldata uri,
        string calldata checksum,
        string calldata checksumAlgo,
        string calldata metadata
    ) external returns (uint256 recordId, uint256 index) {
        if (bytes(checksum).length == 0) revert EmptyChecksum();
        if (bytes(uri).length == 0) revert EmptyUri();

        RegistryStorage storage $ = _s();
        bytes32 checksumHash = keccak256(bytes(checksum));
        recordId = $.recordIdByChecksum[checksumHash];
        // recordId 0 (a brand-new stream) matches no record-scoped grant: roles are only
        // grantable against existing streams, so a first version needs a registry-level role.
        _checkWriter(recordId);

        if (recordId == 0) {
            recordId = ++$.recordCount;
            $.recordIdByChecksum[checksumHash] = recordId;
        }
        index = ++$.versionCount[recordId];

        IAnchoring(ANCHORING_ADDRESS)
            .anchorAndHash(
                recordKey(recordId),
                abi.encode(
                    KIND_RECORD,
                    recordId,
                    index,
                    uri,
                    checksum,
                    checksumAlgo,
                    metadata,
                    block.timestamp
                )
            );
        emit RecordAdded(recordId, index, checksum);
    }

    /// @notice Anchors a status for one record version. Requires `admin` or `editor` at record
    ///         or registry scope. Idempotent: the envelope carries a sequence number, so
    ///         re-asserting the current status is a fresh anchor.
    function updateRecordStatus(uint256 recordId, uint256 index, string calldata status) external {
        RegistryStorage storage $ = _s();
        if (index == 0 || index > $.versionCount[recordId]) {
            revert RecordNotFound(recordId, index);
        }
        _checkWriter(recordId);

        IAnchoring(ANCHORING_ADDRESS)
            .anchorAndHash(
                statusKey(recordId, index),
                abi.encode(KIND_STATUS, recordId, index, status, ++$.seq)
            );
        emit RecordStatusUpdated(recordId, index, status);
    }

    // -- RBAC ----------------------------------------------------------------
    /// @notice Grants `role` at registry scope (`checksum == ""`) or record scope. The caller
    ///         must hold this registry's `admin` role — except that `owner()` may grant a
    ///         registry-level `admin` without holding it (break-glass recovery, which is what
    ///         makes the last-admin rule in {revokeRole} safe).
    function grantRole(string calldata checksum, address account, bytes32 role) external {
        (bytes32 roleId, bytes32 checksumHash, bool registryScope) = _scopedRole(checksum, role);
        bool registryAdmin = registryScope && role == ROLE_ADMIN;

        RegistryStorage storage $ = _s();
        bool breakGlass = registryAdmin && msg.sender == owner();
        if (!breakGlass && !_isRegistryAdmin()) revert Unauthorized();

        if (!$.member[roleId][account]) {
            $.member[roleId][account] = true;
            if (registryAdmin) $.adminCount++;
        }
        emit RoleGranted(checksumHash, account, role);
    }

    /// @notice Revokes a role. The last registry-level admin cannot be revoked — recover by
    ///         having `owner()` grant a replacement first, so a registry never reaches zero
    ///         admins.
    function revokeRole(string calldata checksum, address account, bytes32 role) external {
        (bytes32 roleId, bytes32 checksumHash, bool registryScope) = _scopedRole(checksum, role);

        RegistryStorage storage $ = _s();
        if (!_isRegistryAdmin()) revert Unauthorized();
        if (!$.member[roleId][account]) revert MissingRole(account, role);

        if (registryScope && role == ROLE_ADMIN) {
            if ($.adminCount <= 1) revert LastAdmin();
            $.adminCount--;
        }
        $.member[roleId][account] = false;
        emit RoleRevoked(checksumHash, account, role);
    }

    // -- views ---------------------------------------------------------------
    /// @notice The break-glass admin: the factory's owner, read live rather than copied at
    ///         deployment, so transferring it moves every registry at once.
    function owner() public view returns (address) {
        return IOwned(_s().factory).owner();
    }

    function factory() external view returns (address) {
        return _s().factory;
    }

    function recordIdForChecksum(string calldata checksum) external view returns (uint256) {
        return _s().recordIdByChecksum[keccak256(bytes(checksum))];
    }

    function versionCount(uint256 recordId) external view returns (uint256) {
        return _s().versionCount[recordId];
    }

    function hasRole(string calldata checksum, address account, bytes32 role)
        external
        view
        returns (bool)
    {
        (bytes32 roleId,,) = _resolveRole(checksum, role);
        return roleId != 0 && _s().member[roleId][account];
    }

    /// @notice The latest anchored digest for a record stream — verifiable against the
    ///         envelope in the corresponding `Anchored` event.
    function latestRecordDigest(uint256 recordId) external view returns (bytes32) {
        return IAnchoring(ANCHORING_ADDRESS).latest(address(this), recordKey(recordId));
    }

    // -- internals -----------------------------------------------------------
    /// @dev The caller holds this registry's `admin` role.
    function _isRegistryAdmin() private view returns (bool) {
        return _s().member[ROLE_ADMIN][msg.sender];
    }

    /// @dev `admin` or `editor`, registry scope first (the common case — every first version
    ///      is necessarily written by a registry-scoped holder), then record scope.
    function _checkWriter(uint256 recordId) private view {
        RegistryStorage storage $ = _s();
        if (_isRegistryAdmin()) return;
        if ($.member[ROLE_EDITOR][msg.sender]) return;
        if (recordId != 0) {
            if ($.member[recordRole(recordId, ROLE_ADMIN)][msg.sender]) return;
            if ($.member[recordRole(recordId, ROLE_EDITOR)][msg.sender]) return;
        }
        revert Unauthorized();
    }

    /// @dev Resolves a scope to its role id. Registry scope (`checksum == ""`) is the role
    ///      itself; record scope needs the stream the checksum names.
    function _resolveRole(string calldata checksum, bytes32 role)
        private
        view
        returns (bytes32 roleId, bytes32 checksumHash, bool registryScope)
    {
        registryScope = bytes(checksum).length == 0;
        checksumHash = keccak256(bytes(checksum));
        if (registryScope) {
            roleId = role;
        } else {
            uint256 recordId = _s().recordIdByChecksum[checksumHash];
            if (recordId != 0) roleId = recordRole(recordId, role);
        }
    }

    /// @dev Validates the role and the scope's existence, then derives the scoped role id.
    function _scopedRole(string calldata checksum, bytes32 role)
        private
        view
        returns (bytes32 roleId, bytes32 checksumHash, bool registryScope)
    {
        if (role != ROLE_ADMIN && role != ROLE_EDITOR) revert InvalidRole(role);

        (roleId, checksumHash, registryScope) = _resolveRole(checksum, role);
        if (roleId == 0) revert NoRecordForChecksum(checksumHash);
    }
}
