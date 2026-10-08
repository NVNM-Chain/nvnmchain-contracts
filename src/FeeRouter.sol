// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BPS} from "./Constants.sol";
import {FeeLockbox} from "./FeeLockbox.sol";
import {IFeeManager} from "./interfaces/IFeeManager.sol";
import {INVNMStaking} from "./interfaces/INVNMStaking.sol";
import {ISwapCap, ISwapper} from "./interfaces/ISwapper.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title FeeRouter
/// @notice Per-validator fee splitter, paid by `FeeManager.distributeFees`. `flush` takes the
///         factory's protocol cuts — devshare, and buybacks swapped to NVNM for a dead address,
///         held here until a swap clears — then splits what is left into operator commission
///         and delegator rewards, so the delegator share comes out of the validator allocation,
///         not off the top. Until the lockbox commences distribution the operator is owed the
///         whole remainder there, whatever the commission.
/// @dev `flush` is permissionless and takes an arbitrary token, so it is guarded: a token
///      contract is free to call back mid-transfer.
contract FeeRouter is ReentrancyGuard {
    IFeeManager public constant FEE_MANAGER = IFeeManager(0xfeEC000000000000000000000000000000000000);

    address public immutable validator; // delegation / election key
    address public immutable operator; // receives the commission
    address public immutable staking;
    address public immutable factory;
    address public immutable lockbox; // the factory's
    /// @dev Of the *validator remainder* after protocol cuts, not of the gross fee.
    uint256 public immutable commissionBps;

    /// @notice Per token, the delegators' share the pool cannot account in. Held out of the
    ///         flushable balance, or a permissionless re-flush would cut it again.
    mapping(address => uint256) public heldForDelegators;
    /// @notice Per token, the buyback cut not yet swapped, retried by every flush: unset swapper,
    ///         a rejected swap, or a token the swapper does not take. Never forwarded unswapped.
    mapping(address => uint256) public heldForBuyback;
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
    /// @notice The swapper rejected `amount` of the buyback cut, which stays held for a retry.
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
        if (validator_ == address(0) || operator_ == address(0) || staking_ == address(0) || factory_ == address(0)) {
            revert ZeroAddress();
        }
        if (commissionBps_ > BPS) revert InvalidBps();
        validator = validator_;
        operator = operator_;
        staking = staking_;
        factory = factory_;
        lockbox = FeeRouterFactory(factory_).lockbox();
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

    /// @notice Have FeeManager pay this router in the pool's reward token, which `flush` deposits
    ///         and swaps; unset, it pays the chain's default token. The factory calls it at
    ///         creation; anyone may again after a reward-token migration, outside this router's
    ///         own blocks, where FeeManager refuses it.
    function setValidatorToken() external {
        FEE_MANAGER.setValidatorToken(rewardToken());
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
        uint256 reserved = heldForDelegators[token] + heldForBuyback[token];
        uint256 balance = SafeTransferLib.balanceOf(token, address(this));
        balance = balance > reserved ? balance - reserved : 0; // never re-cut what is held
        if (balance == 0 && heldForBuyback[token] == 0) return 0;

        (uint256 devAmt, uint256 buyAmt, uint256 boughtBack) = _protocolCuts(token, balance, rTok);
        uint256 remainder = balance - devAmt - buyAmt;

        // Delegators wait too: a 0% router over a self-staked pool would otherwise pay out at once.
        bool deferred = !FeeLockbox(lockbox).commenced();
        uint256 commission = deferred ? remainder : (remainder * commissionBps) / BPS;
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
                heldForDelegators[token] += delegatorAmt;
                emit DelegatorShareUnrouted(token, delegatorAmt);
            }
        }

        if (commission != 0) {
            if (!deferred) {
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
        (address dev, address buy, uint256 devBps, uint256 buyBps, address swapper, uint256 swapGas) =
            FeeRouterFactory(factory).cuts();
        devAmt = (balance * devBps) / BPS;
        buyAmt = (balance * buyBps) / BPS;
        if (devAmt != 0) SafeTransferLib.safeTransfer(token, dev, devAmt);

        boughtBack = _buyBack(token, rTok, swapper, swapGas, buy, buyAmt);
    }

    /// @dev Swap what the swapper takes of the held and new buyback cut into the stake token for
    ///      `sink`; the rest stays held for the next flush.
    function _buyBack(address token, address rTok, address swapper, uint256 budget, address sink, uint256 buyAmt)
        private
        returns (uint256 boughtBack)
    {
        uint256 pending = heldForBuyback[token] + buyAmt;
        // The swapper is bound to one pair, so anything else waits, as all of it does unset.
        if (pending != 0 && swapper != address(0) && token == rTok) {
            uint256 amount = pending;
            try ISwapCap(swapper).maxAmountIn() returns (uint256 cap) {
                if (cap < amount) amount = cap;
            } catch {} // a bare market takes any size
            if (amount != 0) {
                bool ok;
                (ok, boughtBack) = _swap(token, swapper, budget, sink, amount);
                if (ok) pending -= amount;
            }
        }
        heldForBuyback[token] = pending;
    }

    /// @dev One swap of `amount` into the stake token for `sink`. A rejected swap spends nothing.
    function _swap(address token, address swapper, uint256 budget, address sink, uint256 amount)
        private
        returns (bool ok, uint256 out)
    {
        address sTok = stakeToken();
        SafeTransferLib.safeApproveWithRetry(token, swapper, amount);
        // A fixed budget, so the caller's gas limit cannot pick the outcome: short of it the
        // flush reverts, where the 63/64 rule would otherwise starve the swap into the fallback.
        if (gasleft() < budget + budget / 63 + SWAP_CALL_OVERHEAD) revert SwapUnderfunded();
        try ISwapper(swapper).swap{gas: budget}(token, sTok, amount, 0) returns (uint256 got) {
            (ok, out) = (true, got);
            if (got != 0) SafeTransferLib.safeTransfer(sTok, sink, got);
        } catch {
            // One bad pool must not strand every other leg behind it: the cut waits for a retry.
            SafeTransferLib.safeApproveWithRetry(token, swapper, 0);
            emit BuybackSwapFailed(swapper, amount);
        }
    }

    /// @notice Factory-owner escape hatch for the escrowed delegator share, to be converted and
    ///         deposited to the pool by hand. Nothing else: live fees are only ever routed by
    ///         `flush`.
    function sweep(address token, address to) external nonReentrant returns (uint256 amount) {
        if (msg.sender != Ownable(factory).owner()) revert NotFactoryOwner();
        if (to == address(0)) revert ZeroAddress();
        amount = heldForDelegators[token];
        heldForDelegators[token] = 0;
        if (amount != 0) SafeTransferLib.safeTransfer(token, to, amount);
        emit Swept(token, to, amount);
    }
}

