// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

/// @title ModuleAdminMultisig
/// @notice The chain's 2-of-3 module admin as a contract, so `Anchoring`'s break-glass grant has a
///         sender on Tempo: an amino multisig's address is a hash of the composite key, which no
///         single key derives, and an EVM sender is recovered from one signature.
/// @dev Placed by the genesis alloc, the owners in slots 0..2. Two of them rotate the three, as
///      the old chain's `MsgUpdateParams` let its members do; the authority genesis names in
///      `_recovery` replaces them outright, for when too few keys are left to reach two. It calls
///      `Anchoring` and nothing else.
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

    /// The count at the last `recover`: everything older is dead, confirmations included.
    uint256 internal _recoveredAt;

    /// Who may `recover`, from the genesis alloc. Genesis is the only writer — a boundary
    /// installs code and never storage — so a chain that launched without one has only rotation.
    address internal _recovery;

    /// The owners a proposal would install, if it is a rotation rather than a call.
    mapping(uint256 => address[3]) internal _rotations;

    event Proposed(uint256 indexed id, address indexed owner, bytes data);
    event Confirmed(uint256 indexed id, address indexed owner, uint8 confirmations);
    event Executed(uint256 indexed id, bytes returned);
    event Recovered(address[3] owners);
    event Rotated(uint256 indexed id, address[3] owners);

    error NotAnOwner(address caller);
    error NotRecoveryAuthority(address caller);
    error BadOwner(address owner);
    error NoSuchProposal(uint256 id);
    error AlreadyConfirmed(uint256 id, address owner);
    error AlreadyExecuted(uint256 id);
    error Superseded(uint256 id);
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
        if (id <= _recoveredAt) revert Superseded(id);
        Proposal storage p = _proposals[id];
        if (p.confirmations >= THRESHOLD) revert AlreadyExecuted(id);
        if (_confirmed[id][msg.sender]) revert AlreadyConfirmed(id, msg.sender);

        _confirmed[id][msg.sender] = true;
        p.confirmations += 1;
        emit Confirmed(id, msg.sender, p.confirmations);

        if (p.confirmations >= THRESHOLD) {
            address[3] memory rotation = _rotations[id];
            if (rotation[0] != address(0)) {
                _install(rotation);
                emit Rotated(id, rotation);
                return;
            }
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

    /// @notice Who may `recover`, from genesis. Zero where none was named, which leaves rotation
    ///         as the only way the owners change.
    function recoveryAuthority() public view returns (address) {
        return _recovery;
    }

    /// @notice Propose the owners to install, which two of the three then confirm. This is what
    ///         the old chain's `MsgUpdateParams` did, and it needs no authority above this one.
    function proposeRotation(address[3] calldata newOwners) external onlyOwner returns (uint256 id) {
        _requireDistinct(newOwners);
        id = ++proposalCount;
        _proposals[id] = Proposal({data: "", confirmations: 1});
        _rotations[id] = newOwners;
        _confirmed[id][msg.sender] = true;
        emit Proposed(id, msg.sender, "");
        emit Confirmed(id, msg.sender, 1);
    }

    /// @notice Replace the owners outright, for when too few keys are left to reach two. Only the
    ///         authority genesis named may call it, and a chain that named none has no such call.
    function recover(address[3] calldata newOwners) external {
        address authority = _recovery;
        if (authority == address(0) || msg.sender != authority) revert NotRecoveryAuthority(msg.sender);
        _requireDistinct(newOwners);
        _install(newOwners);
        emit Recovered(newOwners);
    }

    /// Owners take effect together with the count that kills every proposal raised before them: a
    /// confirmation from an owner on the way out must not carry one to the threshold.
    function _install(address[3] memory newOwners) private {
        _owners = newOwners;
        _recoveredAt = proposalCount;
    }

    /// Zero admits nobody and a repeat puts the threshold out of reach, since an owner cannot
    /// confirm twice.
    function _requireDistinct(address[3] calldata newOwners) private pure {
        for (uint256 i = 0; i < 3; i++) {
            address owner = newOwners[i];
            if (owner == address(0)) revert BadOwner(owner);
            for (uint256 j = 0; j < i; j++) {
                if (owner == newOwners[j]) revert BadOwner(owner);
            }
        }
    }
}
