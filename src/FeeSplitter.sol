// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Tempo's fee manager precompile.
interface IFeeManager {
    /// @notice Pays `validator` the fees credited to it in `token`. Permissionless.
    function distributeFees(address validator, address token) external;
}

/// @title FeeSplitter
/// @notice Every validator's fee recipient. `split` pays devshare and buybacks their cuts and holds the
///         validators' share, in equal parts per operator, until the owner commences distribution.
/// @dev Genesis may name its address before it is deployed: the first split covers every fee since. As
///      every block's beneficiary it can never set a validator token, so FeeManager pays it in nUSD.
contract FeeSplitter is Ownable {
    address private constant FEE_MANAGER = 0xfeEC000000000000000000000000000000000000;
    uint256 private constant BPS = 10_000;
    /// @dev The whitepaper's floor on the buyback share.
    uint256 private constant MIN_BUYBACK_BPS = 2_000;

    address public immutable devshare;
    address public immutable buyback;
    uint256 public immutable devshareBps;
    uint256 public immutable buybackBps;

    /// @notice Each operator's payout address, which only its holder can move.
    address[] public operators;
    bool public commenced;
    /// @notice token => what every split so far has given each operator.
    mapping(address => uint256) public perOperator;
    /// @notice token => operator index => how much of `perOperator` it has been paid.
    mapping(address => mapping(uint256 => uint256)) public paid;
    /// @notice token => the validators' share not yet paid, which a split leaves alone.
    mapping(address => uint256) public held;

    event Split(address indexed token, uint256 devshare, uint256 buyback, uint256 validators);
    event Commenced();
    event Claimed(address indexed token, uint256 indexed operator, address to, uint256 amount);
    event OperatorMoved(uint256 indexed operator, address from, address to);

    error ZeroAddress();
    error InvalidBps();
    error NoOperators();
    error NotCommenced();
    error AlreadyCommenced();
    error NotOperator();
    error Unrenounceable();

    constructor(
        address owner_,
        address devshare_,
        address buyback_,
        uint256 devshareBps_,
        uint256 buybackBps_,
        address[] memory operators_
    ) {
        if (owner_ == address(0) || devshare_ == address(0) || buyback_ == address(0)) {
            revert ZeroAddress();
        }
        if (devshareBps_ + buybackBps_ > BPS || buybackBps_ < MIN_BUYBACK_BPS) revert InvalidBps();
        if (operators_.length == 0) revert NoOperators();
        for (uint256 i; i < operators_.length; ++i) {
            if (operators_[i] == address(0)) revert ZeroAddress();
        }
        _initializeOwner(owner_);
        devshare = devshare_;
        buyback = buyback_;
        devshareBps = devshareBps_;
        buybackBps = buybackBps_;
        operators = operators_;
    }

    /// @notice Collect `token` fees from FeeManager and divide everything not yet held. Permissionless. A
    ///         remainder too small to divide among the operators waits for the next split.
    function split(address token) external returns (uint256 fresh) {
        IFeeManager(FEE_MANAGER).distributeFees(address(this), token);
        fresh = SafeTransferLib.balanceOf(token, address(this)) - held[token];
        uint256 dev = fresh * devshareBps / BPS;
        uint256 buy = fresh * buybackBps / BPS;
        uint256 n = operators.length;
        uint256 each = (fresh - dev - buy) / n;
        perOperator[token] += each;
        held[token] += each * n;
        SafeTransferLib.safeTransfer(token, devshare, dev);
        SafeTransferLib.safeTransfer(token, buyback, buy);
        emit Split(token, dev, buy, each * n);
    }

    /// @notice Release the validators' share, for good.
    function commence() external onlyOwner {
        if (commenced) revert AlreadyCommenced();
        commenced = true;
        emit Commenced();
    }

    /// @notice Pay operator `i` what is held for it in `token`. Permissionless once commenced.
    function claim(address token, uint256 i) external returns (uint256 amount) {
        if (!commenced) revert NotCommenced();
        address to = operators[i];
        amount = owed(token, i);
        paid[token][i] = perOperator[token];
        held[token] -= amount;
        SafeTransferLib.safeTransfer(token, to, amount);
        emit Claimed(token, i, to, amount);
    }

    /// @notice Move operator `i`'s payout to `to`; only its current address may.
    function moveOperator(uint256 i, address to) external {
        if (msg.sender != operators[i]) revert NotOperator();
        if (to == address(0)) revert ZeroAddress();
        operators[i] = to;
        emit OperatorMoved(i, msg.sender, to);
    }

    /// @notice The validators' share held for operator `i` in `token`.
    function owed(address token, uint256 i) public view returns (uint256) {
        operators[i]; // past the last operator, reverts as `claim` does
        return perOperator[token] - paid[token][i];
    }

    /// @dev With no owner the validators' share could never be released.
    function renounceOwnership() public payable override onlyOwner {
        revert Unrenounceable();
    }
}
