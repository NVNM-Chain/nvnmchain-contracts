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
/// @dev Genesis may name its address before it is deployed: the first split covers every fee since.
contract FeeSplitter is Ownable {
    address private constant FEE_MANAGER = 0xfeEC000000000000000000000000000000000000;
    /// @dev As every block's beneficiary it can never set a validator token, so FeeManager pays it in
    ///      nUSD alone. Any other token sent here stays here.
    address private constant NUSD = 0x20C0000000000000000000000000000000000000;
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
    /// @notice What every split so far has given each operator.
    uint256 public perOperator;
    /// @notice Operator index => how much of `perOperator` it has been paid.
    mapping(uint256 => uint256) public paid;
    /// @notice The validators' share not yet paid, which a split leaves alone.
    uint256 public held;

    event Split(uint256 devshare, uint256 buyback, uint256 validators);
    event Commenced();
    event Claimed(uint256 indexed operator, address to, uint256 amount);
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

    /// @notice Collect fees from FeeManager and divide everything not yet held. Permissionless. A
    ///         remainder too small to divide among the operators waits for the next split.
    function split() public returns (uint256 fresh) {
        IFeeManager(FEE_MANAGER).distributeFees(address(this), NUSD);
        fresh = SafeTransferLib.balanceOf(NUSD, address(this)) - held;
        uint256 dev = fresh * devshareBps / BPS;
        uint256 buy = fresh * buybackBps / BPS;
        uint256 n = operators.length;
        uint256 each = (fresh - dev - buy) / n;
        perOperator += each;
        held += each * n;
        SafeTransferLib.safeTransfer(NUSD, devshare, dev);
        SafeTransferLib.safeTransfer(NUSD, buyback, buy);
        emit Split(dev, buy, each * n);
    }

    /// @notice Release the validators' share, for good.
    function commence() external onlyOwner {
        if (commenced) revert AlreadyCommenced();
        commenced = true;
        emit Commenced();
    }

    /// @notice Split, then pay operator `i` what is held for it. Permissionless once commenced.
    function claim(uint256 i) external returns (uint256 amount) {
        if (!commenced) revert NotCommenced();
        address to = operators[i];
        split();
        amount = owed(i);
        paid[i] = perOperator;
        held -= amount;
        SafeTransferLib.safeTransfer(NUSD, to, amount);
        emit Claimed(i, to, amount);
    }

    /// @notice Move operator `i`'s payout to `to`; only its current address may.
    function moveOperator(uint256 i, address to) external {
        if (msg.sender != operators[i]) revert NotOperator();
        if (to == address(0)) revert ZeroAddress();
        operators[i] = to;
        emit OperatorMoved(i, msg.sender, to);
    }

    /// @notice The validators' share held for operator `i`.
    function owed(uint256 i) public view returns (uint256) {
        operators[i]; // past the last operator, reverts as `claim` does
        return perOperator - paid[i];
    }

    /// @dev With no owner the validators' share could never be released.
    function renounceOwnership() public payable override onlyOwner {
        revert Unrenounceable();
    }
}
