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
///         registry, record version, status, and ACL change is committed into the precompile's
///         log under this contract's namespace, so `IAnchoring.latest(address(this), key)` is
///         the on-chain source of truth and indexers reconstruct everything from `Anchored`
///         events.
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
        // registryId => recordId => keccak(checksum), for status-update authorization
        mapping(uint256 => mapping(uint256 => bytes32)) checksumByRecord;
        // registryId => recordId => latest index (1-based)
        mapping(uint256 => mapping(uint256 => uint256)) versionCount;
        // roleId => account => member
        mapping(bytes32 => mapping(address => bool)) member;
        // registryId => registry-level admin count, so last-admin protection is O(1)
        mapping(uint256 => uint256) adminCount;
        // discriminator for status/ACL envelopes, so idempotent re-assertions never
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

    /// @notice Registry-level role id.
    function registryRole(uint256 registryId, bytes32 role) public pure returns (bytes32) {
        return keccak256(abi.encode("role:registry", registryId, role));
    }

    /// @notice Record-level role id: scoped by registry *and* checksum, so a grant in one
    ///         registry never authorizes another registry sharing the same checksum.
    function recordRole(uint256 registryId, bytes32 checksumHash, bytes32 role)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode("role:record", registryId, checksumHash, role));
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
                abi.encode(id, name, description, metadata, msg.sender, block.timestamp)
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

        AnchoringStorage storage $ = _s();
        if (registryId == 0 || registryId > $.registryCount) revert RegistryNotFound(registryId);

        bytes32 checksumHash = keccak256(bytes(checksum));
        _checkWriter(registryId, checksumHash);

        recordId = $.recordIdByChecksum[registryId][checksumHash];
        if (recordId == 0) {
            recordId = ++$.recordCount[registryId];
            $.recordIdByChecksum[registryId][checksumHash] = recordId;
            $.checksumByRecord[registryId][recordId] = checksumHash;
        }
        index = ++$.versionCount[registryId][recordId];

        IAnchoring(ANCHORING_ADDRESS)
            .anchorAndHash(
                recordKey(registryId, recordId),
                abi.encode(
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

    /// @notice Anchors a status for one record version. Requires `admin` or `editor`; the
    ///         record scope comes from the stream's checksum. Idempotent: the envelope carries
    ///         a sequence number, so re-asserting the current status is a fresh anchor.
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
        _checkWriter(registryId, $.checksumByRecord[registryId][recordId]);

        IAnchoring(ANCHORING_ADDRESS)
            .anchorAndHash(
                statusKey(registryId, recordId, index),
                abi.encode(registryId, recordId, index, status, ++$.seq)
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
        bytes32 roleId = _scopedRole(registryId, checksum, role);

        bool breakGlass = msg.sender == owner() && role == ROLE_ADMIN && bytes(checksum).length == 0;
        if (!breakGlass && !_s().member[registryRole(registryId, ROLE_ADMIN)][msg.sender]) {
            revert Unauthorized();
        }

        AnchoringStorage storage $ = _s();
        if (!$.member[roleId][account]) {
            $.member[roleId][account] = true;
            if (role == ROLE_ADMIN && bytes(checksum).length == 0) $.adminCount[registryId]++;
        }
        emit RoleGranted(registryId, keccak256(bytes(checksum)), account, role);
    }

    /// @notice Revokes a role. The last registry-level admin cannot be revoked — recover by
    ///         having `owner()` grant a replacement first, so a registry never reaches zero
    ///         admins.
    function revokeRole(uint256 registryId, string calldata checksum, address account, bytes32 role)
        external
    {
        bytes32 roleId = _scopedRole(registryId, checksum, role);

        AnchoringStorage storage $ = _s();
        if (!$.member[registryRole(registryId, ROLE_ADMIN)][msg.sender]) revert Unauthorized();
        if (!$.member[roleId][account]) revert MissingRole(account, role);

        if (role == ROLE_ADMIN && bytes(checksum).length == 0) {
            if ($.adminCount[registryId] <= 1) revert LastAdmin();
            $.adminCount[registryId]--;
        }
        $.member[roleId][account] = false;
        emit RoleRevoked(registryId, keccak256(bytes(checksum)), account, role);
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
        bytes32 roleId = bytes(checksum).length == 0
            ? registryRole(registryId, role)
            : recordRole(registryId, keccak256(bytes(checksum)), role);
        return _s().member[roleId][account];
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
    /// @dev `admin` or `editor`, record scope first, then registry scope.
    function _checkWriter(uint256 registryId, bytes32 checksumHash) private view {
        AnchoringStorage storage $ = _s();
        if ($.member[recordRole(registryId, checksumHash, ROLE_ADMIN)][msg.sender]) return;
        if ($.member[recordRole(registryId, checksumHash, ROLE_EDITOR)][msg.sender]) return;
        if ($.member[registryRole(registryId, ROLE_ADMIN)][msg.sender]) return;
        if ($.member[registryRole(registryId, ROLE_EDITOR)][msg.sender]) return;
        revert Unauthorized();
    }

    /// @dev Validates the role and the scope's existence, then derives the scoped role id.
    function _scopedRole(uint256 registryId, string calldata checksum, bytes32 role)
        private
        view
        returns (bytes32)
    {
        if (role != ROLE_ADMIN && role != ROLE_EDITOR) revert InvalidRole(role);

        AnchoringStorage storage $ = _s();
        if (registryId == 0 || registryId > $.registryCount) revert RegistryNotFound(registryId);
        if (bytes(checksum).length == 0) return registryRole(registryId, role);

        bytes32 checksumHash = keccak256(bytes(checksum));
        if ($.recordIdByChecksum[registryId][checksumHash] == 0) {
            revert NoRecordForChecksum(registryId, checksumHash);
        }
        return recordRole(registryId, checksumHash, role);
    }

    function _authorizeUpgrade(address) internal override onlyOwner { }

    /// @dev Prevent the owner slot from being re-initialized on an upgradeable deployment.
    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }
}
