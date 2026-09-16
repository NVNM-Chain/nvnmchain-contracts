// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

/// @title ModuleAdminMultisig
/// @notice The chain's 2-of-3 module admin as a contract, so `Anchoring`'s break-glass grant has a
///         sender on Tempo: an amino multisig's address is a hash of the composite key, which no
///         single key derives, and an EVM sender is recovered from one signature.
/// @dev Placed by the genesis alloc, the owners in slots 0..2; nothing sets them afterwards. It
///      calls `Anchoring` and nothing else.
contract ModuleAdminMultisig {
    address[3] internal _owners;

    uint8 internal constant THRESHOLD = 2;
    address internal constant ANCHORING = 0x0000000000000000000000000000000000000A00;

    struct Proposal {
        bytes data;
        uint8 confirmations;
    }

    /// Ids count from 1. A proposal at the threshold has run.
    mapping(uint256 => Proposal) internal _proposals;
    mapping(uint256 => mapping(address => bool)) internal _confirmed;

    uint256 public proposalCount;

    event Proposed(uint256 indexed id, address indexed owner, bytes data);
    event Confirmed(uint256 indexed id, address indexed owner, uint8 confirmations);
    event Executed(uint256 indexed id, bytes returned);

    error NotAnOwner(address caller);
    error NoSuchProposal(uint256 id);
    error AlreadyConfirmed(uint256 id, address owner);
    error AlreadyExecuted(uint256 id);
    error CallReverted(bytes returned);

    modifier onlyOwner() {
        _requireOwner();
        _;
    }

    /// The zero address is never an owner, so an unset slot admits nobody.
    function _requireOwner() private view {
        address caller = msg.sender;
        if (caller == address(0) || (caller != _owners[0] && caller != _owners[1] && caller != _owners[2])) {
            revert NotAnOwner(caller);
        }
    }

    /// @notice Propose a call to `Anchoring`, confirmed by the proposer.
    function propose(bytes calldata data) external onlyOwner returns (uint256 id) {
        id = ++proposalCount;
        _proposals[id] = Proposal({data: data, confirmations: 1});
        _confirmed[id][msg.sender] = true;
        emit Proposed(id, msg.sender, data);
        emit Confirmed(id, msg.sender, 1);
    }

    /// @notice Confirm proposal `id`, running it once the threshold is met. A call that reverts
    ///         reverts the confirmation with it.
    function confirm(uint256 id) external onlyOwner {
        if (id == 0 || id > proposalCount) revert NoSuchProposal(id);
        Proposal storage p = _proposals[id];
        if (p.confirmations >= THRESHOLD) revert AlreadyExecuted(id);
        if (_confirmed[id][msg.sender]) revert AlreadyConfirmed(id, msg.sender);

        _confirmed[id][msg.sender] = true;
        p.confirmations += 1;
        emit Confirmed(id, msg.sender, p.confirmations);

        if (p.confirmations >= THRESHOLD) {
            (bool ok, bytes memory returned) = ANCHORING.call(p.data);
            if (!ok) revert CallReverted(returned);
            emit Executed(id, returned);
        }
    }

    function confirmed(uint256 id, address owner) external view returns (bool) {
        return _confirmed[id][owner];
    }

    function proposal(uint256 id) external view returns (bytes memory data, uint8 confirmations, bool executed) {
        Proposal storage p = _proposals[id];
        return (p.data, p.confirmations, p.confirmations >= THRESHOLD);
    }

    function owners() external view returns (address[3] memory, uint8) {
        return (_owners, THRESHOLD);
    }
}
