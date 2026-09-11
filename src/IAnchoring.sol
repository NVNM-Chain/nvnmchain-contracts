// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

/// @title IAnchoring
/// @notice The x/anchoring precompile's interface, copied from `HumanABI` in the chain's
///         `x/anchoring/precompile/anchoring.go`. Any change to a type or its order moves a
///         selector; `test/Selectors.t.sol` pins them.
interface IAnchoring {
    /// @param timestamp The block time, set by the chain, in Go's `time.Time.String()` form.
    /// @param isLatest Whether this is the newest version of its checksum.
    struct Record {
        string uri;
        string checksum;
        string checksumAlgo;
        string metadata;
        string timestamp;
        string status;
        uint64 recordId;
        uint64 index;
        bool isLatest;
        uint64 registryId;
    }

    /// @param creator The creator's bech32 address.
    /// @param createdAt The block time, formatted like `Record.timestamp`.
    struct Registry {
        uint64 id;
        string name;
        string description;
        string creator;
        string createdAt;
        string metadata;
    }

    /// The Cosmos paging pair. `key`/`nextKey` are a KV cursor only `registries` uses.
    struct PageRequest {
        bytes key;
        uint64 offset;
        uint64 limit;
        bool countTotal;
        bool reverse;
    }

    struct PageResponse {
        bytes nextKey;
        uint64 total;
    }

    /// @dev Copied from `HumanABI` too: a changed signature moves topic0, and log filters
    ///      stop matching without an error.
    event AddRegistry(address indexed caller, uint64 registryId, string name);
    event AddRecord(address indexed caller, uint64 registryId, uint64 recordId, uint64 index, string checksum);
    event UpdateRecordStatus(address indexed caller, uint64 registryId, uint64 recordId, uint64 index, string status);
    event GrantRole(address indexed caller, uint64 registryId, string checksum, address account, string role);
    event RevokeRole(address indexed caller, uint64 registryId, string checksum, address account, string role);

    function addRegistry(string calldata name, string calldata description, string calldata metadata)
        external
        returns (uint64 registryId);

    function addRecord(Record calldata record) external returns (uint64 recordId);

    function updateRecordStatus(uint64 registryId, uint64 recordId, uint64 index, string calldata status) external;

    function records(
        uint64 registryId,
        string calldata checksum,
        uint64 recordId,
        uint64 index,
        PageRequest calldata pagination
    ) external view returns (Record[] memory recordsOut, PageResponse memory paginationOut);

    function registries(uint64 registryId, PageRequest calldata pagination)
        external
        view
        returns (Registry[] memory registriesOut, PageResponse memory paginationOut);

    /// @notice Exact match only: `matchMode` 0 or 1. Prefix (2), suffix (3) and contains (4)
    ///         were a node-local index; on chain they revert and stay an off-chain search.
    function registriesByName(string calldata name, uint8 matchMode, PageRequest calldata pagination)
        external
        view
        returns (Registry[] memory registriesOut, PageResponse memory paginationOut);

    function grantRole(uint64 registryId, string calldata checksum, address account, string calldata role) external;

    function revokeRole(uint64 registryId, string calldata checksum, address account, string calldata role) external;
}
