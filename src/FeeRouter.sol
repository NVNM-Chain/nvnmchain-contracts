// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BPS} from "./Constants.sol";
import {FeeLockbox} from "./FeeLockbox.sol";
import {INVNMStaking} from "./interfaces/INVNMStaking.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title FeeRouter
/// @notice Per-validator fee splitter, paid by `FeeManager.distributeFees`. `flush` takes the
///         factory's protocol cuts (devshare + buybacks), then splits what is left into operator
///         commission and delegator rewards — so the delegator share comes out of the validator
///         allocation, not off the top. At `commissionBps = 10_000` (Phases 1–4) the operator
///         takes the whole remainder, pool or no pool, held in the factory's lockbox until
///         distribution commences.
/// @dev `flush` is permissionless and takes an arbitrary token, so it is guarded: a token
///      contract is free to call back mid-transfer.
contract FeeRouter is ReentrancyGuard {
    address public immutable validator; // delegation / election key
    address public immutable operator; // receives the commission
    address public immutable staking;
    address public immutable factory;
    address public immutable lockbox; // the factory's; 0 without a factory
    /// @dev Of the *validator remainder* after protocol cuts, not of the gross fee.
    uint256 public immutable commissionBps;

    /// @notice Per token, the delegators' share the pool cannot account in. Held out of the
    ///         flushable balance, or a permissionless re-flush would cut it again.
    mapping(address => uint256) public heldForDelegators;
    mapping(address => bool) private lockboxApproved; // token => standing allowance granted

    event Flushed(
        address indexed token,
        uint256 commission,
        uint256 devshare,
        uint256 buyback,
        uint256 boughtBack,
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
    error SwapUnderfunded();

    /// @dev CALL's own cost and argument encoding, on top of the swap's budget.
    uint256 private constant SWAP_CALL_OVERHEAD = 10_000;

    constructor(address validator_, address operator_, address staking_, address factory_, uint256 commissionBps_) {
        if (validator_ == address(0) || operator_ == address(0) || staking_ == address(0)) {
            revert ZeroAddress();
        }
        if (commissionBps_ > BPS) revert InvalidBps();
        validator = validator_;
        operator = operator_;
        staking = staking_;
        factory = factory_;
        lockbox = factory_ == address(0) ? address(0) : FeeRouterFactory(factory_).lockbox();
        commissionBps = commissionBps_;
    }

    /// @notice The pool's reward token. Read live: the pool is upgradeable, and a cached copy
    ///         would misroute the delegator leg after a reward-token migration.
    function rewardToken() public view returns (address) {
        return INVNMStaking(staking).rewardToken();
    }

    /// @notice The pool's stake token, the buyback target. Read live, like `rewardToken`.
    function stakeToken() public view returns (address) {
        return INVNMStaking(staking).stakeToken();
    }

    /// @notice `flush` for the staking pool's reward token.
    function flush() external returns (uint256 deposited) {
        address token = rewardToken();
        return _flush(token, token);
    }

    /// @notice Apply protocol cuts to this router's `token` balance, then split the remainder.
    ///         With no stakers the delegator leg is paid to the operator (PoA).
    /// @dev In steady state a router holds one token, which `flush()` covers. This overload
    ///      routes everything else — a residue, or a plain transfer in — by the same rules
    ///      rather than stranding it.
    function flush(address token) external returns (uint256 deposited) {
        return _flush(token, rewardToken());
    }

    function _flush(address token, address rTok) private nonReentrant returns (uint256 deposited) {
        uint256 held = heldForDelegators[token];
        uint256 balance = SafeTransferLib.balanceOf(token, address(this));
        balance = balance > held ? balance - held : 0; // never re-cut the escrow
        if (balance == 0) return 0;

        (uint256 devAmt, uint256 buyAmt, uint256 boughtBack) = _protocolCuts(token, balance, rTok);
        uint256 remainder = balance - devAmt - buyAmt;

        uint256 commission = (remainder * commissionBps) / BPS;
        uint256 delegatorAmt = remainder - commission;

        if (delegatorAmt != 0) {
            // Shares, not staked tokens: `depositReward` divides by the share supply, and
            // rounding can leave a pool holding tokens with no shares.
            if (INVNMStaking(staking).totalShares(validator) == 0) {
                // No pool (PoA / empty): the operator takes the whole validator remainder.
                commission += delegatorAmt;
            } else if (token == rTok) {
                SafeTransferLib.safeApproveWithRetry(token, staking, delegatorAmt);
                INVNMStaking(staking).depositReward(validator, delegatorAmt);
                deposited = delegatorAmt;
            } else {
                // Owed to stakers, but the pool only accounts in `rewardToken`. Escrow beats
                // paying the validator out of the delegators' allocation.
                heldForDelegators[token] = held + delegatorAmt;
                emit DelegatorShareUnrouted(token, delegatorAmt);
            }
        }

        if (commission != 0) {
            if (lockbox == address(0) || FeeLockbox(lockbox).commenced()) {
                SafeTransferLib.safeTransfer(token, operator, commission);
            } else {
                // A standing allowance: one per flush would rewrite the slot every time.
                if (!lockboxApproved[token]) {
                    SafeTransferLib.safeApproveWithRetry(token, lockbox, type(uint256).max);
                    lockboxApproved[token] = true;
                }
                FeeLockbox(lockbox).deposit(token, operator, commission);
            }
        }
        emit Flushed(token, commission, devAmt, buyAmt, boughtBack, deposited);
    }

    function _protocolCuts(address token, uint256 balance, address rTok)
        private
        returns (uint256 devAmt, uint256 buyAmt, uint256 boughtBack)
    {
        if (factory == address(0)) return (0, 0, 0);
        (address dev, address buy, uint256 devBps, uint256 buyBps, address swapper, uint256 swapGas) =
            FeeRouterFactory(factory).cuts();
        devAmt = (balance * devBps) / BPS;
        buyAmt = (balance * buyBps) / BPS;
        if (devAmt != 0) SafeTransferLib.safeTransfer(token, dev, devAmt);

        if (buyAmt == 0) return (devAmt, 0, 0);
        // The swapper is bound to one pair, so anything else is forwarded like an unset one.
        if (swapper == address(0) || token != rTok) {
            SafeTransferLib.safeTransfer(token, buy, buyAmt);
            return (devAmt, buyAmt, 0);
        }
        boughtBack = _buyBack(token, swapper, swapGas, buy, buyAmt);
    }

    /// @dev Swap the buyback cut into the stake token for `buy`, or forward it unswapped if the
    ///      market rejects it.
    function _buyBack(address token, address swapper, uint256 budget, address buy, uint256 buyAmt)
        private
        returns (uint256 boughtBack)
    {
        address sTok = stakeToken();
        SafeTransferLib.safeApproveWithRetry(token, swapper, buyAmt);
        // A fixed budget, so the caller's gas limit cannot pick the outcome: short of it the
        // flush reverts, where the 63/64 rule would otherwise starve the swap into the fallback.
        if (gasleft() < budget + budget / 63 + SWAP_CALL_OVERHEAD) revert SwapUnderfunded();
        try ISwapper(swapper).swap{gas: budget}(token, sTok, buyAmt, 0) returns (uint256 out) {
            boughtBack = out;
            if (out != 0) SafeTransferLib.safeTransfer(sTok, buy, out);
        } catch {
            // One bad pool must not strand every other leg behind it. Fall back to the
            // unconfigured-swapper route and let ops convert.
            SafeTransferLib.safeApproveWithRetry(token, swapper, 0);
            SafeTransferLib.safeTransfer(token, buy, buyAmt);
            emit BuybackSwapFailed(swapper, buyAmt);
        }
    }

    /// @notice Factory-owner escape hatch for the escrowed delegator share, to be converted and
    ///         deposited to the pool by hand. Nothing else: live fees are only ever routed by
    ///         `flush`.
    function sweep(address token, address to) external nonReentrant returns (uint256 amount) {
        if (factory == address(0) || msg.sender != Ownable(factory).owner()) {
            revert NotFactoryOwner();
        }
        if (to == address(0)) revert ZeroAddress();
        amount = heldForDelegators[token];
        heldForDelegators[token] = 0;
        if (amount != 0) SafeTransferLib.safeTransfer(token, to, amount);
        emit Swept(token, to, amount);
    }
}

/// @notice Deploys one deterministic FeeRouter per (validator, operator, commission). The owner
///         sets the commission cap and the swapper; the split's recipients are fixed here at
///         deploy, and its ratios are what the lockbox's validator vote holds.
contract FeeRouterFactory is Ownable {
    address public immutable staking;
    address public immutable lockbox; // where every router's operator share waits
    address public immutable devshare;
    address public immutable buyback;
    /// @dev `GuardedSwapper` reads this to decide who may move its reference price.
    mapping(address => bool) public isRouter;
    uint256 public maxCommissionBps;
    address public swapper; // 0 = buybacks pay stables to `buyback`
    uint256 public swapGas; // what each buyback swap gets, whatever the flush caller sends

    event RouterCreated(address indexed validator, address router, address operator, uint256 commissionBps);
    event MaxCommissionSet(uint256 bps);
    event SwapperSet(address swapper, uint256 swapGas);

    error CommissionTooHigh();
    error ZeroAddress();
    error ZeroGas();

    constructor(
        address staking_,
        address lockbox_,
        address owner_,
        uint256 maxCommissionBps_,
        address devshare_,
        address buyback_
    ) {
        if (staking_ == address(0) || lockbox_ == address(0) || devshare_ == address(0) || buyback_ == address(0)) revert ZeroAddress();
        if (maxCommissionBps_ > BPS) revert CommissionTooHigh();
        staking = staking_;
        lockbox = lockbox_;
        devshare = devshare_;
        buyback = buyback_;
        _initializeOwner(owner_);
        maxCommissionBps = maxCommissionBps_;
    }

    function setMaxCommission(uint256 bps) external onlyOwner {
        if (bps > BPS) revert CommissionTooHigh();
        maxCommissionBps = bps;
        emit MaxCommissionSet(bps);
    }

    /// @notice Market converting the buyback cut to NVNM, and the gas each swap gets. Unset,
    ///         the cut is forwarded as stablecoin for ops to buy off-contract.
    /// @dev Routers call it with `minOut = 0`, so all price protection lives in the swapper:
    ///      this must be a `GuardedSwapper` or equivalent, never a bare AMM.
    function setSwapper(address swapper_, uint256 swapGas_) external onlyOwner {
        if (swapper_ != address(0) && swapGas_ == 0) revert ZeroGas();
        swapper = swapper_;
        swapGas = swapGas_;
        emit SwapperSet(swapper_, swapGas_);
    }

    /// @notice All a flush routes by, in one read: the cuts' recipients and ratios, and the market.
    function cuts()
        external
        view
        returns (address dev, address buy, uint256 devBps, uint256 buyBps, address swapper_, uint256 swapGas_)
    {
        (devBps, buyBps) = FeeLockbox(lockbox).split();
        return (devshare, buyback, devBps, buyBps, swapper, swapGas);
    }

    function create(address validator, address operator, uint256 commissionBps) external returns (address router) {
        if (commissionBps > maxCommissionBps) revert CommissionTooHigh();
        bytes32 salt = keccak256(abi.encode(validator, operator, commissionBps));
        router = address(new FeeRouter{salt: salt}(validator, operator, staking, address(this), commissionBps));
        isRouter[router] = true;
        emit RouterCreated(validator, router, operator, commissionBps);
    }
}
