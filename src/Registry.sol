// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { ANCHORING_ADDRESS, IAnchoring } from "./interfaces/IAnchoring.sol";

/// @dev Just enough of the factory to read its owner, so the two contracts do not import
///      each other.
interface IOwned {
    function owner() external view returns (address);
}

/// @title Registry
/// @notice One registry of checksum records, versioned per checksum, with scoped RBAC. Every
///         version and status is a leaf of this contract's Merkle Mountain Range in the
///         anchoring precompile, never stored here: the contract keeps only role membership and
///         a version count per record. A leaf's payload is in the precompile's log, and it
///         proves against `IAnchoring.root(address(this))` with `log n` siblings, forever, through
///         {MMRVerifier}.
/// @dev One deployment per registry, from {RegistryFactory}. The precompile is partitioned by
///      caller, so the deployment address *is* the registry's MMR, and a payload is only
///      meaningful with the namespace it was appended under beside it. No registry id anywhere.
///
///      The MMR's count and peaks are the precompile's state, so a write carries no witness
///      and several may share a transaction. That is also what keeps the arithmetic, and its
///      bytecode, out of a contract deployed once per registry: the two leaf entry points
///      forward the call as it came, once the caller's role is checked.
///
///      A record has no id: `keccak256(checksum)` *is* its identity, which is what `addRecord`
///      already looked one up by. Numbering is log order, an indexer's job.
///
///      Roles are registry-scoped (this whole contract — the role is its own id, no derivation)
///      or record-scoped (one checksum within it), over `admin` and `editor`. They are *not*
///      leaves: membership is this contract's state, history is `RoleGranted`/`RoleRevoked`,
///      and a third copy in the log would only be something to drift.
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
    /// @dev Every envelope this contract commits to leads with its kind, so an indexer
    ///      classifies a leaf's payload from the log alone.
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
    /// Discriminator for status envelopes, so re-asserting a status is a distinct leaf.
    uint256 private seq;

    // -- events --------------------------------------------------------------
    /// @dev Carries what a consumer dedups on — `checksum`, `dataPointer` — and who to
    ///      attribute it to, so that needs no envelope decoding. The precompile's `namespace`
    ///      cannot stand in for `author`: it is always this contract.
    event RecordAdded(
        bytes32 indexed checksumHash,
        uint256 index,
        string checksum,
        RecordCategory category,
        string dataPointer,
        address indexed author
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
    /// A bare leaf leading with `record` or `status`, this contract's own kinds.
    error ReservedKind();

    /// @notice Deployed by {RegistryFactory}, with its creator as the first admin.
    constructor(address admin, address factory_) {
        factory = factory_;
        member[ROLE_ADMIN][admin] = true;
        adminCount = 1;
        emit RoleGranted(REGISTRY_SCOPE, admin, ROLE_ADMIN);
    }

    // -- keys ----------------------------------------------------------------
    /// @notice Record-level role id, scoped by record stream. Registry-level roles need no
    ///         derivation — the role *is* the id — so there is no `registryRole`.
    function recordRole(bytes32 checksumHash, bytes32 role) public pure returns (bytes32) {
        return keccak256(abi.encode("role:record", checksumHash, role));
    }

    // -- records -------------------------------------------------------------
    /// @notice Appends a version to `checksum`, creating the stream on first use, as one leaf
    ///         committing to the record envelope. Requires `admin` or `editor` at record or
    ///         registry scope. The version `index` inside the envelope makes every version's
    ///         digest distinct, so re-adding identical content is a new version.
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

        _append(
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
                msg.sender,
                block.timestamp
            )
        );
        emit RecordAdded(checksumHash, index, checksum, category, dataPointer, msg.sender);
    }

    /// @notice Appends a status for one record version, as one leaf. Requires `admin` or
    ///         `editor` at record or registry scope. Idempotent: the envelope carries a
    ///         sequence number, so re-asserting the current status is a fresh leaf.
    function updateRecordStatus(string calldata checksum, uint256 index, string calldata status)
        external
    {
        bytes32 checksumHash = keccak256(bytes(checksum));
        if (index == 0 || index > versionCount[checksumHash]) {
            revert RecordNotFound(checksumHash, index);
        }
        _checkWriter(checksumHash);

        _append(abi.encode(KIND_STATUS, checksumHash, index, status, msg.sender, ++seq));
        emit RecordStatusUpdated(checksumHash, index, status);
    }

    /// @dev One leaf committing to `envelope`, which rides along as the leaf's metadata so the
    ///      log carries the preimage: self-verifying, the commitment is its digest.
    function _append(bytes memory envelope) private {
        IAnchoring(ANCHORING_ADDRESS).appendLeaf(keccak256(envelope), envelope);
    }

    // -- leaves --------------------------------------------------------------
    /// @notice The registry's MMR root, zero before the first leaf.
    function mmrRoot() public view returns (bytes32) {
        return IAnchoring(ANCHORING_ADDRESS).root(address(this));
    }

    /// @notice Appends one leaf whose commitment is the caller's to shape: a record that lives
    ///         off-chain and proves against the root instead of being an envelope here.
    ///         Requires `admin` or `editor` at registry scope. Arguments are the precompile's.
    ///         A payload leading with `record` or `status` is refused: a reader takes the
    ///         author and version inside those on this contract's word.
    function appendLeaf(bytes32, bytes calldata metadata) external returns (bytes32 root) {
        _checkRegistryWriter();
        if (metadata.length >= 32) {
            bytes32 kind = bytes32(metadata[:32]);
            if (kind == KIND_RECORD || kind == KIND_STATUS) revert ReservedKind();
        }
        return _forward();
    }

    /// @notice The bulk anchor: a batch as the roots of aligned perfect subtrees, in leaf order,
    ///         one call however many rows. How a corpus loads, its rows staying off-chain.
    ///         Requires `admin` or `editor` at registry scope. Arguments are the precompile's.
    function appendLeaves(IAnchoring.Chunk[] calldata, bytes calldata)
        external
        returns (bytes32 root)
    {
        _checkRegistryWriter();
        return _forward();
    }

    /// @dev The call as it came, made under this contract's address. The precompile's signature
    ///      is this one's, so nothing is decoded to be encoded again, and its refusal is
    ///      returned as it was raised. A `call`, never `delegatecall`.
    function _forward() private returns (bytes32 root) {
        (bool ok, bytes memory out) = ANCHORING_ADDRESS.call(msg.data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(out, 32), mload(out))
            }
        }
        root = abi.decode(out, (bytes32));
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

    // -- internals -----------------------------------------------------------
    /// @dev The caller holds this registry's `admin` role.
    function _isRegistryAdmin() private view returns (bool) {
        return member[ROLE_ADMIN][msg.sender];
    }

    /// @dev `admin` or `editor` at registry scope: a leaf has no checksum for a record-scoped
    ///      role to attach to.
    function _checkRegistryWriter() private view {
        if (_isRegistryAdmin() || member[ROLE_EDITOR][msg.sender]) return;
        revert Unauthorized();
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
