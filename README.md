# nvnmchain-contracts

Application contracts for NVM. Economics (token, staking, fee split) live here as
upgradeable contracts; the node reads them only through an opt-in consensus hook
(`stakingElection` → `NVNMStaking.computeCommittee()`). The anchoring precompile
is enshrined in the node; this repo talks to it through `IAnchoring`.

## Registry + RegistryFactory

One contract per registry: versioned checksum records with scoped role-based access control,
deployed by a factory.

The precompile at `0x…0a00` is a *caller-partitioned* commitment log, so a registry's own
address is its partition — `IAnchoring.latest(registry, key)` is the on-chain source of truth,
and no key, mapping or envelope carries a registry id. A single contract fronting many
registries would throw that partition away and rebuild it by hand.

The contract anchors rather than stores: every record version and status is committed through
the precompile, and only what authorization and id assignment need — counters and role
membership — lives in contract storage. Each envelope leads with a `bytes32` kind (`record`,
`status`), so an indexer classifies a payload from the log rather than by matching it against
a derived key. Envelopes stay distinct per version — the version `index`, and a sequence
number for status — so re-anchoring identical content is a new version rather than a
`CommitmentUnchanged` revert.

Role changes are **not** anchored. Membership is the registry's state, read with `hasRole`,
and history is its own `RoleGranted`/`RoleRevoked`, which carry every field. A third copy in
the anchored log would only be something to drift.

Roles are registry-scoped (the whole contract, needing no derivation — the role is its own id)
or record-scoped (one checksum within it), over `admin` and `editor`. The owner (a Safe) is the
break-glass admin: it may grant a registry `admin` without holding one, which is what keeps the
"last admin cannot be revoked" rule recoverable.

Registries are immutable: upgrading means deploying a new one and re-granting its roles.
What a registry anchors is a commitment, provable under the address that wrote it forever, so
a replacement splits the history across two addresses rather than invalidating any of it.
Registry name, description and metadata ride in `RegistryDeployed` rather than an anchor:
descriptive, set once, nothing to prove.

## Staking and fees

Fee waterfall and delegated staking on a fixed-supply NVNM token. Rewards are
deposited, never minted.

- **FeeRouter / FeeRouterFactory** — per-validator `feeRecipient`. Factory-owned
  protocol cuts are **devshare + buybacks** (Phase 1: 25/25); Option A/B is
  `setProtocolSplit`. The remainder is the validator allocation: `commissionBps`
  to the operator, the rest to that validator's delegators, or all of it to the
  operator when the pool is empty (PoA). Buybacks go to a declared wallet,
  optionally swapped to NVNM first, and never compound into a validator pool. A
  swapper that rejects the trade does not stall the flush; the cut is forwarded
  as stablecoin instead. `flush` takes a token, since `FeeManager` bills each
  payer in the token they chose and every one of them owes the cuts. Only the
  pool's own reward token reaches delegators; another token's delegator share is
  escrowed for governance rather than paid to the operator, and held out of the
  flushable balance so a permissionless re-flush cannot cut it twice.
- **NVNMStaking** — per-validator share pools and **bond-only slash**:
  delegators are never slashed. `computeCommittee` is top-N (21 at Phase 5) by
  `acquired * acquiredWeight + delegated`, one equal seat each, capped per
  validator by `maxDelegated`. Seating fewer than `minSeats` members elects
  nobody, dropping every node to the registry fallback together rather than
  running consensus on a committee below the intended fault tolerance.
  `candidacyBond` is the 1M NVNM acquired stake and
  `minAcquired` the floor that enforces it at election time — below it,
  delegation alone never buys a seat. Stake and bonds both leave through the
  unbonding delay, and a departing bond stays slashable until `withdrawBond` —
  so once a nonzero `unbondingPeriod` is set (the storage default is 0,
  immediate), an operator cannot resign ahead of its own slash.
- **GuardedSwapper** — buyback-market wrapper: per-swap size cap plus a two-sided
  price floor, `maxDeviationBps` against an EMA of recent swaps and `maxDriftBps`
  against the owner-seeded `refPrice`. The second is what stops the EMA being
  walked down a swap at a time; a manipulated high print is clamped on its way
  into the EMA, so the floor cannot be ratcheted up either. Only the owner and
  the factory's routers may swap.
- **BridgedNVNM** — L1 ERC-20; only Safe-curated BRIDGE adapters mint/burn.

Two things the phase plan needs that these contracts do not enforce: nothing
binds a validator's registry `feeRecipient` to a router, so one pointing at an
EOA pays no devshare or buyback; and the phase gates (TTM revenue, the 5 → 9 →
15 → 21 ramp) are governance calls on `maxSeats`, not on-chain conditions.

## Layout

- `src/Registry.sol` — one registry, deployed outright and immutable
- `src/RegistryFactory.sol` — deploys registries and holds the implementation pointer
- `src/interfaces/IAnchoring.sol` — the precompile's interface and address
- `src/NVNMStaking.sol` — delegated staking and committee election
- `src/FeeRouter.sol` — per-validator fee splitter and factory
- `src/GuardedSwapper.sol` — guarded buyback swapper
- `src/BridgedNVNM.sol` — bridged NVNM ERC-20
- `test/support/MockAnchoring.sol` — a stand-in for the precompile, etched at its address so
  tests run in a plain forge EVM
- `test/support/RegistryDeployer.sol` — one-shot factory deploy, for local and e2e use
- `test/support/StakingDeployer.sol` — one-shot staking + mock tokens, for local and e2e use

## Develop

```sh
forge build
forge test
```

The precompile itself lives in the node repo (`crates/precompiles/src/anchoring/`); this repo
depends on it only through `IAnchoring`. The epoch-feed hook lives in the node
(`crates/consensus`); leave `stakingElection` unset for PoA.
