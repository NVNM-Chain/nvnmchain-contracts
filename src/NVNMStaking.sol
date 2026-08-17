// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { BPS } from "./Constants.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { Initializable } from "solady/utils/Initializable.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { UUPSUpgradeable } from "solady/utils/UUPSUpgradeable.sol";

/// @title NVNMStaking
/// @notice Delegated fee-sharing staking: retail holders stake NVNM toward a validator;
///         that validator's deposited stablecoin fees split pro-rata among its delegators.
///         Rewards are deposited, never minted.
/// @dev UUPS proxy, `owner` (a Safe) is the upgrade authority. `slash` seizes only the
///         validator's acquired candidacy bond — delegators are not slashed. Committee
///         election is top-N by `acquired * acquiredWeight + delegated`, one equal seat each
///         (the consensus engine is unit-weighted). Both delegated stake and the bond exit
///         through the owner-set unbonding period.
contract NVNMStaking is UUPSUpgradeable, Initializable, Ownable, ReentrancyGuard {
    using FixedPointMathLib for uint256;

    // Reward-accumulator fixed-point scale. Shares run at ~VIRTUAL_SHARES x the staked wei, so
    // the scale must dominate a share supply of ~1e30 (1e9 NVNM staked) for the truncation in
    // `amount * ACC / totalShares` to stay under one reward-token unit per deposit — at 1e18 a
    // 500-USDC deposit against a 1M-NVNM pool would round to zero and strand in the contract.
    uint256 private constant ACC = 1e36;
    // ERC4626-style virtual offset: the share rate is (tShares + VIRTUAL_SHARES) per
    // (tStaked + VIRTUAL_STAKE), so a donation-based inflation attack must move ~VIRTUAL_SHARES
    // times the victim's deposit to round it to zero.
    uint256 private constant VIRTUAL_SHARES = 1e3;
    uint256 private constant VIRTUAL_STAKE = 1;
    uint256 private constant MAX_CANDIDATES = 256; // bounds the consensus-facing election scan
    uint256 private constant MAX_UNBONDING = 30 days; // the longest exit an owner may impose

    /// @dev An exiting stake bucket: `amount` parked until `releaseAt`, cleared as a unit so
    ///      the pair can never drift apart.
    struct Unbonding {
        uint256 amount;
        uint256 releaseAt;
    }

    // -- ERC-7201 namespaced storage -----------------------------------------
    /// @custom:storage-location erc7201:nvnm.staking.storage
    struct StakingStorage {
        address stakeToken; // NVNM
        address rewardToken; // fee stablecoin (nvmnUSD)
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
        // candidacy: owner curation, or permissionless self-registration against an NVNM bond
        address[] candidates; // electable validators
        mapping(address => uint256) candidateIndex; // 1-based position in `candidates`; 0 = none
        uint256 candidacyBond; // 0 = self-registration closed
        mapping(address => uint256) bondPaid; // candidate => acquired stake
        // A departing candidate's bond stays in `bondPaid`, and so stays slashable, until
        // `withdrawBond`. Otherwise an operator front-runs its own slash by resigning.
        mapping(address => uint256) bondReleaseAt; // candidate => withdrawable-from timestamp
        // election: top-`maxSeats` by acquired * acquiredWeight + delegated, one seat each.
        // maxSeats 0 = unconfigured; acquiredWeight 0 means 1; maxDelegated 0 = uncapped.
        // minAcquired is the 1M NVNM floor: below it, delegation alone never buys a seat.
        uint256 maxSeats;
        uint256 acquiredWeight;
        uint256 maxDelegated;
        uint256 minAcquired;
        // minSeats: the committee viability floor. Electing fewer members elects nobody, and
        // an empty committee drops every node to the registry fallback together. 0 disables.
        uint256 minSeats;
    }

    // keccak256(abi.encode(uint256(keccak256("nvnm.staking.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _STORAGE_SLOT =
        0x30ce8c2903d30a857154c6ccc6fd0f005695d28f4395deb97f28581bda922200;

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
    event CandidateSet(address indexed validator, bool active);
    event CommitteeConfigSet(uint256 maxCommittee, uint256 acquiredWeight, uint256 maxDelegated);
    event CandidacyBondSet(uint256 bond);
    event MinAcquiredSet(uint256 minAcquired);
    event MinSeatsSet(uint256 minSeats);
    event UnbondingPeriodSet(uint256 period);
    event UnstakeRequested(
        address indexed validator, address indexed user, uint256 amount, uint256 releaseAt
    );
    event Withdrawn(address indexed validator, address indexed user, uint256 amount);
    event BondUnbonding(address indexed validator, uint256 amount, uint256 releaseAt);
    event BondWithdrawn(address indexed validator, uint256 amount);
    event Slashed(
        address indexed validator, uint256 bps, uint256 seized, address indexed recipient
    );

    // -- errors --------------------------------------------------------------
    error ZeroAmount();
    error ZeroAddress();
    error InsufficientStake();
    error NoStakers();
    error AlreadyCandidate();
    error NotCandidate();
    error InvalidPeriod();
    error NothingToWithdraw();
    error StillUnbonding();
    error CandidacyClosed();
    error InvalidBps();
    error NotAuthorized();
    error PoolCollapsed();
    error ZeroShares();
    error CandidateListFull();
    error DelegationCap();

    constructor() {
        _disableInitializers();
    }

    /// @dev Tokens must be standard ERC-20s (no fee-on-transfer / rebasing).
    function initialize(address owner_, address stakeToken_, address rewardToken_)
        external
        initializer
    {
        if (stakeToken_ == address(0) || rewardToken_ == address(0)) revert ZeroAddress();
        _initializeOwner(owner_);
        StakingStorage storage $ = _s();
        $.stakeToken = stakeToken_;
        $.rewardToken = rewardToken_;
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

    /// @notice Exit `amount` tokens of your stake from `validator`; accrued rewards stay
    ///         claimable. With an unbonding period set the stake parks in a pending bucket
    ///         until `withdraw`, and a new request resets the clock on the whole bucket.
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

    /// @notice Set the unbonding delay, for stake and bonds alike (future exits only). Should
    ///         be at least one epoch once the committee election feeds consensus.
    function setUnbondingPeriod(uint256 period) external onlyOwner {
        if (period > MAX_UNBONDING) revert InvalidPeriod();
        _s().unbondingPeriod = period;
        emit UnbondingPeriodSet(period);
    }

    /// @notice Deposit `amount` of reward token to split pro-rata among `validator`'s stakers.
    ///         Permissionless — the fee-routing layer (or anyone) tops up a validator's pool.
    function depositReward(address validator, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        StakingStorage storage $ = _s();
        uint256 tShares = $.totalShares[validator];
        if (tShares == 0) revert NoStakers();
        SafeTransferLib.safeTransferFrom($.rewardToken, msg.sender, address(this), amount);
        $.accRewardPerShare[validator] += amount.fullMulDiv(ACC, tShares);
        emit RewardDeposited(validator, msg.sender, amount);
    }

    /// @notice Add stake tokens to `validator`'s pool without minting shares, growing every
    ///         delegator's stake pro-rata. Raw transfers are ignored by the accounting, so
    ///         compounding must come through here.
    function compoundReward(address validator, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        StakingStorage storage $ = _s();
        if ($.totalShares[validator] == 0) revert NoStakers();
        uint256 tStaked = $.totalStaked[validator];
        if (tStaked == 0) revert PoolCollapsed();
        // Compounded stake carries election weight like delegated stake, so the cap binds here
        // too or it is trivially bypassed.
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
    function _settle(StakingStorage storage $, address validator, address user) private {
        $.accrued[validator][user] += _pendingReward($, validator, user);
        $.userPaid[validator][user] = $.accRewardPerShare[validator];
    }

    /// @dev The per-validator delegation cap, against what the pool would then hold; 0 is
    ///      uncapped.
    function _checkCap(StakingStorage storage $, uint256 staked) private view {
        uint256 cap = $.maxDelegated;
        if (cap != 0 && staked > cap) revert DelegationCap();
    }

    /// @dev Rewards accrued since `user` last settled against `validator`'s accumulator.
    ///      The one accrual formula — `earned` must always report what `claim` will pay.
    function _pendingReward(StakingStorage storage $, address validator, address user)
        private
        view
        returns (uint256)
    {
        return $.shares[validator][user].fullMulDiv(
            $.accRewardPerShare[validator] - $.userPaid[validator][user], ACC
        );
    }

    // -- share/token conversion ----------------------------------------------
    // The virtual-offset rate lives in these three helpers only, so the offset and each call
    // site's rounding direction cannot drift apart.
    function _toShares(uint256 tShares, uint256 tStaked, uint256 amount)
        private
        pure
        returns (uint256)
    {
        return amount.fullMulDiv(tShares + VIRTUAL_SHARES, tStaked + VIRTUAL_STAKE);
    }

    function _toSharesUp(uint256 tShares, uint256 tStaked, uint256 amount)
        private
        pure
        returns (uint256)
    {
        return amount.fullMulDivUp(tShares + VIRTUAL_SHARES, tStaked + VIRTUAL_STAKE);
    }

    function _toTokens(uint256 tShares, uint256 tStaked, uint256 shares)
        private
        pure
        returns (uint256)
    {
        return shares.fullMulDiv(tStaked + VIRTUAL_STAKE, tShares + VIRTUAL_SHARES);
    }

    // -- slashing ------------------------------------------------------------
    /// @notice Slash `bps` of `validator`'s acquired candidacy bond. Delegated stake, live or
    ///         unbonding, is untouched; a bond unbonding after a resignation is not.
    /// @dev Callable by the protocol system caller (address(0)) or the owner.
    function slash(address validator, uint256 bps, address recipient)
        external
        nonReentrant
        returns (uint256 seized)
    {
        if (msg.sender != address(0) && msg.sender != owner()) revert NotAuthorized();
        if (bps == 0 || bps > BPS) revert InvalidBps();
        if (recipient == address(0)) revert ZeroAddress();
        StakingStorage storage $ = _s();

        uint256 bond = $.bondPaid[validator];
        seized = (bond * bps) / BPS;
        if (seized != 0) {
            $.bondPaid[validator] = bond - seized;
            SafeTransferLib.safeTransfer($.stakeToken, recipient, seized);
        }
        emit Slashed(validator, bps, seized, recipient);
    }

    // -- candidacy -----------------------------------------------------------
    /// @notice Add or remove an electable validator. Owner curation posts no bond; any bond
    ///         already held exits through `_removeCandidate`.
    function setCandidate(address validator, bool active) external onlyOwner {
        if (validator == address(0)) revert ZeroAddress();
        if (active) {
            _addCandidate(validator);
        } else {
            _removeCandidate(validator);
        }
    }

    /// @notice Self-register as an electable validator by posting the NVNM candidacy bond.
    function registerCandidate() external nonReentrant {
        StakingStorage storage $ = _s();
        uint256 bond = $.candidacyBond;
        if (bond == 0) revert CandidacyClosed();
        // A prior bond still unbonding must be withdrawn first: overwriting it here would lose
        // the balance and let an operator cycle resign/re-register to shed slashing exposure.
        if ($.bondReleaseAt[msg.sender] != 0) revert StillUnbonding();
        $.bondPaid[msg.sender] = bond;
        _addCandidate(msg.sender);
        SafeTransferLib.safeTransferFrom($.stakeToken, msg.sender, address(this), bond);
    }

    /// @notice Resign candidacy; the bond unbonds and is claimed with `withdrawBond`.
    function resignCandidate() external nonReentrant {
        _removeCandidate(msg.sender);
    }

    /// @notice Withdraw your matured candidacy bond, net of any slashing during unbonding.
    function withdrawBond() external nonReentrant returns (uint256 amount) {
        StakingStorage storage $ = _s();
        uint256 releaseAt = $.bondReleaseAt[msg.sender];
        if (releaseAt == 0) revert NothingToWithdraw();
        if (block.timestamp < releaseAt) revert StillUnbonding();
        amount = $.bondPaid[msg.sender];
        $.bondPaid[msg.sender] = 0;
        $.bondReleaseAt[msg.sender] = 0;
        if (amount != 0) SafeTransferLib.safeTransfer($.stakeToken, msg.sender, amount);
        emit BondWithdrawn(msg.sender, amount);
    }

    function _addCandidate(address validator) private {
        StakingStorage storage $ = _s();
        if ($.candidateIndex[validator] != 0) revert AlreadyCandidate();
        // The consensus layer eth_calls computeCommittee() every epoch under a fixed gas
        // budget, and this bound is what keeps that read inside it. Owner curation is bounded
        // too: an over-long list drops every node to the registry fallback at once.
        if ($.candidates.length >= MAX_CANDIDATES) revert CandidateListFull();
        // Re-entering the set cancels unbonding on a bond already held — electable again means
        // at risk again, and otherwise `withdrawBond` drains a live candidate's bond.
        $.bondReleaseAt[validator] = 0;
        $.candidates.push(validator);
        $.candidateIndex[validator] = $.candidates.length;
        emit CandidateSet(validator, true);
    }

    /// @dev Candidacy, and so election weight, ends at once; the bond unbonds and stays
    ///      slashable until `withdrawBond`.
    function _removeCandidate(address validator) private {
        StakingStorage storage $ = _s();
        uint256 idx = $.candidateIndex[validator];
        if (idx == 0) revert NotCandidate();
        address[] storage list = $.candidates;
        address last = list[list.length - 1];
        list[idx - 1] = last;
        $.candidateIndex[last] = idx;
        list.pop();
        $.candidateIndex[validator] = 0;
        emit CandidateSet(validator, false);
        uint256 bond = $.bondPaid[validator];
        if (bond == 0) return;
        uint256 period = $.unbondingPeriod;
        if (period == 0) {
            $.bondPaid[validator] = 0;
            SafeTransferLib.safeTransfer($.stakeToken, validator, bond);
            emit BondWithdrawn(validator, bond);
        } else {
            uint256 releaseAt = block.timestamp + period;
            $.bondReleaseAt[validator] = releaseAt;
            emit BondUnbonding(validator, bond, releaseAt);
        }
    }

    // -- committee election --------------------------------------------------
    /// @notice Election knobs: committee size (21 at Phase 5), acquired-stake overweight, and
    ///         the per-validator delegation cap.
    function setCommitteeConfig(
        uint256 maxCommittee,
        uint256 acquiredWeight_,
        uint256 maxDelegated_
    ) external onlyOwner {
        if (maxCommittee == 0) revert ZeroAmount();
        StakingStorage storage $ = _s();
        $.maxSeats = maxCommittee;
        $.acquiredWeight = acquiredWeight_;
        $.maxDelegated = maxDelegated_;
        emit CommitteeConfigSet(maxCommittee, acquiredWeight_, maxDelegated_);
    }

    /// @notice Set the acquired-stake floor for electability — the 1M NVNM minimum. 0 disables
    ///         it (the PoA phases, where the owner curates candidates and no bond is posted).
    function setMinAcquired(uint256 minAcquired_) external onlyOwner {
        _s().minAcquired = minAcquired_;
        emit MinAcquiredSet(minAcquired_);
    }

    /// @notice Set the committee viability floor: electing fewer than `minSeats` members
    ///         elects nobody, dropping every node to the registry fallback together instead
    ///         of seating a committee below the intended fault tolerance. 0 disables it.
    function setMinSeats(uint256 minSeats_) external onlyOwner {
        _s().minSeats = minSeats_;
        emit MinSeatsSet(minSeats_);
    }

    /// @notice Set the NVNM bond for permissionless candidacy (0 closes self-registration).
    function setCandidacyBond(uint256 bond) external onlyOwner {
        _s().candidacyBond = bond;
        emit CandidacyBondSet(bond);
    }

    /// @notice Top-`maxSeats` candidates by `bond * acquiredWeight + delegated`, one seat each.
    ///         Candidates below the `minAcquired` floor, or with zero weight, are dropped;
    ///         ties keep candidate-list order. Unconfigured (`maxSeats` 0), or seating fewer
    ///         than `minSeats` members, elects nobody.
    /// @dev The consensus layer reads this at a chosen block, and that read is itself the
    ///      stake snapshot. Seats are always 1: the threshold-simplex engine is unit-weighted.
    ///      Unconfigured must return empty rather than revert: the node treats a revert as a
    ///      node-local read failure and stalls its epoch feed, while an empty committee routes
    ///      every node into the designed registry fallback together.
    function computeCommittee()
        external
        view
        returns (address[] memory vals, uint256[] memory seats)
    {
        StakingStorage storage $ = _s();
        uint256 maxSeats = $.maxSeats;
        if (maxSeats == 0) return (vals, seats);

        uint256 weightMul = $.acquiredWeight;
        if (weightMul == 0) weightMul = 1;
        uint256 floor = $.minAcquired;
        uint256 cap = $.maxDelegated;

        uint256 n = $.candidates.length;
        address[] memory cv = new address[](n);
        uint256[] memory cweight = new uint256[](n);
        uint256 m;
        for (uint256 i; i < n; ++i) {
            address c = $.candidates[i];
            uint256 acquired = $.bondPaid[c];
            if (acquired < floor) continue; // delegation alone never buys a seat
            // The cap binds at the read too: lowering it must shed an incumbent's excess
            // election weight, not just refuse new stake.
            uint256 delegated = $.totalStaked[c];
            if (cap != 0 && delegated > cap) delegated = cap;
            // Saturating: this read must be total. Checked overflow (an absurd owner-set
            // weight against a large bond) would be a deterministic revert, and the node
            // maps that to a stalled epoch feed — not the registry fallback.
            uint256 w = acquired.saturatingMul(weightMul).saturatingAdd(delegated);
            if (w == 0) continue;
            cv[m] = c;
            cweight[m] = w;
            ++m;
        }

        for (uint256 i = 1; i < m; ++i) {
            address v = cv[i];
            uint256 s = cweight[i];
            uint256 j = i;
            for (; j > 0 && cweight[j - 1] < s; --j) {
                cv[j] = cv[j - 1];
                cweight[j] = cweight[j - 1];
            }
            cv[j] = v;
            cweight[j] = s;
        }

        uint256 count = m < maxSeats ? m : maxSeats;
        // Below the viability floor the election seats nobody: better every node falls back
        // to the full registry together than consensus runs on a committee smaller than
        // governance considers safe.
        if (count < $.minSeats) return (vals, seats);
        vals = new address[](count);
        seats = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            vals[i] = cv[i];
            seats[i] = 1;
        }
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

    /// @notice Outstanding pool shares — the quantity `depositReward` divides by, and so the
    ///         one a caller must check before depositing.
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

    /// @notice A departed candidate's unbonding bond. `releaseAt == 0` means not unbonding —
    ///         still an active candidate, or already withdrawn.
    function pendingBondOf(address validator)
        external
        view
        returns (uint256 amount, uint256 releaseAt)
    {
        StakingStorage storage $ = _s();
        releaseAt = $.bondReleaseAt[validator];
        amount = releaseAt == 0 ? 0 : $.bondPaid[validator];
    }

    function bondOf(address validator) external view returns (uint256) {
        return _s().bondPaid[validator];
    }

    function candidates() external view returns (address[] memory) {
        return _s().candidates;
    }

    function candidacyBond() external view returns (uint256) {
        return _s().candidacyBond;
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
        returns (uint256 maxCommittee, uint256 acquiredWeight_, uint256 maxDelegated_)
    {
        StakingStorage storage $ = _s();
        return ($.maxSeats, $.acquiredWeight, $.maxDelegated);
    }

    function unbondingPeriod() external view returns (uint256) {
        return _s().unbondingPeriod;
    }

    function stakeToken() external view returns (address) {
        return _s().stakeToken;
    }

    function rewardToken() external view returns (address) {
        return _s().rewardToken;
    }

    // -- upgrade authority ---------------------------------------------------
    function _authorizeUpgrade(address) internal override onlyOwner { }

    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }
}
