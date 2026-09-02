// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { BPS } from "./Constants.sol";
import { INVNMStaking } from "./interfaces/INVNMStaking.sol";
import { ISwapper } from "./interfaces/ISwapper.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

/// @title FeeRouter
/// @notice Per-validator fee splitter, paid by `FeeManager.distributeFees`. `flush` is
///         permissionless: it applies the factory's protocol cuts (devshare + buybacks) to one
///         fee token and splits the validator remainder into operator commission and delegator
///         rewards — so the delegator share comes out of the validator allocation, not off
///         the top. At `commissionBps = 10_000` (Phases 1–4) the whole remainder reaches the
///         operator, pool or no pool; below it (Phase 5) the rest is deposited to this
///         validator's pool.
/// @dev `flush` takes an arbitrary token, so it is guarded: a token contract is free to call
///      back in mid-transfer.
contract FeeRouter is ReentrancyGuard {
    address public immutable validator; // delegation / election key
    address public immutable operator; // receives the commission
    address public immutable staking;
    address public immutable factory;
    /// @dev Of the *validator remainder* after protocol cuts, not of the gross fee.
    uint256 public immutable commissionBps;

    /// @notice Per token, the delegators' share held back because the pool cannot account in
    ///         it. Kept out of the flushable balance: `flush` is permissionless, so leaving it
    ///         visible would let anyone cut it again on every call.
    mapping(address => uint256) public heldForDelegators;

    event Flushed(
        address indexed token,
        uint256 commission,
        uint256 devshare,
        uint256 buyback,
        uint256 compounded,
        uint256 deposited
    );
    event Swept(address indexed token, address indexed to, uint256 amount);
    /// @notice The buyback cut was forwarded as stablecoin because the swapper rejected it.
    event BuybackSwapFailed(address indexed swapper, uint256 amount);
    /// @notice A delegator share was added to `heldForDelegators` instead of being paid out.
    event DelegatorShareUnrouted(address indexed token, uint256 amount);

    error ZeroAddress();
    error InvalidBps();
    error NotFactoryOwner();

    constructor(
        address validator_,
        address operator_,
        address staking_,
        address factory_,
        uint256 commissionBps_
    ) {
        if (validator_ == address(0) || operator_ == address(0) || staking_ == address(0)) {
            revert ZeroAddress();
        }
        if (commissionBps_ > BPS) revert InvalidBps();
        validator = validator_;
        operator = operator_;
        staking = staking_;
        factory = factory_;
        commissionBps = commissionBps_;
    }

    /// @notice The staking pool's reward token. Read live, never cached: the pool is a UUPS
    ///         proxy, and a stale copy would silently misroute the delegator leg after a
    ///         reward-token migration.
    function rewardToken() public view returns (address) {
        return INVNMStaking(staking).rewardToken();
    }

    /// @notice The staking pool's stake token (the buyback target). Read live, like
    ///         `rewardToken`.
    function stakeToken() public view returns (address) {
        return INVNMStaking(staking).stakeToken();
    }

    /// @notice `flush` for the staking pool's reward token.
    function flush() external returns (uint256 deposited) {
        return flush(rewardToken());
    }

    /// @notice Apply protocol cuts to this router's `token` balance, then split the validator
    ///         remainder. With no stakers the delegator leg is paid to the operator (PoA).
    /// @dev `FeeManager` swaps every payer's fee into the recipient's own preferred token, so
    ///      in steady state a router holds exactly one: `flush()` covers it. This overload is
    ///      for everything else — a preferred token pointed somewhere other than the pool's
    ///      reward token, the residue of changing it, or a plain transfer in — so those are
    ///      routed by the same rules instead of stranded.
    function flush(address token) public nonReentrant returns (uint256 deposited) {
        address rTok = rewardToken();
        uint256 held = heldForDelegators[token];
        uint256 balance = SafeTransferLib.balanceOf(token, address(this));
        balance = balance > held ? balance - held : 0; // never re-cut the escrow
        if (balance == 0) return 0;

        (uint256 devAmt, uint256 buyAmt, uint256 compounded) = _protocolCuts(token, balance, rTok);
        uint256 remainder = balance - devAmt - buyAmt;

        uint256 commission = (remainder * commissionBps) / BPS;
        uint256 delegatorAmt = remainder - commission;

        if (delegatorAmt != 0) {
            // Shares, not staked tokens: `depositReward` divides by the share supply. Rounding
            // can leave a pool holding tokens with no shares, and the wrong check reverts.
            if (INVNMStaking(staking).totalShares(validator) == 0) {
                // No pool (PoA / empty): the operator takes the whole validator remainder.
                commission += delegatorAmt;
            } else if (token == rTok) {
                SafeTransferLib.safeApproveWithRetry(token, staking, delegatorAmt);
                INVNMStaking(staking).depositReward(validator, delegatorAmt);
                deposited = delegatorAmt;
            } else {
                // Stakers are owed this, but the pool only accounts in `rewardToken`. Escrow it
                // rather than hand it to the operator — paying the validator out of the
                // delegators' allocation is the one outcome worse than holding it.
                heldForDelegators[token] = held + delegatorAmt;
                emit DelegatorShareUnrouted(token, delegatorAmt);
            }
        }

        if (commission != 0) SafeTransferLib.safeTransfer(token, operator, commission);
        emit Flushed(token, commission, devAmt, buyAmt, compounded, deposited);
    }

    function _protocolCuts(address token, uint256 balance, address rTok)
        private
        returns (uint256 devAmt, uint256 buyAmt, uint256 compounded)
    {
        if (factory == address(0)) return (0, 0, 0);
        FeeRouterFactory f = FeeRouterFactory(factory);
        (address dev, address buy, uint256 devBps, uint256 buyBps) = f.protocolSplit();
        devAmt = (balance * devBps) / BPS;
        buyAmt = (balance * buyBps) / BPS;
        if (devAmt != 0) SafeTransferLib.safeTransfer(token, dev, devAmt);

        if (buyAmt == 0) return (devAmt, 0, 0);
        address swapper = f.swapper();
        // The swapper is bound to one (rewardToken -> stakeToken) pair, so anything else is
        // forwarded for ops to convert, as when no swapper is configured at all.
        if (swapper == address(0) || token != rTok) {
            SafeTransferLib.safeTransfer(token, buy, buyAmt);
            return (devAmt, buyAmt, 0);
        }
        address sTok = stakeToken();
        SafeTransferLib.safeApproveWithRetry(token, swapper, buyAmt);
        try ISwapper(swapper).swap(token, sTok, buyAmt, 0) returns (uint256 out) {
            compounded = out;
            if (out != 0) SafeTransferLib.safeTransfer(sTok, buy, out);
        } catch {
            // A rejected market must not strand the devshare, commission and delegator legs
            // behind it — one bad pool would stop every router. Fall back to the unconfigured-
            // swapper route: forward the cut as stablecoin and let ops convert it.
            SafeTransferLib.safeApproveWithRetry(token, swapper, 0);
            SafeTransferLib.safeTransfer(token, buy, buyAmt);
            emit BuybackSwapFailed(swapper, buyAmt);
        }
    }

    /// @notice Governance escape hatch for funds `flush` cannot route — chiefly a delegator
    ///         share held in a token the pool cannot account in, which is swept, converted and
    ///         deposited to the pool directly (`depositReward` is permissionless).
    ///         Factory owner only.
    /// @dev Sends the whole balance, so the escrow is cleared with it.
    function sweep(address token, address to) external nonReentrant returns (uint256 amount) {
        if (factory == address(0) || msg.sender != Ownable(factory).owner()) {
            revert NotFactoryOwner();
        }
        if (to == address(0)) revert ZeroAddress();
        amount = SafeTransferLib.balanceOf(token, address(this));
        heldForDelegators[token] = 0;
        if (amount != 0) SafeTransferLib.safeTransfer(token, to, amount);
        emit Swept(token, to, amount);
    }
}

