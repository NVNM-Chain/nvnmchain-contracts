// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IValidatorConfigV2} from "./interfaces/IValidatorConfigV2.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title FeeLockbox
/// @notice Holds the validator share of network fees per operator until distribution commences:
///         non-affiliated validators must exceed half the active set, and a majority of that set
///         must vote for it. No operator, affiliated or not, is paid before then.
/// @dev The owner declares who is affiliated and cannot undeclare it. The set is read from the
///      registry at each count, so a removed validator's vote stops counting. Commencement is
///      permanent.
contract FeeLockbox is Ownable, ReentrancyGuard {
    IValidatorConfigV2 public constant REGISTRY = IValidatorConfigV2(0xCcCCCCcC00000000000000000000000000000001);

    bool public commenced;
    mapping(address => bool) public affiliated; // validator => affiliated with the founding parties
    mapping(address => bool) public voted; // validator => votes to commence
    mapping(address => mapping(address => uint256)) public owed; // token => operator => deferred

    event Deposited(address indexed token, address indexed operator, uint256 amount);
    event Paid(address indexed token, address indexed operator, uint256 amount);
    event Affiliated(address indexed validator);
    event Voted(address indexed validator, bool support);
    event Commenced(uint256 active, uint256 affiliatedCount, uint256 votes);

    error ZeroAddress();
    error NotCommenced();
    error AlreadyCommenced();
    error NotValidator();
    error MajorityAffiliated();
    error VoteShort();

    constructor(address owner_) {
        _initializeOwner(owner_);
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

    function _isActive(address who) private view returns (bool) {
        IValidatorConfigV2.Validator[] memory set = REGISTRY.getActiveValidators();
        for (uint256 i; i < set.length; ++i) {
            if (set[i].validatorAddress == who) return true;
        }
        return false;
    }
}
