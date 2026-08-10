// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Ownable } from "solady/auth/Ownable.sol";
import { Initializable } from "solady/utils/Initializable.sol";
import { UUPSUpgradeable } from "solady/utils/UUPSUpgradeable.sol";

import { ANCHORING_ADDRESS, IAnchoring } from "./interfaces/IAnchoring.sol";

/// @title AnchoringRegistry
/// @notice Registries of checksum records, versioned per checksum, with scoped RBAC — anchored
///         through the anchoring precompile rather than stored here. This contract keeps only
///         what authorization and id assignment need (counters and role membership); every
///         registry, record version, status, and role change is committed into the precompile's
///         log under this contract's namespace, so `IAnchoring.latest(address(this), key)` is
///         the on-chain source of truth and indexers reconstruct that history — permissions
///         included — from `Anchored` events alone. The `RoleGranted`/`RoleRevoked` events are
///         the same facts in readable form, for consumers already following this contract.
/// @dev UUPS proxy; `owner` (a Safe) is the upgrade authority and the break-glass admin: it may
///      grant a registry-level `admin` without holding one, which is what keeps the last-admin
///      rule recoverable. Storage is ERC-7201-namespaced.
///
///      Roles are scoped, not global: registry-level or record-level (one checksum within one
///      registry), over `admin` and `editor`. Role ids are `keccak256(abi.encode(...))` over
///      the scope fields — following the anchoring module's *scoping* (a record role in one
///      registry never authorizes another registry sharing the checksum) while sidestepping
///      its string-concatenation encoding entirely: fixed-width ABI fields cannot be forged
///      with separator characters.
contract AnchoringRegistry is UUPSUpgradeable, Initializable, Ownable {
    // -- roles ---------------------------------------------------------------
    bytes32 public constant ROLE_ADMIN = "admin";
    bytes32 public constant ROLE_EDITOR = "editor";

    // -- ERC-7201 namespaced storage -----------------------------------------
    /// @custom:storage-location erc7201:anchoring.registry.storage
    struct AnchoringStorage {
        uint256 registryCount;
        // registryId => count (1-based recordId)
        mapping(uint256 => uint256) recordCount;
        // registryId => keccak(checksum) => recordId (0 = none)
        mapping(uint256 => mapping(bytes32 => uint256)) recordIdByChecksum;
        // registryId => recordId => latest index (1-based)
        mapping(uint256 => mapping(uint256 => uint256)) versionCount;
        // roleId => account => member
        mapping(bytes32 => mapping(address => bool)) member;
        // registryId => registry-level admin count, so last-admin protection is O(1)
        mapping(uint256 => uint256) adminCount;
        // discriminator for status envelopes, so idempotent re-assertions never
        // collide with the precompile's no-op rule
        uint256 seq;
    }

    // keccak256(abi.encode(uint256(keccak256("anchoring.registry.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SLOT =
        0x8b49649f5faffe6fb556822f369f5b9093cb15727ca57978ba8ef3ec01def500;

    function _s() private pure returns (AnchoringStorage storage $) {
        assembly {
            $.slot := SLOT
        }
    }

    // -- events --------------------------------------------------------------
    event RegistryAdded(uint256 indexed id, string name, address indexed creator);
    event RecordAdded(
        uint256 indexed registryId, uint256 indexed recordId, uint256 index, string checksum
    );
    event RecordStatusUpdated(
        uint256 indexed registryId, uint256 indexed recordId, uint256 index, string status
    );
    event RoleGranted(
        uint256 indexed registryId, bytes32 checksumHash, address indexed account, bytes32 role
    );
    event RoleRevoked(
        uint256 indexed registryId, bytes32 checksumHash, address indexed account, bytes32 role
    );

    // -- errors --------------------------------------------------------------
    error EmptyName();
    error EmptyChecksum();
    error EmptyUri();
    error RegistryNotFound(uint256 id);
    error RecordNotFound(uint256 registryId, uint256 recordId, uint256 index);
    error NoRecordForChecksum(uint256 registryId, bytes32 checksumHash);
    error InvalidRole(bytes32 role);
    error MissingRole(address account, bytes32 role);
    error LastAdmin();

    // -- init ----------------------------------------------------------------
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_) external initializer {
        _initializeOwner(owner_);
    }

    // -- envelope kinds -------------------------------------------------------
    /// @dev Every anchored envelope leads with one of these, so an indexer can classify a
    ///      payload from the log alone rather than having to match it against a derived key.
    bytes32 public constant KIND_REGISTRY = "registry";
    bytes32 public constant KIND_RECORD = "record";
    bytes32 public constant KIND_STATUS = "status";
    bytes32 public constant KIND_ACL = "acl";

    // -- key and role derivation (public, so indexers derive identically) ----
    function registryKey(uint256 id) public pure returns (bytes32) {
        return keccak256(abi.encode("registry", id));
    }

    function recordKey(uint256 registryId, uint256 recordId) public pure returns (bytes32) {
        return keccak256(abi.encode("record", registryId, recordId));
    }

    function statusKey(uint256 registryId, uint256 recordId, uint256 index)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode("status", registryId, recordId, index));
    }

    /// @notice The key an ACL change is anchored under. ``latest(registry, aclKey(...))``
    ///         is the live state of one grant, provable without reading contract storage.
    function aclKey(uint256 registryId, bytes32 checksumHash, address account, bytes32 role)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode("acl", registryId, checksumHash, account, role));
    }

    /// @notice Registry-level role id.
    function registryRole(uint256 registryId, bytes32 role) public pure returns (bytes32) {
        return keccak256(abi.encode("role:registry", registryId, role));
    }

    /// @notice Record-level role id: scoped by registry *and* record stream (within a registry
    ///         the checksum↔recordId map is a bijection), so a grant in one registry never
    ///         authorizes another registry sharing the same checksum.
    function recordRole(uint256 registryId, uint256 recordId, bytes32 role)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode("role:record", registryId, recordId, role));
    }

    // -- registries ----------------------------------------------------------
    /// @notice Creates a registry and makes the caller its admin. Permissionless, and `name`
    ///         is deliberately not unique — `id` is the canonical reference.
    function addRegistry(
        string calldata name,
        string calldata description,
        string calldata metadata
    ) external returns (uint256 id) {
        if (bytes(name).length == 0) revert EmptyName();

        AnchoringStorage storage $ = _s();
        id = ++$.registryCount;

        $.member[registryRole(id, ROLE_ADMIN)][msg.sender] = true;
        $.adminCount[id] = 1;

        IAnchoring(ANCHORING_ADDRESS)
            .anchorAndHash(
                registryKey(id),
                abi.encode(
                    KIND_REGISTRY, id, name, description, metadata, msg.sender, block.timestamp
                )
            );
        emit RegistryAdded(id, name, msg.sender);
    }

    // -- records -------------------------------------------------------------
    /// @notice Appends a version to `(registryId, checksum)`, creating the stream on first
    ///         use. Requires `admin` or `editor` at record or registry scope. The version
    ///         `index` inside the anchored envelope makes every version's digest distinct, so
    ///         re-anchoring identical content is a new version, never a no-op revert.
    function addRecord(
        uint256 registryId,
        string calldata uri,
        string calldata checksum,
        string calldata checksumAlgo,
        string calldata metadata
    ) external returns (uint256 recordId, uint256 index) {
        if (bytes(checksum).length == 0) revert EmptyChecksum();
        if (bytes(uri).length == 0) revert EmptyUri();
        _requireRegistry(registryId);

        AnchoringStorage storage $ = _s();
        bytes32 checksumHash = keccak256(bytes(checksum));
        recordId = $.recordIdByChecksum[registryId][checksumHash];
        // recordId 0 (a brand-new stream) matches no record-scoped grant: roles are only
        // grantable against existing streams, so a first version needs a registry-level role.
        _checkWriter(registryId, recordId);

        if (recordId == 0) {
            recordId = ++$.recordCount[registryId];
            $.recordIdByChecksum[registryId][checksumHash] = recordId;
        }
        index = ++$.versionCount[registryId][recordId];

        IAnchoring(ANCHORING_ADDRESS)
            .anchorAndHash(
                recordKey(registryId, recordId),
                abi.encode(
                    KIND_RECORD,
                    registryId,
                    recordId,
                    index,
                    uri,
                    checksum,
                    checksumAlgo,
                    metadata,
                    block.timestamp
                )
            );
        emit RecordAdded(registryId, recordId, index, checksum);
    }

    /// @notice Anchors a status for one record version. Requires `admin` or `editor` at record
    ///         or registry scope. Idempotent: the envelope carries a sequence number, so
    ///         re-asserting the current status is a fresh anchor.
    function updateRecordStatus(
        uint256 registryId,
        uint256 recordId,
        uint256 index,
        string calldata status
    ) external {
        AnchoringStorage storage $ = _s();
        if (index == 0 || index > $.versionCount[registryId][recordId]) {
            revert RecordNotFound(registryId, recordId, index);
        }
        _checkWriter(registryId, recordId);

        IAnchoring(ANCHORING_ADDRESS)
            .anchorAndHash(
                statusKey(registryId, recordId, index),
                abi.encode(KIND_STATUS, registryId, recordId, index, status, ++$.seq)
            );
        emit RecordStatusUpdated(registryId, recordId, index, status);
    }

    // -- RBAC ----------------------------------------------------------------
    /// @notice Grants `role` at registry scope (`checksum == ""`) or record scope. The caller
    ///         must hold the registry's `admin` role — except that `owner()` may grant a
    ///         registry-level `admin` without holding it (break-glass recovery, which is what
    ///         makes the last-admin rule in {revokeRole} safe).
    function grantRole(uint256 registryId, string calldata checksum, address account, bytes32 role)
        external
    {
        (bytes32 roleId, bytes32 checksumHash, bool registryScope) =
            _scopedRole(registryId, checksum, role);
        bool registryAdmin = registryScope && role == ROLE_ADMIN;

        AnchoringStorage storage $ = _s();
        bool breakGlass = registryAdmin && msg.sender == owner();
        if (!breakGlass && !_isRegistryAdmin(registryId)) revert Unauthorized();

        if (!$.member[roleId][account]) {
            $.member[roleId][account] = true;
            if (registryAdmin) $.adminCount[registryId]++;
            _anchorAcl(registryId, checksumHash, account, role, true);
        }
        emit RoleGranted(registryId, checksumHash, account, role);
    }

    /// @notice Revokes a role. The last registry-level admin cannot be revoked — recover by
    ///         having `owner()` grant a replacement first, so a registry never reaches zero
    ///         admins.
    function revokeRole(uint256 registryId, string calldata checksum, address account, bytes32 role)
        external
    {
        (bytes32 roleId, bytes32 checksumHash, bool registryScope) =
            _scopedRole(registryId, checksum, role);

        AnchoringStorage storage $ = _s();
        if (!_isRegistryAdmin(registryId)) revert Unauthorized();
        if (!$.member[roleId][account]) revert MissingRole(account, role);

        if (registryScope && role == ROLE_ADMIN) {
            if ($.adminCount[registryId] <= 1) revert LastAdmin();
            $.adminCount[registryId]--;
        }
        $.member[roleId][account] = false;
        _anchorAcl(registryId, checksumHash, account, role, false);
        emit RoleRevoked(registryId, checksumHash, account, role);
    }

    // -- views ---------------------------------------------------------------
    function registryCount() external view returns (uint256) {
        return _s().registryCount;
    }

    function recordCount(uint256 registryId) external view returns (uint256) {
        return _s().recordCount[registryId];
    }

    function recordIdForChecksum(uint256 registryId, string calldata checksum)
        external
        view
        returns (uint256)
    {
        return _s().recordIdByChecksum[registryId][keccak256(bytes(checksum))];
    }

    function versionCount(uint256 registryId, uint256 recordId) external view returns (uint256) {
        return _s().versionCount[registryId][recordId];
    }

    function hasRole(uint256 registryId, string calldata checksum, address account, bytes32 role)
        external
        view
        returns (bool)
    {
        (bytes32 roleId,,) = _resolveRole(registryId, checksum, role);
        return roleId != 0 && _s().member[roleId][account];
    }

    /// @notice The latest anchored digest for a record stream — verifiable against the
    ///         envelope in the corresponding `Anchored` event.
    function latestRecordDigest(uint256 registryId, uint256 recordId)
        external
        view
        returns (bytes32)
    {
        return IAnchoring(ANCHORING_ADDRESS).latest(address(this), recordKey(registryId, recordId));
    }

    // -- internals -----------------------------------------------------------
    /// @dev Ids are 1-based and dense, so this is the definition of "the registry exists".
    function _requireRegistry(uint256 registryId) private view {
        if (registryId == 0 || registryId > _s().registryCount) {
            revert RegistryNotFound(registryId);
        }
    }

    /// @dev The caller holds the registry-level `admin` role.
    function _isRegistryAdmin(uint256 registryId) private view returns (bool) {
        return _s().member[registryRole(registryId, ROLE_ADMIN)][msg.sender];
    }

    /// @dev Anchors one grant's new state, so an indexer rebuilds permissions from the log
    ///      rather than from this contract's events.
    ///
    ///      Only reached when membership actually changed. Anchoring an unchanged grant would
    ///      re-anchor an identical envelope and revert `CommitmentUnchanged`, turning a
    ///      repeated grant from a no-op into a failure. No sequence number is needed: the
    ///      no-op rule compares against the current head, and granted/revoked alternate.
    function _anchorAcl(
        uint256 registryId,
        bytes32 checksumHash,
        address account,
        bytes32 role,
        bool granted
    ) private {
        IAnchoring(ANCHORING_ADDRESS)
            .anchorAndHash(
                aclKey(registryId, checksumHash, account, role),
                abi.encode(KIND_ACL, registryId, checksumHash, account, role, granted)
            );
    }

    /// @dev `admin` or `editor`, registry scope first (the common case — every first version
    ///      is necessarily written by a registry-scoped holder), then record scope.
    function _checkWriter(uint256 registryId, uint256 recordId) private view {
        AnchoringStorage storage $ = _s();
        if (_isRegistryAdmin(registryId)) return;
        if ($.member[registryRole(registryId, ROLE_EDITOR)][msg.sender]) return;
        if ($.member[recordRole(registryId, recordId, ROLE_ADMIN)][msg.sender]) return;
        if ($.member[recordRole(registryId, recordId, ROLE_EDITOR)][msg.sender]) return;
        revert Unauthorized();
    }

    /// @dev Derives the scoped role id without validating existence: `roleId == 0` means record
    ///      scope with no stream for the checksum. The one place scope is decided — callers
    ///      reuse `checksumHash` (events) and `registryScope` (admin-count bookkeeping).
    function _resolveRole(uint256 registryId, string calldata checksum, bytes32 role)
        private
        view
        returns (bytes32 roleId, bytes32 checksumHash, bool registryScope)
    {
        registryScope = bytes(checksum).length == 0;
        checksumHash = keccak256(bytes(checksum));
        if (registryScope) {
            roleId = registryRole(registryId, role);
        } else {
            uint256 recordId = _s().recordIdByChecksum[registryId][checksumHash];
            if (recordId != 0) roleId = recordRole(registryId, recordId, role);
        }
    }

    /// @dev Validates the role and the scope's existence, then derives the scoped role id.
    function _scopedRole(uint256 registryId, string calldata checksum, bytes32 role)
        private
        view
        returns (bytes32 roleId, bytes32 checksumHash, bool registryScope)
    {
        if (role != ROLE_ADMIN && role != ROLE_EDITOR) revert InvalidRole(role);
        _requireRegistry(registryId);

        (roleId, checksumHash, registryScope) = _resolveRole(registryId, checksum, role);
        if (roleId == 0) revert NoRecordForChecksum(registryId, checksumHash);
    }

    function _authorizeUpgrade(address) internal override onlyOwner { }

    /// @dev Prevent the owner slot from being re-initialized on an upgradeable deployment.
    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }
}
