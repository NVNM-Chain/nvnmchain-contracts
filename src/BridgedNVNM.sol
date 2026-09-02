// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { EnumerableRoles } from "solady/auth/EnumerableRoles.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";

/// @title BridgedNVNM
/// @notice The L1 representation of the NVNM governance/stake token. The canonical fixed supply
///         lives on Ethereum; bridge adapters mint here on deposit and burn on withdrawal, so L1
///         supply always equals the amount currently bridged in. A plain ERC-20 (not a TIP-20
///         stablecoin), so it is usable as `NVNMStaking`'s stake token.
/// @dev `owner` (a Safe) curates the BRIDGE role; only BRIDGE holders mint/burn. There is no
///      direct owner mint, so supply integrity reduces to the Safe's role curation: the owner
///      inflates only by granting BRIDGE, a visible on-chain act, never as a side effect.
contract BridgedNVNM is ERC20, Ownable, EnumerableRoles {
    uint256 public constant BRIDGE = 1;

    constructor(address owner_) {
        _initializeOwner(owner_);
    }

    function name() public pure override returns (string memory) {
        return "NVNM";
    }

    function symbol() public pure override returns (string memory) {
        return "NVNM";
    }

    // Role assignment stays owner-only via EnumerableRoles' default `_authorizeSetRole`.
    function MAX_ROLE() public pure returns (uint256) {
        return BRIDGE;
    }

    /// @notice Mint `amount` to `to` for a bridge deposit.
    function bridgeMint(address to, uint256 amount) external onlyRole(BRIDGE) {
        _mint(to, amount);
    }

    /// @notice Burn `amount` from `from` for a bridge withdrawal (requires allowance if not self).
    function bridgeBurn(address from, uint256 amount) external onlyRole(BRIDGE) {
        if (from != msg.sender) _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
    }
}