/// @notice Deploys one deterministic FeeRouter per (validator, operator, commission). The owner
///         sets the commission cap and the swapper; devshare's recipient is fixed here at deploy,
///         buybacks go to `BUYBACK_SINK`, and the ratios are what the lockbox's validator vote holds.
contract FeeRouterFactory is Ownable {
    /// @notice Where bought-back NVNM goes: no key, so it never moves again.
    address public constant BUYBACK_SINK = 0x000000000000000000000000000000000000dEaD;

    address public immutable staking;
    address public immutable lockbox; // where every router's operator share waits
    address public immutable devshare;
    /// @dev `GuardedSwapper` reads this to decide who may move its reference price.
    mapping(address => bool) public isRouter;
    uint256 public maxCommissionBps;
    address public swapper; // 0 = routers hold the buyback cut
    uint256 public swapGas; // what each buyback swap gets, whatever the flush caller sends
    /// @notice Each validator's latest router, the only fee recipient the node's registry takes
    ///         for it from NVNM1. The precompile reads this mapping at slot 4; keep it there.
    mapping(address validator => address router) public routerOf;

    event RouterCreated(address indexed validator, address router, address operator, uint256 commissionBps);
    event MaxCommissionSet(uint256 bps);
    event SwapperSet(address swapper, uint256 swapGas);

    error CommissionTooHigh();
    error ZeroAddress();
    error ZeroGas();

    constructor(address staking_, address lockbox_, address owner_, uint256 maxCommissionBps_, address devshare_) {
        if (staking_ == address(0) || lockbox_ == address(0) || devshare_ == address(0)) revert ZeroAddress();
        if (maxCommissionBps_ > BPS) revert CommissionTooHigh();
        staking = staking_;
        lockbox = lockbox_;
        devshare = devshare_;
        _initializeOwner(owner_);
        maxCommissionBps = maxCommissionBps_;
    }

    function setMaxCommission(uint256 bps) external onlyOwner {
        if (bps > BPS) revert CommissionTooHigh();
        maxCommissionBps = bps;
        emit MaxCommissionSet(bps);
    }

    /// @notice Market converting the buyback cut to NVNM, and the gas each swap gets. Unset,
    ///         routers hold the cut until one is set.
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
        return (devshare, BUYBACK_SINK, devBps, buyBps, swapper, swapGas);
    }

    /// @notice A router for `validator`, from now on the one the registry takes for it. Only the
    ///         validator or the owner: a router names who is paid the operator share. The owner
    ///         keeps the right so a seat that never routes can be made to take the cuts, and in
    ///         doing so names that seat's operator. Deployed under the registry's owner, which
    ///         can unseat the validator outright, that adds nothing to what it is trusted with;
    ///         nothing here ties the two, and under another owner it is a power of its own.
    function create(address validator, address operator, uint256 commissionBps) external returns (address router) {
        if (msg.sender != validator && msg.sender != owner()) revert Unauthorized();
        if (commissionBps > maxCommissionBps) revert CommissionTooHigh();
        bytes32 salt = keccak256(abi.encode(validator, operator, commissionBps));
        router = address(new FeeRouter{salt: salt}(validator, operator, staking, address(this), commissionBps));
        // Now, while no block pays it yet: FeeManager refuses the change in a router's own blocks.
        FeeRouter(router).setValidatorToken();
        isRouter[router] = true;
        routerOf[validator] = router;
        emit RouterCreated(validator, router, operator, commissionBps);
    }
}
