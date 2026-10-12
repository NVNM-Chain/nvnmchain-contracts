// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BPS, VALIDATOR_REGISTRY} from "./Constants.sol";
import {IBondGateway} from "./interfaces/IBondGateway.sol";
import {IEquivocation} from "./interfaces/IEquivocation.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Initializable} from "solady/utils/Initializable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";

/// @title NVNMStaking
/// @notice Delegated fee-sharing staking: retail holders stake NVNM toward a validator;
///         that validator's deposited stablecoin fees split pro-rata among its delegators.
///         Rewards are deposited, never minted, and vest over `rewardDuration`.
/// @dev UUPS proxy. `owner` upgrades, and should be a timelock longer than `MAX_UNBONDING` so
///      delegators can exit before a change lands. `slasher` acts without that delay, or a
///      resigning validator would withdraw its bond before a queued slash; `slash` seizes only
///      the validator's acquired bond — delegators are never slashed. Ethereum's lockbox has a
///      slasher of its own, for the slash this chain's validators would not carry, and
///      `slashFromBridge` keeps the books here in step. Election is top-N of the node's registry
///      by `acquired * acquiredWeight + delegated`: the registry's owner curates who may stand,
///      a bond at `minAcquired` makes one electable. Each seat votes once; the node draws block
///      proposers by the same score (`electionWeight`). Stake and bond both exit through the
///      unbonding period.
contract NVNMStaking is UUPSUpgradeable, Initializable, Ownable, ReentrancyGuard {
    using FixedPointMathLib for uint256;

    // Reward-accumulator scale, sized to dominate a ~1e30 share supply: at 1e18 a 500-USDC
    // deposit against a 1M-NVNM pool rounds to zero and strands in the contract.
    uint256 private constant ACC = 1e36;
    // ERC4626-style virtual offset: a donation-based inflation attack must move ~VIRTUAL_SHARES
    // times the victim's deposit to round it to zero.
    uint256 private constant VIRTUAL_SHARES = 1e3;
    uint256 private constant VIRTUAL_STAKE = 1;
    uint256 private constant MAX_SEATS = 21; // the validator set's cap
    uint256 private constant MAX_UNBONDING = 14 days; // the longest exit; the owner's timelock waits longer
    uint256 private constant MAX_REWARD_DURATION = 30 days;

    /// @dev An exiting stake bucket, cleared as a unit so the pair cannot drift apart.
    struct Unbonding {
        uint256 amount;
        uint256 releaseAt;
    }

    // -- ERC-7201 namespaced storage -----------------------------------------
    /// @custom:storage-location erc7201:nvnm.staking.storage
    struct StakingStorage {
        address stakeToken; // NVNM
        address rewardToken; // fee stablecoin (USDT0 on mainnet)
        mapping(address => uint256) totalStaked; // validator => pool tokens
        mapping(address => uint256) accRewardPerShare; // validator => reward accumulator (ACC-scaled)
        mapping(address => mapping(address => uint256)) shares; // validator => user => pool shares
        mapping(address => uint256) totalShares; // validator => total pool shares
        mapping(address => mapping(address => uint256)) userPaid; // validator => user => acc at last settle
        mapping(address => mapping(address => uint256)) accrued; // validator => user => claimable rewards
        // unbonding: exiting stake stops earning and stops counting for election at once, and
        // is withdrawable after the delay
        uint256 unbondingPeriod; // seconds; 0 = immediate
        mapping(address => mapping(address => Unbonding)) unstaking; // validator => user => bucket
        // candidacy: a bond bridged in from Ethereum, held by the validator's address
        mapping(address => uint256) bondPaid; // validator => acquired stake
        // A departing validator's bond stays in `bondPaid`, and so stays slashable, until
        // `withdrawBond`. Otherwise an operator front-runs its own slash by resigning.
        mapping(address => uint256) bondReleaseAt; // validator => withdrawable-from timestamp
        // election: top-`maxSeats` of the registry by acquired * acquiredWeight + delegated, one
        // seat each. maxSeats 0 = unconfigured; acquiredWeight 0 means 1; maxDelegated 0 = uncapped.
        // minAcquired is the 1M NVNM floor: below it, delegation alone never buys a seat.
        uint256 maxSeats;
        uint256 acquiredWeight;
        uint256 maxDelegated;
        uint256 minAcquired;
        // minSeats: electing fewer members elects nobody. It bounds what computeCommittee
        // returns, not what the node seats: that is the registry's share of it. 0 disables.
        uint256 minSeats;
        // Every posted bond not yet withdrawn, unbonding ones included. While it is nonzero the
        // unbonding period cannot be 0, or a bond leaves in the block its slash was sent.
        uint256 bonded;
        // reward streams: a deposit vests over `rewardDuration`, so stake earns it by being there
        // while it vests, not by landing in the block before the flush. A pool with no shares
        // pauses its stream until the next stake.
        uint256 rewardDuration; // seconds, for deposits from now on
        mapping(address => uint256) rewardRate; // validator => ACC-scaled tokens per second
        mapping(address => uint256) rewardFinish; // validator => when the stream runs dry
        mapping(address => uint256) rewardUpdated; // validator => last accrual
        address slasher; // may slash bonds without the owner's delay; 0 = nobody
        // The L1 bridge gateway: bonds arrive only through it and leave or are seized through it,
        // so each stays tied to its validator's bond on Ethereum.
        address bondGateway;
        // Evidence slashing: what conflicting votes cost a bond, 0 = closed, and for how many
        // epochs evidence of them counts. A key pays once for an epoch, whatever address the
        // registry holds it under by then: one fault signs twice in many rounds. Both share
        // the gateway's slot, which a slash reads anyway.
        uint16 equivocationBps;
        uint64 evidenceEpochs;
        mapping(bytes32 key => mapping(uint64 epoch => bool)) punished;
    }

    // keccak256(abi.encode(uint256(keccak256("nvnm.staking.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _STORAGE_SLOT = 0x30ce8c2903d30a857154c6ccc6fd0f005695d28f4395deb97f28581bda922200;

    function _s() private pure returns (StakingStorage storage $) {
        assembly {
            $.slot := _STORAGE_SLOT
        }
    }

    // -- events --------------------------------------------------------------
    event Staked(address indexed validator, address indexed user, uint256 amount);
    event Unstaked(address indexed validator, address indexed user, uint256 amount);
    event RewardDeposited(address indexed validator, address indexed from, uint256 amount);
    event RewardClaimed(address indexed validator, address indexed user, uint256 amount);
    event RewardCompounded(address indexed validator, address indexed from, uint256 amount);
    /// @notice `validator` stands for election again, or has resigned and its bond unbonds.
    event CandidateSet(address indexed validator, bool active);
    event CommitteeConfigSet(uint256 maxSeats, uint256 acquiredWeight, uint256 maxDelegated);
    event SlasherSet(address slasher);
    event MinAcquiredSet(uint256 minAcquired);
    event MinSeatsSet(uint256 minSeats);
    event UnbondingPeriodSet(uint256 period);
    event RewardDurationSet(uint256 duration);
    event UnstakeRequested(address indexed validator, address indexed user, uint256 amount, uint256 releaseAt);
    event Withdrawn(address indexed validator, address indexed user, uint256 amount);
    event BondUnbonding(address indexed validator, uint256 amount, uint256 releaseAt);
    event BondWithdrawn(address indexed validator, uint256 amount);
    event BondReceived(address indexed validator, uint256 amount, uint256 bond);
    event BondGatewaySet(address gateway);
    event Slashed(address indexed validator, uint256 bps, uint256 seized);
    event EquivocationSet(uint256 bps, uint256 evidenceEpochs);
    event Equivocated(address indexed validator, uint64 epoch, uint64 viewNumber);

    // -- errors --------------------------------------------------------------
    error ZeroAmount();
    error ZeroAddress();
    error InsufficientStake();
    error NoStakers();
    error AlreadyCandidate();
    error NotCandidate();
    error InvalidPeriod();
    error NotSlasher();
    error NothingToWithdraw();
    error StillUnbonding();
    error InvalidBps();
    error PoolCollapsed();
    error ZeroShares();
    error DelegationCap();
    error UnbondingRequired();
    error TooManySeats();
    error SlashingClosed();
    error NotBondGateway();
    error EvidenceExpired();
    error AlreadySlashed();
    error NothingToSlash();

    constructor() {
        _disableInitializers();
    }

    /// @dev Tokens must be standard ERC-20s (no fee-on-transfer / rebasing).
    function initialize(address owner_, address stakeToken_, address rewardToken_) external initializer {
        // No owner would leave the proxy unupgradeable, with every knob at its default.
        if (owner_ == address(0) || stakeToken_ == address(0) || rewardToken_ == address(0)) revert ZeroAddress();
        _initializeOwner(owner_);
        StakingStorage storage $ = _s();
        $.stakeToken = stakeToken_;
        $.rewardToken = rewardToken_;
        $.rewardDuration = 1 days;
    }

    // -- staking -------------------------------------------------------------
    /// @notice Stake `amount` NVNM toward `validator`, minting pool shares at the current rate.
    function stake(address validator, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        StakingStorage storage $ = _s();
        uint256 tShares = $.totalShares[validator];
        uint256 tStaked = $.totalStaked[validator];
        _checkCap($, tStaked + amount);
        // A collapsed pool (shares outstanding, zero tokens) has no meaningful rate.
        if (tShares != 0 && tStaked == 0) revert PoolCollapsed();
        uint256 minted = _toShares(tShares, tStaked, amount);
        if (minted == 0) revert ZeroShares(); // backstop: rate pushed beyond the virtual offset
        _settle($, validator, msg.sender);
        $.shares[validator][msg.sender] += minted;
        $.totalShares[validator] = tShares + minted;
        $.totalStaked[validator] = tStaked + amount;
        SafeTransferLib.safeTransferFrom($.stakeToken, msg.sender, address(this), amount);
        emit Staked(validator, msg.sender, amount);
    }

    /// @notice Exit `amount` of your stake; accrued rewards stay claimable. With an unbonding
    ///         period set it parks until `withdraw`, and a new request resets the whole bucket.
    function unstake(address validator, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        StakingStorage storage $ = _s();
        uint256 tShares = $.totalShares[validator];
        uint256 tStaked = $.totalStaked[validator];
        uint256 userShares = $.shares[validator][msg.sender];
        if (tStaked == 0 || _toTokens(tShares, tStaked, userShares) < amount) {
            revert InsufficientStake();
        }
        // Burn rounded-up shares so the pool never pays out more than the share fraction.
        uint256 burned = _toSharesUp(tShares, tStaked, amount);
        if (burned > userShares) burned = userShares;
        _settle($, validator, msg.sender);
        $.shares[validator][msg.sender] = userShares - burned;
        $.totalShares[validator] = tShares - burned;
        $.totalStaked[validator] = tStaked - amount;
        uint256 period = $.unbondingPeriod;
        if (period == 0) {
            SafeTransferLib.safeTransfer($.stakeToken, msg.sender, amount);
            emit Unstaked(validator, msg.sender, amount);
        } else {
            uint256 releaseAt = block.timestamp + period;
            Unbonding storage u = $.unstaking[validator][msg.sender];
            u.amount += amount;
            u.releaseAt = releaseAt;
            emit UnstakeRequested(validator, msg.sender, amount, releaseAt);
        }
    }

    /// @notice Withdraw your matured unbonding stake from `validator`.
    function withdraw(address validator) external nonReentrant returns (uint256 amount) {
        StakingStorage storage $ = _s();
        Unbonding storage u = $.unstaking[validator][msg.sender];
        amount = u.amount;
        if (amount == 0) revert NothingToWithdraw();
        if (block.timestamp < u.releaseAt) revert StillUnbonding();
        delete $.unstaking[validator][msg.sender];
        SafeTransferLib.safeTransfer($.stakeToken, msg.sender, amount);
        emit Withdrawn(validator, msg.sender, amount);
    }

    /// @notice The exit delay for stake and bonds alike, applied to future exits only. Should
    ///         be at least one epoch once the election feeds consensus, and cannot be 0 while
    ///         the election is configured or a bond is posted.
    function setUnbondingPeriod(uint256 period) external onlyOwner {
        if (period > MAX_UNBONDING) revert InvalidPeriod();
        StakingStorage storage $ = _s();
        if (period == 0 && ($.maxSeats != 0 || $.bonded != 0)) revert UnbondingRequired();
        $.unbondingPeriod = period;
        emit UnbondingPeriodSet(period);
    }

    /// @notice Stream `amount` of reward token to `validator`'s stakers over `rewardDuration`,
    ///         together with whatever has not vested yet. Permissionless — the fee-routing layer
    ///         (or anyone) tops up a validator's pool.
    function depositReward(address validator, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        StakingStorage storage $ = _s();
        if ($.totalShares[validator] == 0) revert NoStakers();
        SafeTransferLib.safeTransferFrom($.rewardToken, msg.sender, address(this), amount);
        _accrue($, validator);
        uint256 duration = $.rewardDuration;
        uint256 finish = $.rewardFinish[validator];
        uint256 unvested = block.timestamp < finish ? $.rewardRate[validator] * (finish - block.timestamp) : 0;
        $.rewardRate[validator] = (amount * ACC + unvested) / duration;
        $.rewardFinish[validator] = block.timestamp + duration;
        emit RewardDeposited(validator, msg.sender, amount);
    }

    /// @notice How long each deposit takes to vest, for deposits from now on. Never 0: paid at
    ///         once, a deposit rewards whoever staked the block before it.
    function setRewardDuration(uint256 duration) external onlyOwner {
        if (duration == 0 || duration > MAX_REWARD_DURATION) revert InvalidPeriod();
        _s().rewardDuration = duration;
        emit RewardDurationSet(duration);
    }

    /// @notice Grow every delegator's stake pro-rata without minting shares. Raw transfers are
    ///         invisible to the accounting, so compounding must come through here.
    function compoundReward(address validator, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        StakingStorage storage $ = _s();
        if ($.totalShares[validator] == 0) revert NoStakers();
        uint256 tStaked = $.totalStaked[validator];
        if (tStaked == 0) revert PoolCollapsed();
        // Compounded stake carries election weight, so the cap binds here or is bypassed.
        _checkCap($, tStaked + amount);
        $.totalStaked[validator] = tStaked + amount;
        SafeTransferLib.safeTransferFrom($.stakeToken, msg.sender, address(this), amount);
        emit RewardCompounded(validator, msg.sender, amount);
    }

    /// @notice Claim your accrued reward-token rewards for `validator`.
    function claim(address validator) external nonReentrant returns (uint256 amount) {
        StakingStorage storage $ = _s();
        _settle($, validator, msg.sender);
        amount = $.accrued[validator][msg.sender];
        if (amount != 0) {
            $.accrued[validator][msg.sender] = 0;
            SafeTransferLib.safeTransfer($.rewardToken, msg.sender, amount);
            emit RewardClaimed(validator, msg.sender, amount);
        }
    }

    /// @dev Fold pending rewards into `accrued` and mark the user settled to the accumulator.
    ///      Callers change shares only after this, so the stream accrues on the old supply.
    function _settle(StakingStorage storage $, address validator, address user) private {
        _accrue($, validator);
        $.accrued[validator][user] += _pendingReward($, validator, user);
        $.userPaid[validator][user] = $.accRewardPerShare[validator];
    }

    /// @dev Vest the stream into the accumulator up to now. With no shares to pay, the unvested
    ///      remainder restarts from now instead of vesting to nobody.
    function _accrue(StakingStorage storage $, address validator) private {
        uint256 last = $.rewardUpdated[validator];
        uint256 finish = $.rewardFinish[validator];
        if (last < finish && $.totalShares[validator] == 0) {
            $.rewardFinish[validator] = block.timestamp + (finish - last);
        } else {
            $.accRewardPerShare[validator] = _vestedAcc($, validator);
        }
        $.rewardUpdated[validator] = block.timestamp;
    }

    /// @dev The accumulator as `_accrue` would leave it now.
    function _vestedAcc(StakingStorage storage $, address validator) private view returns (uint256 acc) {
        acc = $.accRewardPerShare[validator];
        uint256 last = $.rewardUpdated[validator];
        uint256 finish = $.rewardFinish[validator];
        uint256 tShares = $.totalShares[validator];
        if (last < finish && tShares != 0) {
            uint256 end = block.timestamp < finish ? block.timestamp : finish;
            acc += $.rewardRate[validator].fullMulDiv(end - last, tShares);
        }
    }

    /// @dev The per-validator delegation cap, against what the pool would then hold; 0 is
    ///      uncapped.
    function _checkCap(StakingStorage storage $, uint256 staked) private view {
        uint256 cap = $.maxDelegated;
        if (cap != 0 && staked > cap) revert DelegationCap();
    }

    /// @dev The one accrual formula: `earned` must report what `claim` will pay.
    function _pendingReward(StakingStorage storage $, address validator, address user) private view returns (uint256) {
        return $.shares[validator][user].fullMulDiv(_vestedAcc($, validator) - $.userPaid[validator][user], ACC);
    }

    // -- share/token conversion ----------------------------------------------
    // The rate lives in these three helpers only, so the offset and each call site's rounding
    // direction cannot drift apart.
    function _toShares(uint256 tShares, uint256 tStaked, uint256 amount) private pure returns (uint256) {
        return amount.fullMulDiv(tShares + VIRTUAL_SHARES, tStaked + VIRTUAL_STAKE);
    }

    function _toSharesUp(uint256 tShares, uint256 tStaked, uint256 amount) private pure returns (uint256) {
        return amount.fullMulDivUp(tShares + VIRTUAL_SHARES, tStaked + VIRTUAL_STAKE);
    }

    function _toTokens(uint256 tShares, uint256 tStaked, uint256 shares) private pure returns (uint256) {
        return shares.fullMulDiv(tStaked + VIRTUAL_STAKE, tShares + VIRTUAL_SHARES);
    }

    // -- slashing ------------------------------------------------------------
    /// @notice Slash `bps` of `validator`'s bond, once the election is configured (Phase 5), and
    ///         seize as much of its bond on Ethereum. Delegated stake is untouched; a bond
    ///         unbonding after a resignation is not. Only the slasher: the owner's delay would let
    ///         the bond leave first. The slasher pays the bridge's fee (see {IBondGateway}).
    function slash(address validator, uint256 bps) external nonReentrant returns (uint256 seized) {
        StakingStorage storage $ = _s();
        // An unset slasher must not admit address(0), which the node calls from.
        if ($.slasher == address(0) || msg.sender != $.slasher) revert NotSlasher();
        if (bps == 0 || bps > BPS) revert InvalidBps();
        // The PoA phases have no validator-level slashing, bond or not.
        if ($.maxSeats == 0) revert SlashingClosed();
        return _slash($, validator, bps);
    }

    /// @notice Slash `equivocationBps` of the bond of the validator whose consensus key signed
    ///         the conflicting votes in `evidence`, as the node's registry reads it. Anyone may
    ///         bring it: once for a key and epoch, and while the epoch is no more than
    ///         `evidenceEpochs` old. With no bond to slash it reverts, and the epoch stays open
    ///         for one that arrives in time. You pay the bridge's fee (see {IBondGateway}) and
    ///         are not paid back: what is seized burns, so bringing evidence is the validators'
    ///         and the foundation's own interest, not a bounty.
    function slashEquivocation(bytes calldata evidence) external nonReentrant returns (uint256 seized) {
        StakingStorage storage $ = _s();
        uint256 bps = $.equivocationBps;
        // Before asking the registry, which charges for the signatures it checks.
        if (bps == 0 || $.maxSeats == 0) revert SlashingClosed();
        (address validator, uint64 epoch, uint64 viewNumber, uint64 epochsAgo) =
            IEquivocation(VALIDATOR_REGISTRY).equivocator(evidence);
        if (epochsAgo > $.evidenceEpochs) revert EvidenceExpired();
        // The registry accepted the evidence, so it opens with the key that signed.
        mapping(uint64 => bool) storage punished = $.punished[bytes32(evidence[:32])];
        if (punished[epoch]) revert AlreadySlashed();
        punished[epoch] = true;
        emit Equivocated(validator, epoch, viewNumber);
        seized = _slash($, validator, bps);
        if (seized == 0) revert NothingToSlash();
    }

    function _slash(StakingStorage storage $, address validator, uint256 bps) private returns (uint256 seized) {
        seized = ($.bondPaid[validator] * bps) / BPS;
        emit Slashed(validator, bps, seized);
        if (seized != 0) _debitBond($, validator, seized).seize(validator, seized, msg.sender);
    }

    // -- candidacy -----------------------------------------------------------
    /// @notice `amount` more of `validator`'s bond, pulled from the gateway, which has just
    ///         minted it from `validator`'s bond on Ethereum and approved it. At `minAcquired`
    ///         it stands `validator` for election by itself. Joining an unbonding bond, it
    ///         restarts the wait: otherwise it leaves with a matured one in the block it arrives.
    /// @dev Books only what arrives: a gateway that minted nothing books no bond. Beyond that it
    ///      never reverts for the bond's sake, which is already locked on Ethereum, and a delivery
    ///      that reverted would leave there with no record here. The gateway must deliver a bond
    ///      only from its own validator, or anyone restarts another's wait.
    function bondFromBridge(address validator, uint256 amount) external {
        StakingStorage storage $ = _s();
        if (msg.sender != $.bondGateway) revert NotBondGateway();
        SafeTransferLib.safeTransferFrom($.stakeToken, msg.sender, address(this), amount);
        uint256 bond = $.bondPaid[validator] + amount;
        $.bondPaid[validator] = bond;
        $.bonded += amount;
        emit BondReceived(validator, amount, bond);
        if ($.bondReleaseAt[validator] != 0) _unbondBond($, validator);
    }

    /// @notice Drop up to `amount` of `validator`'s bond, which the lockbox's own slasher has
    ///         seized on Ethereum, and leave it to the gateway to burn. An unbonding bond too.
    /// @dev Never reverts for the bond's sake, as {bondFromBridge}: Ethereum has already seized.
    function slashFromBridge(address validator, uint256 amount) external returns (uint256 seized) {
        StakingStorage storage $ = _s();
        if (msg.sender != $.bondGateway) revert NotBondGateway();
        uint256 bond = $.bondPaid[validator];
        seized = amount.min(bond);
        emit Slashed(validator, bond == 0 ? 0 : (seized * BPS) / bond, seized);
        if (seized != 0) _debitBond($, validator, seized);
    }

    /// @notice Stand for election again on a bond of yours that is unbonding: the wait is
    ///         cancelled, and the bond is at risk again.
    function registerCandidate() external nonReentrant {
        StakingStorage storage $ = _s();
        if ($.bondPaid[msg.sender] == 0 || $.bondReleaseAt[msg.sender] == 0) revert AlreadyCandidate();
        $.bondReleaseAt[msg.sender] = 0;
        emit CandidateSet(msg.sender, true);
    }

    /// @notice Leave the election: your bond unbonds, to be sent home with `withdrawBond`.
    ///         Election weight ends at once; the bond stays slashable until then.
    function resignCandidate() external nonReentrant {
        StakingStorage storage $ = _s();
        if ($.bondPaid[msg.sender] == 0 || $.bondReleaseAt[msg.sender] != 0) revert NotCandidate();
        _unbondBond($, msg.sender);
        emit CandidateSet(msg.sender, false);
    }

    /// @notice Send your matured bond, net of any slashing during unbonding, home to Ethereum,
    ///         where the lockbox pays it out after a wait of its own. You pay the bridge's fee
    ///         (see {IBondGateway}).
    function withdrawBond() external nonReentrant returns (uint256 amount) {
        StakingStorage storage $ = _s();
        uint256 releaseAt = $.bondReleaseAt[msg.sender];
        if (releaseAt == 0) revert NothingToWithdraw();
        if (block.timestamp < releaseAt) revert StillUnbonding();
        amount = $.bondPaid[msg.sender];
        $.bondReleaseAt[msg.sender] = 0;
        emit BondWithdrawn(msg.sender, amount);
        if (amount != 0) _debitBond($, msg.sender, amount).returnBond(msg.sender, amount, msg.sender);
    }

    /// @dev Takes `amount` off `validator`'s bond and approves the gateway to burn it.
    function _debitBond(StakingStorage storage $, address validator, uint256 amount)
        private
        returns (IBondGateway gateway)
    {
        $.bondPaid[validator] -= amount;
        $.bonded -= amount;
        gateway = IBondGateway($.bondGateway);
        SafeTransferLib.safeApprove($.stakeToken, address(gateway), amount);
    }

    function _unbondBond(StakingStorage storage $, address validator) private {
        // A zero period means slashing is closed (`setUnbondingPeriod`): releasing at once loses nothing.
        // Never before a release already set: a top-up under a shortened period must not cut it.
        uint256 releaseAt = (block.timestamp + $.unbondingPeriod).max($.bondReleaseAt[validator]);
        $.bondReleaseAt[validator] = releaseAt;
        emit BondUnbonding(validator, $.bondPaid[validator], releaseAt);
    }

    // -- committee election --------------------------------------------------
    /// @notice Election knobs: committee size (at most 21), acquired-stake overweight, and
    ///         the per-validator delegation cap. Needs a nonzero unbonding period: stake elects
    ///         as it stands at the boundary block, so only the lockup after it makes a seat cost.
    function setCommitteeConfig(uint256 maxSeats_, uint256 acquiredWeight_, uint256 maxDelegated_) external onlyOwner {
        if (maxSeats_ == 0) revert ZeroAmount();
        StakingStorage storage $ = _s();
        // Fewer seats than the floor would elect nobody for good.
        if (maxSeats_ > MAX_SEATS || maxSeats_ < $.minSeats) revert TooManySeats();
        if ($.unbondingPeriod == 0) revert UnbondingRequired();
        $.maxSeats = maxSeats_;
        $.acquiredWeight = acquiredWeight_;
        $.maxDelegated = maxDelegated_;
        emit CommitteeConfigSet(maxSeats_, acquiredWeight_, maxDelegated_);
    }

    /// @notice The acquired-stake floor for electability, the 1M NVNM minimum. 0 disables it,
    ///         as in the PoA phases where the owner curates and no bond is posted.
    function setMinAcquired(uint256 minAcquired_) external onlyOwner {
        _s().minAcquired = minAcquired_;
        emit MinAcquiredSet(minAcquired_);
    }

    /// @notice Electing fewer than `minSeats` elects nobody. The node seats only the elected
    ///         addresses in its registry, under its own floor, so this bounds the return value,
    ///         not the committee. 0 disables it.
    function setMinSeats(uint256 minSeats_) external onlyOwner {
        StakingStorage storage $ = _s();
        if (minSeats_ > ($.maxSeats == 0 ? MAX_SEATS : $.maxSeats)) revert TooManySeats();
        $.minSeats = minSeats_;
        emit MinSeatsSet(minSeats_);
    }

    /// @notice Who may slash; 0 closes slashing to everyone.
    function setSlasher(address slasher_) external onlyOwner {
        _s().slasher = slasher_;
        emit SlasherSet(slasher_);
    }

    /// @notice What `slashEquivocation` takes of a bond, 0 closing it, and how many epochs old
    ///         a round may be. Keep that shorter than the unbonding period, which is in seconds.
    function setEquivocation(uint256 bps, uint256 evidenceEpochs_) external onlyOwner {
        if (bps > BPS) revert InvalidBps();
        StakingStorage storage $ = _s();
        $.equivocationBps = uint16(bps);
        // No round is older than uint64 epochs, so the cap changes nothing.
        uint64 epochs = uint64(evidenceEpochs_.min(type(uint64).max));
        $.evidenceEpochs = epochs;
        emit EquivocationSet(bps, epochs);
    }

    /// @notice The L1 bridge gateway that bonds arrive through and leave by.
    function setBondGateway(address gateway) external onlyOwner {
        _s().bondGateway = gateway;
        emit BondGatewaySet(gateway);
    }

    /// @notice Top-`maxSeats` of `eligible` by `bond * acquiredWeight + delegated`, one equal
    ///         seat each. Those below `minAcquired`, unbonding, or weighing zero are dropped; ties
    ///         keep `eligible`'s order. Unconfigured, or below `minSeats`, elects nobody.
    /// @dev The consensus layer reads this at a chosen block, and that read is the snapshot.
    ///      Electing nobody must return empty rather than revert: a revert reads as a node-local
    ///      failure and stalls one node's epoch feed, where empty sends them all to the same
    ///      fallback.
    /// @param eligible Who the node can seat: its validator registry, in its order, whose owner
    ///        curates who may stand at all.
    function computeCommittee(address[] calldata eligible) external view returns (address[] memory vals) {
        StakingStorage storage $ = _s();
        uint256 maxSeats = $.maxSeats;
        if (maxSeats == 0) return vals;
        (uint256 weightMul, uint256 floor, uint256 cap) = _weighing($);

        // The heaviest so far, heaviest first: `m` of them, up to `maxSeats`.
        address[] memory top = new address[](maxSeats);
        uint256[] memory weight = new uint256[](maxSeats);
        uint256 m;
        for (uint256 i; i < eligible.length; ++i) {
            address c = eligible[i];
            uint256 w = _standingScore($, c, weightMul, floor, cap);
            if (w == 0) continue;
            // Only strictly heavier than the lightest kept displaces it: an earlier tie keeps its seat.
            if (m == maxSeats && w <= weight[m - 1]) continue;
            // The registry names an address once; this read stays total if ever it did not.
            bool kept;
            for (uint256 k; k < m && !kept; ++k) {
                kept = top[k] == c;
            }
            if (kept) continue;
            uint256 j = m < maxSeats ? m++ : maxSeats - 1;
            for (; j > 0 && weight[j - 1] < w; --j) {
                top[j] = top[j - 1];
                weight[j] = weight[j - 1];
            }
            top[j] = c;
            weight[j] = w;
        }
        // Below the viability floor the election seats nobody: better every node falls back to
        // the registry together than run consensus on a committee governance calls unsafe.
        if (m < $.minSeats) return vals;
        vals = new address[](m);
        for (uint256 i; i < m; ++i) {
            vals[i] = top[i];
        }
    }

    /// @notice Each of `who`'s election score, as `computeCommittee` ranks by. Zero for an
    ///         address it would not rank (below `minAcquired`, or unbonding) and for every
    ///         address while the election is unconfigured. The node draws block proposers by it.
    /// @dev Not cut to the committee: the node asks about the keys that hold this epoch's
    ///      shares, which the election may rank outside it by now.
    function electionWeight(address[] calldata who) external view returns (uint256[] memory weights) {
        StakingStorage storage $ = _s();
        weights = new uint256[](who.length);
        if ($.maxSeats == 0) return weights;
        (uint256 weightMul, uint256 floor, uint256 cap) = _weighing($);
        for (uint256 i; i < who.length; ++i) {
            weights[i] = _standingScore($, who[i], weightMul, floor, cap);
        }
    }

    /// @dev `c`'s score while it stands: 0 once its bond is unbonding.
    function _standingScore(StakingStorage storage $, address c, uint256 weightMul, uint256 floor, uint256 cap)
        private
        view
        returns (uint256)
    {
        if ($.bondReleaseAt[c] != 0) return 0;
        return _score($, c, weightMul, floor, cap);
    }

    /// @dev The election's knobs with their defaults applied: an unset weight is 1, an unset cap
    ///      none.
    function _weighing(StakingStorage storage $) private view returns (uint256 weightMul, uint256 floor, uint256 cap) {
        weightMul = $.acquiredWeight == 0 ? 1 : $.acquiredWeight;
        floor = $.minAcquired;
        cap = $.maxDelegated == 0 ? type(uint256).max : $.maxDelegated;
    }

    /// @dev `c`'s score: `bond * acquiredWeight + min(delegated, cap)`, or 0 below `floor`.
    function _score(StakingStorage storage $, address c, uint256 weightMul, uint256 floor, uint256 cap)
        private
        view
        returns (uint256)
    {
        uint256 acquired = $.bondPaid[c];
        if (acquired < floor) return 0; // delegation alone never buys a seat
        // The cap binds at the read too: lowering it sheds an incumbent's excess weight rather
        // than only refusing new stake. Saturating, because this read must be total: a checked
        // overflow would be a deterministic revert, which the node maps to a stalled epoch feed
        // rather than the registry fallback.
        return acquired.saturatingMul(weightMul).saturatingAdd($.totalStaked[c].min(cap));
    }

    // -- views ---------------------------------------------------------------
    /// @notice Claimable rewards for `user` on `validator`, including unsettled accrual.
    function earned(address validator, address user) external view returns (uint256) {
        StakingStorage storage $ = _s();
        return $.accrued[validator][user] + _pendingReward($, validator, user);
    }

    /// @notice `user`'s live stake in tokens at the pool's current rate.
    function stakedOf(address validator, address user) external view returns (uint256) {
        StakingStorage storage $ = _s();
        uint256 tShares = $.totalShares[validator];
        if (tShares == 0) return 0;
        return _toTokens(tShares, $.totalStaked[validator], $.shares[validator][user]);
    }

    function sharesOf(address validator, address user) external view returns (uint256) {
        return _s().shares[validator][user];
    }

    function totalStaked(address validator) external view returns (uint256) {
        return _s().totalStaked[validator];
    }

    /// @notice Outstanding pool shares — what `depositReward` divides by, so check it first.
    function totalShares(address validator) external view returns (uint256) {
        return _s().totalShares[validator];
    }

    function pendingUnstakeOf(address validator, address user)
        external
        view
        returns (uint256 amount, uint256 releaseAt)
    {
        Unbonding storage u = _s().unstaking[validator][user];
        return (u.amount, u.releaseAt);
    }

    /// @notice A departed candidate's unbonding bond. `releaseAt == 0` means not unbonding:
    ///         still a candidate, or already withdrawn.
    function pendingBondOf(address validator) external view returns (uint256 amount, uint256 releaseAt) {
        StakingStorage storage $ = _s();
        releaseAt = $.bondReleaseAt[validator];
        amount = releaseAt == 0 ? 0 : $.bondPaid[validator];
    }

    function slasher() external view returns (address) {
        return _s().slasher;
    }

    function equivocationBps() external view returns (uint256) {
        return _s().equivocationBps;
    }

    function evidenceEpochs() external view returns (uint256) {
        return _s().evidenceEpochs;
    }

    function bondGateway() external view returns (address) {
        return _s().bondGateway;
    }

    function bondOf(address validator) external view returns (uint256) {
        return _s().bondPaid[validator];
    }

    function minAcquired() external view returns (uint256) {
        return _s().minAcquired;
    }

    function minSeats() external view returns (uint256) {
        return _s().minSeats;
    }

    function committeeConfig()
        external
        view
        returns (uint256 maxSeats_, uint256 acquiredWeight_, uint256 maxDelegated_)
    {
        StakingStorage storage $ = _s();
        return ($.maxSeats, $.acquiredWeight, $.maxDelegated);
    }

    function unbondingPeriod() external view returns (uint256) {
        return _s().unbondingPeriod;
    }

    function rewardDuration() external view returns (uint256) {
        return _s().rewardDuration;
    }

    /// @notice `validator`'s reward stream: ACC-scaled (1e36) tokens per second, until `finish`.
    function rewardStream(address validator) external view returns (uint256 rate, uint256 finish) {
        StakingStorage storage $ = _s();
        return ($.rewardRate[validator], $.rewardFinish[validator]);
    }

    function stakeToken() external view returns (address) {
        return _s().stakeToken;
    }

    function rewardToken() external view returns (address) {
        return _s().rewardToken;
    }

    // -- upgrade authority ---------------------------------------------------
    function _authorizeUpgrade(address) internal override onlyOwner {}

    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }
}