/// @notice Deploys one deterministic FeeRouter per (validator, operator, commission).
///         Owner sets the protocol split (devshare / buybacks) and the commission cap;
///         validators self-serve within the cap. Option A/B is `setProtocolSplit`.
contract FeeRouterFactory is Ownable {
    address public immutable staking;
    /// @dev Routers this factory deployed. `GuardedSwapper` reads it to decide who may move its
    ///      reference price — a router's output goes to the buyback wallet, never the caller.
    mapping(address => bool) public isRouter;
    uint256 public maxCommissionBps;
    address public swapper; // 0 = buybacks pay stables to `buyback`
    address public devshare;
    address public buyback;
    uint256 public devshareBps;
    uint256 public buybackBps;

    event RouterCreated(
        address indexed validator, address router, address operator, uint256 commissionBps
    );
    event MaxCommissionSet(uint256 bps);
    event SwapperSet(address swapper);
    event ProtocolSplitSet(
        address devshare, address buyback, uint256 devshareBps, uint256 buybackBps
    );

    error CommissionTooHigh();
    error ZeroAddress();
    error InvalidBps();

    constructor(address staking_, address owner_, uint256 maxCommissionBps_) {
        if (staking_ == address(0)) revert ZeroAddress();
        if (maxCommissionBps_ > BPS) revert CommissionTooHigh();
        staking = staking_;
        _initializeOwner(owner_);
        maxCommissionBps = maxCommissionBps_;
    }

    function setMaxCommission(uint256 bps) external onlyOwner {
        if (bps > BPS) revert CommissionTooHigh();
        maxCommissionBps = bps;
        emit MaxCommissionSet(bps);
    }

    /// @notice Market used to convert the buyback cut to NVNM before it is sent to `buyback`.
    ///         Unset: the cut is forwarded as stablecoin (ops buys off-contract).
    /// @dev Routers call it with `minOut = 0` — all execution-price protection lives in the
    ///      swapper. This must point at a `GuardedSwapper` (or equivalent); a bare AMM here
    ///      leaves every permissionless `flush` open to sandwiching.
    function setSwapper(address swapper_) external onlyOwner {
        swapper = swapper_;
        emit SwapperSet(swapper_);
    }

    /// @notice Protocol cuts: share of gross fees routed to `devshare` and `buyback`.
    function setProtocolSplit(
        address devshare_,
        address buyback_,
        uint256 devshareBps_,
        uint256 buybackBps_
    ) external onlyOwner {
        if (devshareBps_ + buybackBps_ > BPS) revert InvalidBps();
        if (devshareBps_ != 0 && devshare_ == address(0)) revert ZeroAddress();
        if (buybackBps_ != 0 && buyback_ == address(0)) revert ZeroAddress();
        devshare = devshare_;
        buyback = buyback_;
        devshareBps = devshareBps_;
        buybackBps = buybackBps_;
        emit ProtocolSplitSet(devshare_, buyback_, devshareBps_, buybackBps_);
    }

    function protocolSplit()
        external
        view
        returns (address dev, address buy, uint256 devBps, uint256 buyBps)
    {
        return (devshare, buyback, devshareBps, buybackBps);
    }

    function create(address validator, address operator, uint256 commissionBps)
        external
        returns (address router)
    {
        if (commissionBps > maxCommissionBps) revert CommissionTooHigh();
        bytes32 salt = keccak256(abi.encode(validator, operator, commissionBps));
        router = address(
            new FeeRouter{ salt: salt }(validator, operator, staking, address(this), commissionBps)
        );
        isRouter[router] = true;
        emit RouterCreated(validator, router, operator, commissionBps);
    }
}
