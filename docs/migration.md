# Migrating from the precompile

On the old chain (L2), anchoring was the `x/anchoring` precompile. On Tempo (L1) it is a contract
at the same address, `0x…0a00`, holding the same data.

## What stays the same

The eight methods and five events keep the same selectors, event topics and indexed fields, and
`test/Selectors.t.sol` pins them. A client only needs a new RPC URL and chain id.

The contract also adds:

- role views: `hasRole`, `roleMemberCount`, `getRoleAdmin`;
- from T12, ownership (`owner`, `transferOwnership`) and upgrades (`upgradeToAndCall`,
  `Upgraded`).

## What behaves differently

Same selectors do not mean identical behavior. From T12:

- **Name search.** `registriesByName` answers exact matches only, ignoring ASCII case; call it
  with `eth_call`. Prefix, suffix and contains searches revert. A node started with
  `--anchoring.name-index` serves them through the `anchoring_searchRegistriesByName` RPC.
- **Timestamps.** `timestamp` and `createdAt` keep the old string format, but Tempo's block time
  is whole seconds. A row written on Tempo reads `2026-07-30 15:04:00 +0000 UTC`, where the old
  chain wrote `2026-07-30 15:04:00.973906311 +0000 UTC`. Copied timestamps keep the nanoseconds.
- **Errors.** Revert messages leave out values: `registry does not exist`, not
  `registry 7 does not exist`. A call that sends value is refused.
- **Zero address.** `grantRole` refuses the zero address. The old chain accepted it and counted it
  as an admin, so a registry's last real admin could make the zero address admin, step down, and
  leave the registry with no admin anyone controls.
- **Lookup by checksum.** `records` with only a checksum lists registries in the order each first
  anchored that checksum. The old chain listed them by ascending id, and copied data keeps that
  order.
- **Listing all records.** `records` with no filter reads at most 200 registries per call, so a
  page can come back short, or empty, before the end. Pass `pagination.nextKey` back with offset
  0 until `nextKey` comes back empty.
- **Contract callers.** Contracts may call every method. The old chain took writes only from EOAs,
  to block an IBC callback path that Tempo does not have.

Before T12, only the first three apply.

## Which code runs

| | Code at `0x…0a00` | Owner |
|---|---|---|
| Before T12 | the launch build, commit `5b6b126`, keccak `0x893a…7c0e`; only EOAs may write | none |
| From T12 | the proxy `layout/proxy.bin`, keccak `0xaaa5…890d`, over the implementation in `deployment.json` | storage slot 11 |

At the first block from T12 in which the implementation is deployed, the chain swaps the launch
build for the proxy and copies `ValidatorConfigV2`'s owner into slot 11. Until then the launch
build keeps running. A chain that starts at T12 has the proxy from genesis, with the owner named
in genesis.

The testnet launched on the launch build and switches at T12. Mainnet starts at T12.

## Data

The data comes from a snapshot of the old chain running the chain repo's `841ce88`. The dump writer
in the chain repo (`x/anchoring/evmlayout`) turns that snapshot into Tempo's genesis state: every
registry, record version, status, role and index, under the same ids.

Nothing written on the old chain after the snapshot is copied.

## Ownership

The old chain's module admin was a Cosmos multisig with no EVM key. The migration keeps that
address in `_formerAdmin`, a slot nothing reads.

On Tempo the owner can make any address a registry admin, upgrade the implementation and transfer
ownership. The owner holds no registry role unless it grants one to itself.

Registry roles are copied as they are, and a key has the same address on both chains, so whoever
administered a registry on the old chain still does on Tempo. A registry whose only admin cannot
sign on Tempo, such as registry 1, stays frozen until the owner appoints a new admin.

## Funds

The contract holds no funds, and Tempo refuses any call to it that sends value. Account balances
are not anchoring data, so the migration does not move them.
