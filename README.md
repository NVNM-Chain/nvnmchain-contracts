# nvnmchain-contracts

Application contracts for NVM, built on the anchoring precompile enshrined in the node.

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

## Layout

- `src/Registry.sol` — one registry, deployed outright and immutable
- `src/RegistryFactory.sol` — deploys registries and holds the implementation pointer
- `src/interfaces/IAnchoring.sol` — the precompile's interface and address
- `test/support/MockAnchoring.sol` — a stand-in for the precompile, etched at its address so
  tests run in a plain forge EVM
- `test/support/RegistryDeployer.sol` — one-shot factory deploy, for local
  and e2e use

## Develop

```sh
forge build
forge test
```

The precompile itself lives in the node repo (`crates/precompiles/src/anchoring/`); this repo
depends on it only through `IAnchoring`.
