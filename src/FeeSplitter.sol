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
/// @notice One validator's fee recipient. `split` pays devshare and buybacks their cuts and holds the rest
///         for the validator's operator until the owner commences distribution.
/// @dev Genesis may name its address before it is deployed: the first split covers every fee since.
contract FeeSplitter is Ownable {
    address private constant FEE_MANAGER = 0xfeEC000000000000000000000000000000000000;
    /// @dev As a block's beneficiary it can never set a validator token, so FeeManager pays it in nUSD
    ///      alone. Any other token sent here stays here.
    address private constant NUSD = 0x20C0000000000000000000000000000000000000;
    uint256 private constant BPS = 10_000;
    /// @dev The whitepaper's floor on the buyback share.
    uint256 private constant MIN_BUYBACK_BPS = 2_000;

    address public immutable devshare;
    address public immutable buyback;
    uint256 public immutable devshareBps;
    uint256 public immutable buybackBps;

    /// @notice The validator's payout address, which only its holder can move.
    address public operator;
    bool public commenced;
    /// @notice The validator's share not yet paid, which a split leaves alone.
    uint256 public held;

    event Split(uint256 devshare, uint256 buyback, uint256 validator);
    event Commenced();
    event Claimed(address to, uint256 amount);
    event OperatorMoved(address from, address to);

    error ZeroAddress();
    error InvalidBps();
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
        address operator_
    ) {
        if (owner_ == address(0) || devshare_ == address(0) || buyback_ == address(0) || operator_ == address(0)) {
            revert ZeroAddress();
        }
        if (devshareBps_ + buybackBps_ > BPS || buybackBps_ < MIN_BUYBACK_BPS) revert InvalidBps();
        _initializeOwner(owner_);
        devshare = devshare_;
        buyback = buyback_;
        devshareBps = devshareBps_;
        buybackBps = buybackBps_;
        operator = operator_;
    }

    /// @notice Collect fees from FeeManager and divide everything not yet held. Permissionless.
    function split() public returns (uint256 fresh) {
        IFeeManager(FEE_MANAGER).distributeFees(address(this), NUSD);
        fresh = SafeTransferLib.balanceOf(NUSD, address(this)) - held;
        uint256 dev = fresh * devshareBps / BPS;
        uint256 buy = fresh * buybackBps / BPS;
        uint256 kept = fresh - dev - buy;
        held += kept;
        SafeTransferLib.safeTransfer(NUSD, devshare, dev);
        SafeTransferLib.safeTransfer(NUSD, buyback, buy);
        emit Split(dev, buy, kept);
    }

    /// @notice Release the validator's share, for good.
    function commence() external onlyOwner {
        if (commenced) revert AlreadyCommenced();
        commenced = true;
        emit Commenced();
    }

    /// @notice Split, then pay the operator everything held. Permissionless once commenced.
    function claim() external returns (uint256 amount) {
        if (!commenced) revert NotCommenced();
        split();
        amount = held;
        held = 0;
        SafeTransferLib.safeTransfer(NUSD, operator, amount);
        emit Claimed(operator, amount);
    }

    /// @notice Move the payout to `to`; only the current operator may.
    function moveOperator(address to) external {
        if (msg.sender != operator) revert NotOperator();
        if (to == address(0)) revert ZeroAddress();
        operator = to;
        emit OperatorMoved(msg.sender, to);
    }

    /// @dev With no owner the validator's share could never be released.
    function renounceOwnership() public payable override onlyOwner {
        revert Unrenounceable();
    }
}
