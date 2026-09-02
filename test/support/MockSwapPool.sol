// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

/// @dev Minimal constant-product pool for tests and local/e2e deploys — seed once, swap x*y=k,
///      no fees, no LP accounting. NOT production code; the real swapper is an owner decision.
contract MockSwapPool {
    address public immutable tokenA;
    address public immutable tokenB;

    error BadPair();
    error SlippageExceeded();

    constructor(address tokenA_, address tokenB_) {
        tokenA = tokenA_;
        tokenB = tokenB_;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        external
        returns (uint256 out)
    {
        if (!(tokenIn == tokenA && tokenOut == tokenB || tokenIn == tokenB && tokenOut == tokenA)) revert BadPair();
        uint256 rIn = SafeTransferLib.balanceOf(tokenIn, address(this));
        uint256 rOut = SafeTransferLib.balanceOf(tokenOut, address(this));
        SafeTransferLib.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        out = (rOut * amountIn) / (rIn + amountIn);
        if (out < minOut) revert SlippageExceeded();
        SafeTransferLib.safeTransfer(tokenOut, msg.sender, out);
    }
}
