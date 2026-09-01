// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { ANCHORING_ADDRESS, IAnchoring } from "./interfaces/IAnchoring.sol";

/// @dev Just enough of the factory to read its owner, so the two contracts do not import
///      each other.
interface IOwned {
    function owner() external view returns (address);
}

/// @title Registry
/// @notice One registry of checksum records, versioned per checksum, with scoped RBAC —
///         anchored through the anchoring precompile rather than stored here. This contract
///         keeps only role membership and a version count per record; every version and status
///         is committed into the precompile's log under *this contract's* address, so
///         `IAnchoring.latest(address(this), key)` is the on-chain source of truth.
/// @dev One deployment per registry, from {RegistryFactory}. That is the whole reason this
///      contract has no `registryId`: the precompile is a caller-partitioned log, so the
///      deployment address *is* the partition, and a payload is only meaningful with the
///      namespace it was anchored under beside it.
///
///      A record has no id either: `keccak256(checksum)` *is* its identity, which is what
///      `addRecord` already looked one up by. Numbering is log order, an indexer's job.
///
///      Roles are registry-scoped (this whole contract — the role is its own id, no derivation)
///      or record-scoped (one checksum within it), over `admin` and `editor`. They are *not*
///      anchored: membership is this contract's state, history is `RoleGranted`/`RoleRevoked`,
///      and a third copy in the anchored log would only be something to drift.
///
///      Immutable once deployed: no proxy, no `delegatecall`, so storage is plain. Break-glass
///      admin is read live through the factory rather than copied here, so transferring
///      ownership moves it for every registry instead of only for the ones deployed after.
contract Registry {
    // -- roles ---------------------------------------------------------------
    bytes32 public constant ROLE_ADMIN = "admin";
    bytes32 public constant ROLE_EDITOR = "editor";

    // -- record categories ---------------------------------------------------
    /// @notice The use-case a record attests to. An enum so the set is closed and checked at
    ///         ABI decode — an out-of-range value reverts before any state is touched — and
    ///         `Unspecified` is the zero value, so a record claiming no category says so.
    enum RecordCategory {
        Unspecified,
        PrivateMarketsDiligence,
        RegulatedBankUnderwriting,
        MultiPartyClinicalTrials,
        AgenticAI
    }

    // -- envelope kinds ------------------------------------------------------
    bytes32 public constant KIND_RECORD = "record";
    bytes32 public constant KIND_STATUS = "status";

    /// @notice The `checksumHash` a registry-scoped role is announced under: `keccak256("")`,
    ///         which is what an empty checksum hashes to.
    bytes32 public constant REGISTRY_SCOPE = keccak256("");

    // -- storage --------------------------------------------------------------
    /// @notice The factory that deployed this registry. Its owner is the
    ///         break-glass admin, read live so a transfer reaches every registry.
    address public immutable factory;

    /// @notice `keccak(checksum)` => version count; 0 means no such record.
    mapping(bytes32 => uint256) public versionCount;

    /// roleId => account => member
    mapping(bytes32 => mapping(address => bool)) private member;
    /// Registry-level admin count, so last-admin protection is O(1).
    uint256 private adminCount;
    /// Discriminator for status envelopes, so idempotent re-assertions never
    /// collide with the precompile's no-op rule.
    uint256 private seq;

    // -- events --------------------------------------------------------------
    /// @dev Carries what a consumer dedups on — `checksum`, `dataPointer` — so that needs no
    ///      envelope decoding.
    event RecordAdded(
        bytes32 indexed checksumHash,
        uint256 index,
        string checksum,
        RecordCategory category,
        string dataPointer
    );
    event RecordStatusUpdated(bytes32 indexed checksumHash, uint256 index, string status);
    event RoleGranted(bytes32 indexed checksumHash, address indexed account, bytes32 role);
    event RoleRevoked(bytes32 indexed checksumHash, address indexed account, bytes32 role);

    // -- errors --------------------------------------------------------------
    error EmptyChecksum();
    error EmptyUri();
    error RecordNotFound(bytes32 checksumHash, uint256 index);
    error NoRecordForChecksum(bytes32 checksumHash);
    error InvalidRole(bytes32 role);
    error MissingRole(address account, bytes32 role);
    error LastAdmin();
    error Unauthorized();

    /// @notice Deployed by {RegistryFactory}, with its creator as the first admin.
    constructor(address admin, address factory_) {
        factory = factory_;
        member[ROLE_ADMIN][admin] = true;
        adminCount = 1;
        emit RoleGranted(REGISTRY_SCOPE, admin, ROLE_ADMIN);
    }

    // -- keys ----------------------------------------------------------------
    /// @notice The key a record stream is anchored under. No registry id: this contract is
    ///         the registry, and `latest(address(this), key)` is already scoped to it.
    function recordKey(bytes32 checksumHash) public pure returns (bytes32) {
        return keccak256(abi.encode("record", checksumHash));
    }

    function statusKey(bytes32 checksumHash, uint256 index) public pure returns (bytes32) {
        return keccak256(abi.encode("status", checksumHash, index));
    }

    /// @notice Record-level role id, scoped by record stream. Registry-level roles need no
    ///         derivation — the role *is* the id — so there is no `registryRole`.
    function recordRole(bytes32 checksumHash, bytes32 role) public pure returns (bytes32) {
        return keccak256(abi.encode("role:record", checksumHash, role));
    }

    // -- records -------------------------------------------------------------
    /// @notice Appends a version to `checksum`, creating the stream on first use. Requires
    ///         `admin` or `editor` at record or registry scope. The version `index` inside the
    ///         anchored envelope makes every version's digest distinct, so re-anchoring
    ///         identical content is a new version, never a no-op revert.
    /// @param  category    What the record attests to. Classification, not authorization.
    /// @param  dataPointer Identifies the data, where `checksum` identifies the bytes — the
    ///         pair tells the same data re-attested from different data. May be empty; that
    ///         only collapses the caller's records onto one pointer for anyone deduping on it.
    function addRecord(
        string calldata uri,
        string calldata checksum,
        string calldata checksumAlgo,
        string calldata metadata,
        RecordCategory category,
        string calldata dataPointer
    ) external returns (bytes32 checksumHash, uint256 index) {
        if (bytes(checksum).length == 0) revert EmptyChecksum();
        if (bytes(uri).length == 0) revert EmptyUri();

        checksumHash = keccak256(bytes(checksum));
        _checkWriter(checksumHash);
        index = ++versionCount[checksumHash];

        IAnchoring(ANCHORING_ADDRESS)
            .anchorAndHash(
                recordKey(checksumHash),
                abi.encode(
                    KIND_RECORD,
                    checksumHash,
                    index,
                    uri,
                    checksum,
                    checksumAlgo,
                    metadata,
                    category,
                    dataPointer,
                    block.timestamp
                )
            );
        emit RecordAdded(checksumHash, index, checksum, category, dataPointer);
    }

    /// @notice Anchors a status for one record version. Requires `admin` or `editor` at record
    ///         or registry scope. Idempotent: the envelope carries a sequence number, so
    ///         re-asserting the current status is a fresh anchor.
    function updateRecordStatus(string calldata checksum, uint256 index, string calldata status)
        external
    {
        bytes32 checksumHash = keccak256(bytes(checksum));
        if (index == 0 || index > versionCount[checksumHash]) {
            revert RecordNotFound(checksumHash, index);
        }
        _checkWriter(checksumHash);

        IAnchoring(ANCHORING_ADDRESS)
            .anchorAndHash(
                statusKey(checksumHash, index),
                abi.encode(KIND_STATUS, checksumHash, index, status, ++seq)
            );
        emit RecordStatusUpdated(checksumHash, index, status);
    }

    // -- RBAC ----------------------------------------------------------------
    /// @notice Grants `role` at registry scope (`checksum == ""`) or record scope. The caller
    ///         must hold this registry's `admin` role — except that `owner()` may grant a
    ///         registry-level `admin` without holding it (break-glass recovery, which is what
    ///         makes the last-admin rule in {revokeRole} safe).
    function grantRole(string calldata checksum, address account, bytes32 role) external {
        (bytes32 roleId, bytes32 checksumHash, bool registryScope) = _scopedRole(checksum, role);
        bool registryAdmin = registryScope && role == ROLE_ADMIN;

        // The admin bit first: it is one warm SLOAD, where `owner()` is an external
        // call into the factory -- break-glass is consulted only when the caller
        // holds nothing, which is the case it exists for.
        if (!_isRegistryAdmin() && !(registryAdmin && msg.sender == owner())) {
            revert Unauthorized();
        }

        if (!member[roleId][account]) {
            member[roleId][account] = true;
            if (registryAdmin) adminCount++;
        }
        emit RoleGranted(checksumHash, account, role);
    }

    /// @notice Revokes a role. The last registry-level admin cannot be revoked — recover by
    ///         having `owner()` grant a replacement first, so a registry never reaches zero
    ///         admins.
    function revokeRole(string calldata checksum, address account, bytes32 role) external {
        (bytes32 roleId, bytes32 checksumHash, bool registryScope) = _scopedRole(checksum, role);

        if (!_isRegistryAdmin()) revert Unauthorized();
        if (!member[roleId][account]) revert MissingRole(account, role);

        if (registryScope && role == ROLE_ADMIN) {
            if (adminCount <= 1) revert LastAdmin();
            adminCount--;
        }
        member[roleId][account] = false;
        emit RoleRevoked(checksumHash, account, role);
    }

    // -- views ---------------------------------------------------------------
    /// @notice The break-glass admin: the factory's owner, read live rather than copied at
    ///         deployment, so transferring it moves every registry at once.
    function owner() public view returns (address) {
        return IOwned(factory).owner();
    }

    function hasRole(string calldata checksum, address account, bytes32 role)
        external
        view
        returns (bool)
    {
        (bytes32 roleId,,) = _resolveRole(checksum, role);
        return roleId != 0 && member[roleId][account];
    }

    /// @notice The latest anchored digest for a record stream — verifiable against the
    ///         envelope in the corresponding `Anchored` event.
    function latestRecordDigest(bytes32 checksumHash) external view returns (bytes32) {
        return IAnchoring(ANCHORING_ADDRESS).latest(address(this), recordKey(checksumHash));
    }

    // -- internals -----------------------------------------------------------
    /// @dev The caller holds this registry's `admin` role.
    function _isRegistryAdmin() private view returns (bool) {
        return member[ROLE_ADMIN][msg.sender];
    }

    /// @dev `admin` or `editor`, registry scope first (the common case — every first version
    ///      is necessarily written by a registry-scoped holder), then record scope.
    function _checkWriter(bytes32 checksumHash) private view {
        if (_isRegistryAdmin()) return;
        if (member[ROLE_EDITOR][msg.sender]) return;
        if (member[recordRole(checksumHash, ROLE_ADMIN)][msg.sender]) return;
        if (member[recordRole(checksumHash, ROLE_EDITOR)][msg.sender]) return;
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
        } else if (versionCount[checksumHash] != 0) {
            roleId = recordRole(checksumHash, role);
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
