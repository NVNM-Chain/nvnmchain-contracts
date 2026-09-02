// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { BPS } from "./Constants.sol";
import { FeeRouterFactory } from "./FeeRouter.sol";
import { ISwapper } from "./interfaces/ISwapper.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

/// @title GuardedSwapper
/// @notice The production-shaped `ISwapper` for fee buybacks: wraps an inner market for one
///         fixed (tokenIn → tokenOut) pair and enforces a per-swap size cap plus a minimum
///         execution price. A sandwiched or manipulated pool makes the swap revert instead of
///         donating the buyback — routers hold funds and retry.
/// @dev The floor is two-sided and both legs bind: `maxDeviationBps` against the EMA of
///      recent swaps absorbs honest drift, and `maxDriftBps` against the owner-seeded
///      `refPrice` is what stops the EMA being walked down — alone it decays with the price
///      it guards, ~0.6% per swap at 300/2000.
///
///      `swap` is owner-and-routers-only: open, moving the EMA is near-free, since a direct
///      caller keeps the output where a router's goes to the buyback wallet. Router creation
///      is permissionless, so the gate makes that costly rather than impossible — which is
///      why the EMA input is also clamped on the upside, or one manipulated high print
///      ratchets the floor above the honest price until a reseed.
///
///      `owner` (the Safe) seeds the price and tunes the guards; the inner market stays
///      swappable. `FeeRouterFactory.swapper` should point here.
contract GuardedSwapper is Ownable, ISwapper {
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

    event GuardsSet(
        address inner, uint256 maxAmountIn, uint256 maxDeviationBps, uint256 emaAlphaBps
    );
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

    function setGuards(
        address inner_,
        uint256 maxAmountIn_,
        uint256 maxDeviationBps_,
        uint256 emaAlphaBps_
    ) external onlyOwner {
        if (maxDeviationBps_ > BPS || emaAlphaBps_ > BPS) {
            revert InvalidBps();
        }
        inner = inner_;
        maxAmountIn = maxAmountIn_;
        maxDeviationBps = maxDeviationBps_;
        emaAlphaBps = emaAlphaBps_;
        emit GuardsSet(inner_, maxAmountIn_, maxDeviationBps_, emaAlphaBps_);
    }

    /// @notice How far below the seeded `refPrice` execution may fall, however far the EMA has
    ///         drifted. 0 pins the floor to `refPrice` exactly; BPS disables this leg.
    function setDriftBand(uint256 maxDriftBps_) external onlyOwner {
        if (maxDriftBps_ > BPS) revert InvalidBps();
        maxDriftBps = maxDriftBps_;
        emit DriftBandSet(maxDriftBps_);
    }

    /// @notice The `FeeRouterFactory` whose routers may call `swap`. 0 leaves the owner as the
    ///         only caller.
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
        out = ISwapper(market).swap(tokenIn, tokenOut, amountIn, minOut);

        uint256 price = (out * WAD) / amountIn;
        // Every accepted price is at or above the reference floor, so the EMA — a convex
        // combination of accepted prices and its own past — can never sink below it either.
        uint256 floorPrice = (ema * (BPS - maxDeviationBps)) / BPS;
        uint256 refFloor = (refPrice * (BPS - maxDriftBps)) / BPS;
        if (floorPrice < refFloor) floorPrice = refFloor;
        if (price < floorPrice) revert PriceBelowFloor();

        // High prints pay out in full but pull on the EMA only inside the deviation band:
        // otherwise one manipulated print ratchets the floor above the honest price and every
        // later buyback reverts until the owner reseeds.
        uint256 emaInput = price;
        uint256 ceilPrice = (ema * (BPS + maxDeviationBps)) / BPS;
        if (emaInput > ceilPrice) emaInput = ceilPrice;
        emaPrice = (emaInput * emaAlphaBps + ema * (BPS - emaAlphaBps)) / BPS;
        SafeTransferLib.safeTransfer(tokenOut, msg.sender, out);
        emit GuardedSwap(amountIn, out, price, emaPrice);
    }

    function _authorized(address caller) private view returns (bool) {
        if (caller == owner()) return true;
        address factory = routerFactory;
        return factory != address(0) && FeeRouterFactory(factory).isRouter(caller);
    }
}
