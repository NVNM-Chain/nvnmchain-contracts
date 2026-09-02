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

- **FeeRouter / FeeRouterFactory** — per-validator `feeRecipient`. The factory owns the
  protocol cuts (devshare + buybacks, 25/25 at Phase 1; Option A/B is `setProtocolSplit`);
  the remainder splits into operator commission and delegator rewards, so the delegator
  share comes out of the validator allocation rather than off the top. `flush` is
  permissionless, which is what most of its rules are for.
- **NVNMStaking** — per-validator share pools, bond-only slash (delegators are never
  slashed), and the committee election the node reads: top-N (21 at Phase 5) by
  `acquired * acquiredWeight + delegated`, one equal seat each. `candidacyBond` is the 1M
  NVNM acquired stake and `minAcquired` enforces it at election time; `minSeats` refuses
  to seat a committee below the intended fault tolerance, dropping every node to the
  registry fallback together instead.
- **GuardedSwapper** — buyback-market wrapper: a per-swap size cap and a two-sided price
  floor, so a sandwiched pool makes the swap revert instead of donating the buyback. Only
  the owner and the factory's routers may swap.
- **BridgedNVNM** — L1 ERC-20; only Safe-curated BRIDGE adapters mint/burn.

Each contract's own NatSpec carries the rest — why `flush` takes a token, why the EMA
floor is two-sided, why a departing bond stays slashable.

Two things the phase plan needs that these contracts do not enforce: nothing
binds a validator's registry `feeRecipient` to a router, so one pointing at an
EOA pays no devshare or buyback; and the phase gates (TTM revenue, the 5 → 9 →
15 → 21 ramp) are governance calls on `maxSeats`, not on-chain conditions.

### One pool or one per validator

Pools are keyed by an address, and nothing requires that address to be a real
validator. Pointing every router at one sentinel key gives a single pool that
every staker shares and every validator pays into — no operator to choose, and
one `earned` call covers the lot. That is the shape Phases 1–4 want, where there
is no holder staking to allocate anyway.

The cost is that `totalStaked` is then zero for each actual candidate, so
`computeCommittee` ranks on the bond alone and `acquiredWeight` and
`maxDelegated` bind on nothing. Delegation earns yield but does not select the
set. Moving to per-validator pools at Phase 5 turns both back on and needs no
contract change — which is why the pools stay keyed per address rather than
collapsing into one.

## Layout

- `src/Registry.sol` — one registry, deployed outright and immutable
- `src/RegistryFactory.sol` — deploys one Registry per registry, outright
- `src/interfaces/IAnchoring.sol` — the precompile's interface and address
- `src/NVNMStaking.sol` — delegated staking and committee election
- `src/FeeRouter.sol` — per-validator fee splitter and factory
- `src/GuardedSwapper.sol` — guarded buyback swapper
- `src/BridgedNVNM.sol` — bridged NVNM ERC-20
- `test/support/MockAnchoring.sol` — a stand-in for the precompile, etched at its address so
  tests run in a plain forge EVM
- `test/support/RegistryDeployer.sol` — one-shot factory deploy, for local and e2e use
- `test/support/StakingDeployer.sol` — one-shot staking + mock tokens, for local and e2e use
- `test/support/MockERC20.sol`, `test/support/MockSwapPool.sol` — a plain token and a
  fixed-rate market, for the fee and buyback tests

## Develop

```sh
forge build
forge test
```

The precompile itself lives in the node repo (`crates/precompiles/src/anchoring/`); this repo
depends on it only through `IAnchoring`. The epoch-feed hook lives in the node
(`crates/consensus`); leave `stakingElection` unset for PoA.
