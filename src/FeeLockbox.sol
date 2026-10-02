// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BPS} from "./Constants.sol";
import {IValidatorConfigV2} from "./interfaces/IValidatorConfigV2.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title FeeLockbox
/// @notice Holds the validator share of network fees per operator until distribution commences:
///         non-affiliated validators must exceed half the active set, and a majority of that set
///         must vote for it. No operator, affiliated or not, is paid before then. Also holds the
///         fee split, which that set votes proposal by proposal: one applies after `splitDelay`
///         while a majority backs it, and before commencement may neither raise devshare nor cut
///         the validator share.
/// @dev The owner declares who is affiliated and cannot undeclare it. The set is read from the
///      registry at each count, so a removed validator's vote stops counting. Commencement is
///      permanent.
contract FeeLockbox is Ownable, ReentrancyGuard {
    IValidatorConfigV2 public constant REGISTRY = IValidatorConfigV2(0xCcCCCCcC00000000000000000000000000000001);
    /// @notice The least share of gross fees the buyback cut may take.
    uint256 public constant MIN_BUYBACK_BPS = 2_000;

    /// @dev A proposed split, voted on its own: a vote never carries over to a later proposal.
    struct Split {
        uint16 devBps;
        uint16 buyBps;
        uint64 proposedAt;
        bool applied;
    }

    uint256 public immutable splitDelay; // how long a proposal is public before it may apply
    uint128 public devshareBps;
    uint128 public buybackBps;
    Split[] public splits;
    mapping(uint256 => mapping(address => bool)) public splitVotes; // proposal => validator => backs

    bool public commenced;
    mapping(address => bool) public affiliated; // validator => affiliated with the founding parties
    mapping(address => bool) public voted; // validator => votes to commence
    mapping(address => mapping(address => uint256)) public owed; // token => operator => deferred

    event Deposited(address indexed token, address indexed operator, uint256 amount);
    event Paid(address indexed token, address indexed operator, uint256 amount);
    event Affiliated(address indexed validator);
    event Voted(address indexed validator, bool support);
    event Commenced(uint256 active, uint256 affiliatedCount, uint256 votes);
    event SplitProposed(uint256 indexed id, address indexed validator, uint256 devBps, uint256 buyBps);
    event SplitVoted(uint256 indexed id, address indexed validator, bool support);
    event SplitApplied(uint256 indexed id, uint256 devBps, uint256 buyBps);

    error ZeroAddress();
    error NotCommenced();
    error AlreadyCommenced();
    error NotValidator();
    error MajorityAffiliated();
    error VoteShort();
    error InvalidBps();
    error BuybackBelowFloor();
    error NoSuchSplit();
    error SplitPending();
    error AlreadyApplied();
    error DevshareRaised();
    error ValidatorShareCut();
    error ZeroDelay();

    constructor(address owner_, uint256 devshareBps_, uint256 buybackBps_, uint256 splitDelay_) {
        _initializeOwner(owner_);
        _checkSplit(devshareBps_, buybackBps_);
        if (splitDelay_ == 0) revert ZeroDelay();
        devshareBps = uint128(devshareBps_);
        buybackBps = uint128(buybackBps_);
        splitDelay = splitDelay_;
    }

    /// @notice Pull `amount` of `token` for `operator`, held until commencement. After it, routers
    ///         pay operators directly.
    function deposit(address token, address operator, uint256 amount) external nonReentrant {
        if (operator == address(0)) revert ZeroAddress();
        if (commenced) revert AlreadyCommenced();
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        owed[token][operator] += amount;
        emit Deposited(token, operator, amount);
    }

    /// @notice Pay `operator` what it was owed in `token` before commencement. Permissionless.
    function claim(address token, address operator) external nonReentrant returns (uint256 amount) {
        if (!commenced) revert NotCommenced();
        amount = owed[token][operator];
        if (amount == 0) return 0;
        owed[token][operator] = 0;
        SafeTransferLib.safeTransfer(token, operator, amount);
        emit Paid(token, operator, amount);
    }

    /// @notice Declare `validator` affiliated with the founding parties. There is no undeclaring.
    function setAffiliated(address validator) external onlyOwner {
        if (validator == address(0)) revert ZeroAddress();
        affiliated[validator] = true;
        emit Affiliated(validator);
    }

    /// @notice An active validator's vote to commence distribution.
    function vote(bool support) external {
        if (!_isActive(msg.sender)) revert NotValidator();
        voted[msg.sender] = support;
        emit Voted(msg.sender, support);
    }

    /// @notice Start distribution once both conditions hold. Permissionless.
    function commence() external {
        if (commenced) revert AlreadyCommenced();
        (uint256 active, uint256 affiliatedCount, uint256 votes) = composition();
        if ((active - affiliatedCount) * 2 <= active) revert MajorityAffiliated();
        if (votes * 2 <= active) revert VoteShort();
        commenced = true;
        emit Commenced(active, affiliatedCount, votes);
    }

    /// @notice The active set's size, and how many of it are affiliated and have voted to commence.
    function composition() public view returns (uint256 active, uint256 affiliatedCount, uint256 votes) {
        IValidatorConfigV2.Validator[] memory set = REGISTRY.getActiveValidators();
        active = set.length;
        for (uint256 i; i < active; ++i) {
            address v = set[i].validatorAddress;
            if (affiliated[v]) ++affiliatedCount;
            if (voted[v]) ++votes;
        }
    }

    // -- the fee split -------------------------------------------------------
    /// @notice Propose a split, as an active validator, who thereby backs it.
    function proposeSplit(uint256 devBps, uint256 buyBps) external returns (uint256 id) {
        if (!_isActive(msg.sender)) revert NotValidator();
        _checkSplit(devBps, buyBps);
        id = splits.length;
        // Narrowed after `_checkSplit`: both ratios fit, and so does the timestamp.
        splits.push(
            Split({devBps: uint16(devBps), buyBps: uint16(buyBps), proposedAt: uint64(block.timestamp), applied: false})
        );
        splitVotes[id][msg.sender] = true;
        emit SplitProposed(id, msg.sender, devBps, buyBps);
    }

    /// @notice An active validator's vote on split proposal `id`.
    function voteSplit(uint256 id, bool support) external {
        if (!_isActive(msg.sender)) revert NotValidator();
        if (id >= splits.length) revert NoSuchSplit();
        splitVotes[id][msg.sender] = support;
        emit SplitVoted(id, msg.sender, support);
    }

    /// @notice Apply proposal `id` once it has been public for `splitDelay` and a majority of the
    ///         active set backs it. Permissionless.
    /// @dev Devshare does not wait on commencement, so until then a proposal may not raise it, nor
    ///      cut the validator share: either pays the founding parties while they hold the set.
    function applySplit(uint256 id) external {
        if (id >= splits.length) revert NoSuchSplit();
        Split memory s = splits[id];
        if (s.applied) revert AlreadyApplied();
        if (block.timestamp < s.proposedAt + splitDelay) revert SplitPending();
        (uint256 active, uint256 votes) = splitTally(id);
        if (votes * 2 <= active) revert VoteShort();
        (uint256 devBps, uint256 buyBps) = (s.devBps, s.buyBps);
        if (!commenced) {
            if (devBps > devshareBps) revert DevshareRaised();
            if (devBps + buyBps > uint256(devshareBps) + buybackBps) revert ValidatorShareCut();
        }
        splits[id].applied = true;
        devshareBps = uint128(devBps);
        buybackBps = uint128(buyBps);
        emit SplitApplied(id, devBps, buyBps);
    }

    /// @notice The active set's size, and how many of it back split proposal `id`.
    function splitTally(uint256 id) public view returns (uint256 active, uint256 votes) {
        IValidatorConfigV2.Validator[] memory set = REGISTRY.getActiveValidators();
        active = set.length;
        for (uint256 i; i < active; ++i) {
            if (splitVotes[id][set[i].validatorAddress]) ++votes;
        }
    }

    /// @notice The split in force, in one read.
    function split() external view returns (uint256 devBps, uint256 buyBps) {
        return (devshareBps, buybackBps);
    }

    function _checkSplit(uint256 devBps, uint256 buyBps) private pure {
        if (devBps + buyBps > BPS) revert InvalidBps();
        if (buyBps < MIN_BUYBACK_BPS) revert BuybackBelowFloor();
    }

    function _isActive(address who) private view returns (bool) {
        IValidatorConfigV2.Validator[] memory set = REGISTRY.getActiveValidators();
        for (uint256 i; i < set.length; ++i) {
            if (set[i].validatorAddress == who) return true;
        }
        return false;
    }
}
