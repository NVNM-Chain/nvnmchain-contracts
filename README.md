# nvnm-contracts

Application contracts for NVM, built on the anchoring precompile enshrined in the node.

## AnchoringRegistry

Named registries of versioned checksum records, with scoped role-based access control.

The contract anchors rather than stores: every registry, record version, status, and ACL
change is committed through the anchoring precompile at `0x…0a00` under this contract's own
address, so `IAnchoring.latest(registry, key)` is the on-chain source of truth and indexers
rebuild history from `Anchored` events. Only what authorization and id assignment need —
counters and role membership — lives in contract storage.

Roles are registry-scoped or record-scoped (one checksum within one registry) over `admin`
and `editor`; a grant in one registry never authorizes another sharing the same checksum.
The owner (a Safe) is the upgrade authority and break-glass admin: it may grant a registry
`admin` without holding one, which is what keeps the "last admin cannot be revoked" rule
recoverable.

## Layout

- `src/AnchoringRegistry.sol` — the UUPS registry contract
- `src/interfaces/IAnchoring.sol` — the precompile's interface and address
- `test/support/MockAnchoring.sol` — a stand-in for the precompile, etched at its address so
  tests run in a plain forge EVM
- `test/support/AnchoringDeployer.sol` — one-shot impl + ERC-1967 proxy deploy, for local and
  e2e use

## Develop

```sh
forge build
forge test
```

The precompile itself lives in the node repo (`crates/precompiles/src/anchoring/`); this repo
depends on it only through `IAnchoring`.
