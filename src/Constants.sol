// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @dev The basis-point denominator every bps parameter here is read against — a commission,
///      a protocol cut and a price band all mean the same thing by 10_000.
uint256 constant BPS = 10_000;
