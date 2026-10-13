// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice A market that sells `tokenIn` for `tokenOut` (pulls `amountIn` from the caller).
interface ISwapper {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut) external returns (uint256 out);
}

/// @notice A swapper that caps each swap, as `GuardedSwapper` does. Routers swap at most this.
interface ISwapCap {
    function maxAmountIn() external view returns (uint256);
}
