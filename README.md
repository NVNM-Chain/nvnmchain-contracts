# nvnmchain-contracts

Application contracts for NVM, including its economics: the token, staking and the fee split.
Only NVNMStaking is upgradeable (UUPS, owned by a timelock). FeeRouter, FeeRouterFactory,
GuardedSwapper and BridgedNVNM change only through their owners' settings or a redeploy.
If genesis sets `stakingElection` to the staking contract, the node picks each epoch's
committee by calling its `computeCommittee(registry)`, and from NVNM1 draws block proposers by
`electionWeight`, the same score for any address, elected or not.

## Staking and fees

Fee waterfall and delegated staking on a fixed-supply NVNM token. Rewards are
deposited, never minted, and vest over `rewardDuration` (a day by default).

- **FeeRouter / FeeRouterFactory** — per-validator `feeRecipient`. `flush` takes the protocol
  cuts in the ratios the lockbox holds — devshare to a fixed recipient, buybacks swapped to
  NVNM for `0x…dEaD` and held on the router until a swap clears — then splits the remainder
  into operator commission and delegator rewards, so the delegator share comes out of the
  validator allocation rather than off the top. `flush` is permissionless, which is what most
  of its rules are for. `setValidatorToken()` has FeeManager pay the router in the pool's
  reward token (USDT0 on mainnet).
- **FeeLockbox** — holds every router's validator share, delegators' included, owed to its
  operator until distribution commences: non-affiliated validators over half the registry's
  active set, and a majority of that set voting for it. The owner declares every validator
  affiliated or not, once, before it can commence. Also holds the fee split (25/25 at
  Phase 1, buybacks never below 20%), which that set votes proposal by proposal: one applies
  once a majority has backed it for `splitDelay`, and before commencement may neither raise
  devshare nor cut the validator share.
- **NVNMStaking** — per-validator share pools, and the committee election the node reads:
  top-N (at most 21) by `acquired * acquiredWeight + delegated`, one equal seat each.
  `candidacyBond` is the 1M NVNM acquired stake, which `minAcquired` enforces at election
  time; below `minSeats` the election returns nobody, and the node then applies its own
  floor, `min(4, registry)`. Its timelock should outlast the 14-day unbonding cap, so
  delegators can leave before an upgrade lands. Slashing takes only the bond, once the
  election is configured, and is the `slasher`'s: a Safe without that delay, or a resigning
  validator would withdraw its bond first.
- **GuardedSwapper** — buyback-market wrapper: a per-swap size cap and a two-sided price
  floor, so a sandwiched pool makes the swap revert instead of donating the buyback. Only
  the factory's routers may swap, not the owner.
- **BridgedNVNM** — L1 ERC-20; only Safe-curated BRIDGE adapters mint/burn.

Each contract's own NatSpec carries the rest — why `flush` takes a token, why the EMA
floor is two-sided, why a departing bond stays slashable.

Two things the phase plan needs that these contracts do not enforce: the registry owner
must point each validator's `feeRecipient` at its router (from NVNM1 the node lets nobody
else set it and pays blocks nowhere else), and the phase gates (TTM revenue, the 5 → 9 →
15 → 21 ramp) are governance calls, not on-chain conditions. Through Phase 4 the ramp
is registry adds, with `maxSeats` left at 0 so the node seats the registry; setting it
is Phase 5, and it also opens slashing.

### One pool or one per validator

Pools are keyed by an address that need not be a real validator, so pointing every
router at one sentinel gives a single shared pool — no operator to choose, and one
`earned` call for the lot. That suits Phases 1–4, which have no holder staking to
allocate.

It costs the election: `totalStaked` is then zero for every candidate, so
`computeCommittee` ranks on the bond alone and `acquiredWeight` and `maxDelegated`
bind on nothing. Per-validator pools turn both back on by configuration rather than
migration, which is why pools stay keyed per address.

## Anchoring

`x/anchoring`'s precompile as a contract with the same ABI, at the same address on Tempo
(`0x…0a00`), so a caller changes chains and nothing else. Five differences: `registriesByName`
matches exactly, folding ASCII case; timestamps have no sub-second part; revert strings that
format values are shorter; a call carrying value reverts with no reason; the module admin skips
the EOA gate on `grantRole`, as `MsgGrantRole` had none.

The corpus arrives through the chain repo's dump writer (`x/anchoring/evmlayout`), not
transactions, so `layout/` is an interface: the slot layout, the slots the contract writes for
`test/SeedFixture.t.sol`'s corpus, and the runtime code for Tempo's genesis alloc.

## Module admin

`Anchoring._admin()` names who may grant a registry admin without holding the role. This build
names nobody, so the break-glass is unreachable; a chain that wants one returns it there and
installs that build at a fork. The migration still writes the source chain's `params.Admin` into
the slot below `_registryCount`, where nothing reads it.

## Develop

```sh
forge build
forge test
make layout        # regenerate layout/
make layout-check  # regenerate, and fail if it differs from git
```

`test/support/StakingDeployer.sol` stands staking up in one call over existing tokens, for
tempo-e2e.

The epoch-feed hook lives in the node (`crates/consensus`); leave `stakingElection` unset for
PoA.
