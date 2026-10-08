// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BPS} from "./Constants.sol";
import {FeeRouterFactory} from "./FeeRouter.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title GuardedSwapper
/// @notice The `ISwapper` fee buybacks run through: one fixed (tokenIn → tokenOut) pair behind a
///         per-swap size cap and a minimum execution price, so a sandwiched pool makes the swap
///         revert instead of donating the buyback. Routers hold the funds and retry.
/// @dev The floor is two-sided and both legs bind. `maxDeviationBps` against the EMA absorbs
///      honest drift; `maxDriftBps` against the owner-seeded `refPrice` is what stops the EMA
///      being walked down, since alone it decays with the price it guards.
///
///      `swap` is routers-only because moving the EMA is otherwise near-free: a direct caller,
///      the owner included, keeps the output, where a router's goes to the buyback sink. Anyone
///      may create a router for itself, so the gate makes that costly rather than impossible. It
///      is also guarded: the inner market runs before the EMA moves, and a market re-entering
///      through another router would otherwise be judged against the stale price.
contract GuardedSwapper is Ownable, ReentrancyGuard, ISwapper {
    uint256 private constant WAD = 1e18;

    address public immutable tokenIn; // fee stablecoin
    address public immutable tokenOut; // NVNM

    address public inner; // the actual market
    address public routerFactory; // FeeRouterFactory whose routers may swap
    uint256 public maxAmountIn; // per-swap size cap
    uint256 public maxDeviationBps; // allowed drop below the EMA execution price
    uint256 public maxDriftBps; // allowed drop below the seeded reference price
    uint256 public emaAlphaBps; // EMA weight of the newest observation
    uint256 public emaPrice; // tokenOut per WAD tokenIn; 0 until seeded
    uint256 public refPrice; // owner-seeded reference; the EMA cannot decay past its band

    event GuardsSet(address inner, uint256 maxAmountIn, uint256 maxDeviationBps, uint256 emaAlphaBps);
    event DriftBandSet(uint256 maxDriftBps);
    event RouterFactorySet(address routerFactory);
    event PriceSeeded(uint256 price);
    event GuardedSwap(uint256 amountIn, uint256 amountOut, uint256 price, uint256 emaPrice);

    error WrongPair();
    error NotSeeded();
    error InvalidBps();
    error ZeroAmount();
    error AmountTooLarge();
    error PriceBelowFloor();
    error NotAuthorized();

    constructor(address owner_, address tokenIn_, address tokenOut_) {
        _initializeOwner(owner_);
        tokenIn = tokenIn_;
        tokenOut = tokenOut_;
    }

    function setGuards(address inner_, uint256 maxAmountIn_, uint256 maxDeviationBps_, uint256 emaAlphaBps_)
        external
        onlyOwner
    {
        if (maxDeviationBps_ > BPS || emaAlphaBps_ > BPS) {
            revert InvalidBps();
        }
        inner = inner_;
        maxAmountIn = maxAmountIn_;
        maxDeviationBps = maxDeviationBps_;
        emaAlphaBps = emaAlphaBps_;
        emit GuardsSet(inner_, maxAmountIn_, maxDeviationBps_, emaAlphaBps_);
    }

    /// @notice How far below `refPrice` execution may fall, however far the EMA has drifted.
    ///         0 pins the floor to `refPrice`; BPS disables this leg.
    function setDriftBand(uint256 maxDriftBps_) external onlyOwner {
        if (maxDriftBps_ > BPS) revert InvalidBps();
        maxDriftBps = maxDriftBps_;
        emit DriftBandSet(maxDriftBps_);
    }

    /// @notice The `FeeRouterFactory` whose routers may call `swap`. 0 stops every swap.
    function setRouterFactory(address routerFactory_) external onlyOwner {
        routerFactory = routerFactory_;
        emit RouterFactorySet(routerFactory_);
    }

    /// @notice Seed or reset both the reference price and the EMA (tokenOut per 1e18 tokenIn).
    function seedPrice(uint256 price) external onlyOwner {
        emaPrice = price;
        refPrice = price;
        emit PriceSeeded(price);
    }

    function swap(address tokenIn_, address tokenOut_, uint256 amountIn, uint256 minOut)
        external
        nonReentrant
        returns (uint256 out)
    {
        if (!_authorized(msg.sender)) revert NotAuthorized();
        if (tokenIn_ != tokenIn || tokenOut_ != tokenOut) revert WrongPair();
        uint256 ema = emaPrice;
        address market = inner;
        if (market == address(0) || ema == 0) revert NotSeeded();
        if (amountIn == 0) revert ZeroAmount();
        if (amountIn > maxAmountIn) revert AmountTooLarge();

        SafeTransferLib.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        SafeTransferLib.safeApproveWithRetry(tokenIn, market, amountIn);
        uint256 held = SafeTransferLib.balanceOf(tokenOut, address(this));
        ISwapper(market).swap(tokenIn, tokenOut, amountIn, minOut);
        // What arrived, not what the market reports: an overstated `out` would clear the floor
        // and be paid from whatever tokenOut this contract already holds.
        out = SafeTransferLib.balanceOf(tokenOut, address(this)) - held;

        uint256 price = (out * WAD) / amountIn;
        // Whichever floor binds harder. Every accepted price clears the reference floor, so the
        // EMA — a convex combination of accepted prices and its own past — cannot sink below it.
        uint256 floorPrice =
            FixedPointMathLib.max((ema * (BPS - maxDeviationBps)) / BPS, (refPrice * (BPS - maxDriftBps)) / BPS);
        if (price < floorPrice) revert PriceBelowFloor();

        // A high print pays out in full but pulls on the EMA only inside the band, or one
        // manipulated print ratchets the floor above the honest price until the owner reseeds.
        uint256 emaInput = FixedPointMathLib.min(price, (ema * (BPS + maxDeviationBps)) / BPS);
        emaPrice = (emaInput * emaAlphaBps + ema * (BPS - emaAlphaBps)) / BPS;
        SafeTransferLib.safeTransfer(tokenOut, msg.sender, out);
        emit GuardedSwap(amountIn, out, price, emaPrice);
    }

    function _authorized(address caller) private view returns (bool) {
        address factory = routerFactory;
        return factory != address(0) && FeeRouterFactory(factory).isRouter(caller);
    }
}
