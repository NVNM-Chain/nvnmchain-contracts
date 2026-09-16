// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

import {AnchoringRBAC} from "./AnchoringRBAC.sol";
import {Bech32} from "./Bech32.sol";
import {GoTime} from "./GoTime.sol";
import {IAnchoring} from "./IAnchoring.sol";
import {Roles} from "./Roles.sol";

/// @title Anchoring
/// @notice x/anchoring with its state in EVM storage: the precompile's methods, selectors and
///         events, over the whole `Record`.
/// @dev Each method names the keeper function it ports. A caller sees four differences: exact
///      name match folding ASCII case, timestamps with no sub-second part, shorter revert
///      strings where one formats a value, and no reason at all on a call carrying value.
///      The storage layout is the migration's interface; `test/StorageLayout.t.sol` pins it.
contract Anchoring is IAnchoring, AnchoringRBAC {
    string internal constant HRP = "nvnm"; // the bech32 prefix of `Registry.creator`

    /// Field limits in bytes, from `types/record_validation.go` and `types/registry_validation.go`.
    uint256 internal constant MAX_CHECKSUM = 64;
    uint256 internal constant MAX_CHECKSUM_ALGO = 128;
    uint256 internal constant MAX_URI = 2048;
    uint256 internal constant MAX_METADATA = 2048;
    uint256 internal constant MAX_STATUS = 64;
    uint256 internal constant MAX_NAME = 128;
    uint256 internal constant MAX_DESCRIPTION = 2048;

    /// Paging, from `keeper/query.go`.
    uint64 internal constant DEFAULT_PAGE_LIMIT = 50;
    uint64 internal constant MAX_PAGE_LIMIT = 200;

    /// `types.RegistryNameMatchMode`: 0/1 exact, 2 prefix, 3 suffix, 4 contains.
    uint8 internal constant MATCH_EXACT = 1;
    uint8 internal constant MATCH_MAX = 4;

    /// `params.Admin`, who may grant a registry admin without holding the role. No method sets
    /// it; the migration writes the slot.
    address internal _moduleAdmin;

    /// `RegistryCount`. Ids run `1..count` with no gaps, which paging relies on and the
    /// migration guarantees.
    uint64 internal _registryCount;

    mapping(uint64 => Registry) internal _registries; // `Registries`
    mapping(uint64 => uint64) internal _recordCount; // `RecordsCountByRegistry`
    mapping(uint64 => mapping(uint64 => uint64)) internal _latestIndex; // `RecordIndices`
    mapping(uint64 => mapping(uint64 => mapping(uint64 => Record))) internal _records; // `Records`
    mapping(uint64 => mapping(string => uint64)) internal _recordIdByChecksum; // `RecordIdByRegistryAndChecksum`

    /// `RecordIdByChecksumAndRegistry`, which the module prefix-scans. A mapping cannot be
    /// scanned, so it is a list, ascending as the scan returns it.
    mapping(string => uint64[]) internal _registriesByChecksum;

    /// The exact-match name index, keyed by `_lower(name)` as the node's index keyed it.
    /// Names are not unique, hence a list.
    mapping(string => uint64[]) internal _registriesByName;

    constructor(address moduleAdmin) {
        _moduleAdmin = moduleAdmin;
    }

    // ---- transactions ----

    /// @inheritdoc IAnchoring
    /// @dev `keeper.AddRegistry`. The creator is granted admin unchecked: nobody holds the role yet.
    function addRegistry(string calldata name, string calldata description, string calldata metadata)
        external
        returns (uint64 registryId)
    {
        _ensureEoaCaller();
        require(bytes(name).length != 0, "name cannot be empty");
        require(bytes(name).length <= MAX_NAME, "name exceeds max length");
        require(bytes(description).length <= MAX_DESCRIPTION, "description exceeds max length");
        require(bytes(metadata).length <= MAX_METADATA, "metadata exceeds max length");

        registryId = _registryCount + 1;
        Registry storage registry = _registries[registryId];
        registry.id = registryId;
        registry.name = name;
        registry.description = description;
        registry.creator = Bech32.encode(HRP, bytes20(msg.sender));
        registry.createdAt = GoTime.format(block.timestamp);
        registry.metadata = metadata;

        bytes32 adminRole = Roles.forRegistry(registryId, Roles.ADMIN);
        _setRoleAdmin(adminRole, adminRole);
        _grantRoleUnchecked(adminRole, msg.sender);

        _registriesByName[_lower(name)].push(registryId);
        _registryCount = registryId;

        emit AddRegistry(msg.sender, registryId, name);
    }

    /// @inheritdoc IAnchoring
    /// @dev `keeper.AddRecord`. The chain sets `recordId`, `index`, `isLatest` and `timestamp`;
    ///      a checksum the registry already has gets a new version, not a new record.
    function addRecord(Record calldata record) external returns (uint64 recordId) {
        _ensureEoaCaller();
        _validateRecordForCreate(record);

        uint64 registryId = record.registryId;
        require(_registries[registryId].id != 0, "registry does not exist");
        _checkPermission(msg.sender, registryId, record.checksum);

        recordId = _recordIdByChecksum[registryId][record.checksum];
        if (recordId == 0) {
            recordId = _recordCount[registryId] + 1;
            _recordCount[registryId] = recordId;
            _recordIdByChecksum[registryId][record.checksum] = recordId;
            _addRegistryForChecksum(record.checksum, registryId);
        }

        uint64 index = _latestIndex[registryId][recordId] + 1;
        _latestIndex[registryId][recordId] = index;

        Record storage stored = _records[registryId][recordId][index];
        stored.uri = record.uri;
        stored.checksum = record.checksum;
        stored.checksumAlgo = record.checksumAlgo;
        stored.metadata = record.metadata;
        stored.timestamp = GoTime.format(block.timestamp);
        stored.status = record.status;
        stored.recordId = recordId;
        stored.index = index;
        stored.isLatest = true;
        stored.registryId = registryId;

        if (index > 1) {
            _records[registryId][recordId][index - 1].isLatest = false;
        }

        emit AddRecord(msg.sender, registryId, recordId, index, record.checksum);
    }

    /// @inheritdoc IAnchoring
    /// @dev `keeper.UpdateRecordStatus`, checked against the stored checksum so a record role
    ///      reaches every version.
    function updateRecordStatus(uint64 registryId, uint64 recordId, uint64 index, string calldata status) external {
        _ensureEoaCaller();

        // `MsgUpdateRecordStatus.ValidateBasic`'s order, which decides the error a caller sees.
        require(recordId != 0, "record ID cannot be zero");
        _validateStatus(status);
        require(registryId != 0, "registry ID cannot be zero");
        require(index != 0, "index cannot be zero");

        Record storage stored = _records[registryId][recordId][index];
        require(stored.index != 0, "record does not exist");
        _checkPermission(msg.sender, registryId, stored.checksum);
        stored.status = status;

        emit UpdateRecordStatus(msg.sender, registryId, recordId, index, status);
    }

    /// @inheritdoc IAnchoring
    /// @dev `msgServer.GrantRole`. A checksum scopes the role to that record; either way the
    ///      registry's admin role administers it. The module admin skips the EOA gate: on the old
    ///      chain it granted through `MsgGrantRole`, which had none, and here it is a contract.
    function grantRole(uint64 registryId, string calldata checksum, address account, string calldata role) external {
        if (msg.sender != _moduleAdmin) _ensureEoaCaller();
        _validateRoleRequest(registryId, checksum, role);
        bool recordScoped = _ensureRoleScopeExists(registryId, checksum);

        bytes32 role_ = _scopedRole(registryId, checksum, role, recordScoped);
        _setRoleAdmin(role_, Roles.forRegistry(registryId, Roles.ADMIN));

        // Break-glass: the module admin may seed a registry admin, and nothing else.
        if (!recordScoped && _isAdmin(role) && msg.sender == _moduleAdmin) {
            _grantRoleUnchecked(role_, account);
        } else {
            _grantRole(role_, account, msg.sender);
        }

        emit GrantRole(msg.sender, registryId, checksum, account, role);
    }

    /// @inheritdoc IAnchoring
    /// @dev `msgServer.RevokeRole`, with its checks in the module's order.
    function revokeRole(uint64 registryId, string calldata checksum, address account, string calldata role) external {
        _ensureEoaCaller();
        // The precompile checks the role before `ValidateBasic`, so a caller sees it first.
        require(bytes(role).length != 0, "role cannot be empty");
        _validateRoleRequest(registryId, checksum, role);
        bool recordScoped = _ensureRoleScopeExists(registryId, checksum);

        bytes32 role_ = _scopedRole(registryId, checksum, role, recordScoped);
        require(hasRole(role_, account), "address does not have the specified role");

        // A registry without an admin could never be administered again.
        if (!recordScoped && _isAdmin(role)) {
            require(!_isSoleAdmin(Roles.forRegistry(registryId, Roles.ADMIN)), "cannot revoke the last registry admin");
        }

        _revokeRole(role_, account, msg.sender);

        emit RevokeRole(msg.sender, registryId, checksum, account, role);
    }

    // ---- queries ----

    /// @inheritdoc IAnchoring
    /// @dev `queryServer.Records`: its five shapes, in its order. Record ids are `1..count`, so
    ///      a page skips by arithmetic rather than by walking.
    function records(
        uint64 registryId,
        string calldata checksum,
        uint64 recordId,
        uint64 index,
        PageRequest calldata pagination
    ) external view returns (Record[] memory recordsOut, PageResponse memory paginationOut) {
        require(recordId == 0 || registryId != 0, "record_id requires registry_id");
        require(
            index == 0 || (registryId != 0 && (recordId != 0 || bytes(checksum).length != 0)),
            "index requires registry_id and either record_id or checksum"
        );

        if (recordId == 0 && registryId != 0 && bytes(checksum).length != 0) {
            recordId = _recordIdByChecksum[registryId][checksum];
            require(recordId != 0, "record does not exist");
        }

        if (registryId != 0 && recordId != 0) {
            uint64 at = index;
            if (at == 0) {
                at = _latestIndex[registryId][recordId];
                require(at != 0, "record does not exist");
            }
            recordsOut = new Record[](1);
            recordsOut[0] = _load(registryId, recordId, at);
            return (recordsOut, paginationOut);
        }

        (uint64 offset, uint64 limit) = _page(pagination);

        if (registryId != 0) {
            return (_pageOfRegistry(registryId, offset, limit), paginationOut);
        }
        if (bytes(checksum).length != 0) {
            return (_pageOfChecksum(checksum, offset, limit), paginationOut);
        }
        return (_pageOfEverything(offset, limit), paginationOut);
    }

    /// @inheritdoc IAnchoring
    /// @dev `queryServer.Registries`, paged by `query.CollectionPaginate`: the one real cursor
    ///      (the next id, 8 bytes big-endian), and the one page that honours `reverse`.
    function registries(uint64 registryId, PageRequest calldata pagination)
        external
        view
        returns (Registry[] memory registriesOut, PageResponse memory paginationOut)
    {
        if (registryId != 0) {
            require(_registries[registryId].id != 0, "registry does not exist");
            registriesOut = new Registry[](1);
            registriesOut[0] = _registries[registryId];
            return (registriesOut, paginationOut);
        }

        (uint64 offset, uint64 limit) = _page(pagination);
        require(
            offset == 0 || pagination.key.length == 0, "invalid request, either offset or key is expected, got both"
        );

        uint64 total = _registryCount;
        bool reverse = pagination.reverse;

        uint64 start;
        if (pagination.key.length != 0) {
            start = _decodeCursor(pagination.key);
        } else {
            if (offset >= total) return (new Registry[](0), paginationOut);
            start = reverse ? total - offset : offset + 1;
        }
        if (start == 0 || start > total) return (new Registry[](0), paginationOut);

        uint64 available = reverse ? start : total - start + 1;
        uint64 n = available < limit ? available : limit;

        registriesOut = new Registry[](n);
        for (uint64 i = 0; i < n; i++) {
            registriesOut[i] = _registries[reverse ? start - i : start + i];
        }
        if (available > n) {
            paginationOut.nextKey = abi.encodePacked(reverse ? start - n : start + n);
        }
    }

    /// @inheritdoc IAnchoring
    function registriesByName(string calldata name, uint8 matchMode, PageRequest calldata pagination)
        external
        view
        returns (Registry[] memory registriesOut, PageResponse memory paginationOut)
    {
        require(matchMode <= MATCH_MAX, "invalid matchMode: want 0/1 exact, 2 prefix, 3 suffix, 4 contains");
        require(matchMode <= MATCH_EXACT, "only exact match is on chain; search prefix/suffix/contains off chain");
        // `SearchRegistriesByName` checks the mode first too. An empty name is a mistake, not
        // an empty page.
        require(bytes(name).length != 0, "name must be provided");

        (uint64 offset, uint64 limit) = _page(pagination);
        uint64[] storage ids = _registriesByName[_lower(name)];
        uint256 n = _window(ids.length, offset, limit);

        registriesOut = new Registry[](n);
        for (uint256 i = 0; i < n; i++) {
            registriesOut[i] = _registries[ids[offset + i]];
        }
    }

    // ---- gates and validation ----

    /// `Precompile.ensureEOACaller`, kept as it was: whether a contract may anchor on a user's
    /// behalf is not this port's to decide.
    function _ensureEoaCaller() private view {
        require(msg.sender == tx.origin, "sender not an eoa");

        address sender = msg.sender;
        uint256 size;
        assembly ("memory-safe") {
            size := extcodesize(sender)
        }
        if (size == 0) return;

        // `isEOACode` also admits an EIP-7702 delegation: 0xef0100 and the delegate's address.
        require(size == 23, "sender not an eoa");
        bytes memory code = sender.code;
        require(uint8(code[0]) == 0xef && uint8(code[1]) == 0x01 && uint8(code[2]) == 0x00, "sender not an eoa");
    }

    /// `types.ValidateRecordForCreate`.
    function _validateRecordForCreate(Record calldata record) private pure {
        require(bytes(record.checksum).length != 0, "checksum cannot be empty");
        require(bytes(record.checksumAlgo).length != 0, "checksum algorithm cannot be empty");
        require(bytes(record.uri).length != 0, "uri cannot be empty");
        // The module rejects "{}" as empty metadata too.
        require(
            bytes(record.metadata).length != 0 && keccak256(bytes(record.metadata)) != keccak256("{}"),
            "metadata cannot be empty"
        );
        require(record.registryId != 0, "registry ID cannot be zero");

        require(bytes(record.checksum).length <= MAX_CHECKSUM, "checksum exceeds max length");
        require(bytes(record.checksumAlgo).length <= MAX_CHECKSUM_ALGO, "checksum algorithm exceeds max length");
        require(bytes(record.uri).length <= MAX_URI, "uri exceeds max length");
        require(bytes(record.metadata).length <= MAX_METADATA, "metadata exceeds max length");
        _validateStatus(record.status);
    }

    /// `types.ValidateRecordStatus`.
    function _validateStatus(string calldata status) private pure {
        require(bytes(status).length != 0, "status cannot be empty");
        require(bytes(status).length <= MAX_STATUS, "status exceeds max length");
    }

    /// `MsgGrantRole`/`MsgRevokeRole.ValidateBasic`, in their order.
    function _validateRoleRequest(uint64 registryId, string calldata checksum, string calldata role) private pure {
        require(registryId != 0, "registry ID cannot be zero");
        require(bytes(checksum).length <= MAX_CHECKSUM, "checksum exceeds max length");
        require(bytes(role).length != 0, "role cannot be empty");
    }

    /// `msgServer.ensureRoleScopeExists`, returning whether the role is record-scoped.
    function _ensureRoleScopeExists(uint64 registryId, string calldata checksum)
        private
        view
        returns (bool recordScoped)
    {
        require(_registries[registryId].id != 0, "registry does not exist");
        recordScoped = _isRecordScoped(registryId, checksum);
        if (recordScoped) {
            require(_recordIdByChecksum[registryId][checksum] != 0, "record does not exist in registry");
        }
    }

    /// `keeper.checkPermission`: the record's roles, then the registry's. Each pair is derived
    /// at once, since this runs on every write.
    function _checkPermission(address sender, uint64 registryId, string memory checksum) private view {
        if (bytes(checksum).length != 0) {
            (bytes32 recordAdmin, bytes32 recordEditor) = Roles.bothForRecord(registryId, checksum);
            if (hasRole(recordAdmin, sender)) return;
            if (hasRole(recordEditor, sender)) return;
        }
        (bytes32 admin, bytes32 editor) = Roles.bothForRegistry(registryId);
        if (hasRole(admin, sender)) return;
        if (hasRole(editor, sender)) return;
        revert("unauthorized");
    }

    /// `msgServer.isRecordRole`.
    function _isRecordScoped(uint64 registryId, string calldata checksum) private pure returns (bool) {
        return registryId != 0 && bytes(checksum).length != 0;
    }

    /// `msgServer.scopedRole`.
    function _scopedRole(uint64 registryId, string calldata checksum, string calldata role, bool recordScoped)
        private
        pure
        returns (bytes32)
    {
        return recordScoped ? Roles.forRecord(registryId, checksum, role) : Roles.forRegistry(registryId, role);
    }

    function _isAdmin(string calldata role) private pure returns (bool) {
        return keccak256(bytes(role)) == keccak256(bytes(Roles.ADMIN));
    }

    /// Folds `A`-`Z` and leaves every other byte. The node used Go's `strings.ToLower`, which
    /// folds Unicode, so a capital from another script is the one spelling that differs.
    function _lower(string calldata s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c >= 0x41 && c <= 0x5a) b[i] = bytes1(c + 32);
        }
        return string(b);
    }

    // ---- paging ----

    /// `queryServer.sanitizePageRequest`. `countTotal` is ignored, as there.
    function _page(PageRequest calldata pagination) private pure returns (uint64 offset, uint64 limit) {
        offset = pagination.offset;
        limit = pagination.limit == 0 ? DEFAULT_PAGE_LIMIT : pagination.limit;
        if (limit > MAX_PAGE_LIMIT) limit = MAX_PAGE_LIMIT;
    }

    /// The SDK's cursor for a `uint64` key: 8 bytes, big-endian.
    function _decodeCursor(bytes calldata key) private pure returns (uint64) {
        require(key.length == 8, "invalid pagination key");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(bytes8(key));
    }

    /// Rows left after `offset`, capped at `limit`; zero past the end.
    function _window(uint256 total, uint64 offset, uint64 limit) private pure returns (uint256 n) {
        if (offset >= total) return 0;
        n = total - offset;
        if (n > limit) n = limit;
    }

    /// The newest version of each record in one registry.
    function _pageOfRegistry(uint64 registryId, uint64 offset, uint64 limit)
        private
        view
        returns (Record[] memory out)
    {
        uint256 n = _window(_recordCount[registryId], offset, limit);

        out = new Record[](n);
        for (uint256 i = 0; i < n; i++) {
            uint64 recordId = offset + uint64(i) + 1;
            out[i] = _load(registryId, recordId, _latestIndex[registryId][recordId]);
        }
    }

    /// The newest version of one checksum's record, in each registry that has it.
    function _pageOfChecksum(string calldata checksum, uint64 offset, uint64 limit)
        private
        view
        returns (Record[] memory out)
    {
        uint64[] storage ids = _registriesByChecksum[checksum];
        uint256 n = _window(ids.length, offset, limit);

        out = new Record[](n);
        for (uint256 i = 0; i < n; i++) {
            uint64 registryId = ids[offset + i];
            uint64 recordId = _recordIdByChecksum[registryId][checksum];
            out[i] = _load(registryId, recordId, _latestIndex[registryId][recordId]);
        }
    }

    /// The newest version of every record, registry by registry.
    function _pageOfEverything(uint64 offset, uint64 limit) private view returns (Record[] memory out) {
        uint64 registryCount = _registryCount;

        // Skip whole registries to the one the offset lands in.
        uint64 registryId = 1;
        uint64 skip = offset;
        while (registryId <= registryCount) {
            uint64 count = _recordCount[registryId];
            if (skip < count) break;
            skip -= count;
            registryId++;
        }

        // Sized to the limit and trimmed after, which is cheaper than counting first.
        out = new Record[](limit);
        uint64 n = 0;
        while (registryId <= registryCount && n < limit) {
            uint64 count = _recordCount[registryId];
            for (uint64 recordId = skip + 1; recordId <= count && n < limit; recordId++) {
                out[n++] = _load(registryId, recordId, _latestIndex[registryId][recordId]);
            }
            skip = 0;
            registryId++;
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    /// Keeps the list ascending, the order of the module's prefix scan. A seed appends in
    /// order, so this is usually one comparison.
    function _addRegistryForChecksum(string calldata checksum, uint64 registryId) private {
        uint64[] storage ids = _registriesByChecksum[checksum];
        ids.push(registryId);
        uint256 i = ids.length - 1;
        while (i > 0 && ids[i - 1] > registryId) {
            ids[i] = ids[i - 1];
            i--;
        }
        ids[i] = registryId;
    }

    function _load(uint64 registryId, uint64 recordId, uint64 index) private view returns (Record memory) {
        Record storage record = _records[registryId][recordId][index];
        require(record.index != 0, "record does not exist");
        return record;
    }
}
