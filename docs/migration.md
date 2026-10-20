# Migrating from the precompile

The anchoring contract takes over from the old chain's `x/anchoring` precompile (L2) on Tempo
(L1), at the same address, `0x…0a00`.

## Interface

The precompile's eight methods and five events keep their selectors, topics and indexed fields;
`test/Selectors.t.sol` pins the selectors and topics. A caller changes RPC and chain id. The
contract adds role views (`hasRole`, `roleMemberCount`, `getRoleAdmin`), ERC-173 ownership and
the UUPS upgrade (`upgradeToAndCall`, `Upgraded`).

Same selectors do not mean identical behavior. From T12 a caller sees:

- An exact name is an `eth_call` to `registriesByName`, ignoring ASCII case. Prefix, suffix and
  contains revert there; they are the node's `anchoring_searchRegistriesByName` RPC, served when
  it runs with `--anchoring.name-index`.
- New records' timestamps have no sub-second part; migrated records keep theirs.
- Revert strings that format a value are shorter, and a call carrying value is refused.
- No role for the zero address.
- A checksum's registries come in the order they first anchored it, ascending for the corpus.
- The unfiltered record page reads at most 200 registries and returns a cursor.
- No EOA gate; the precompile had one to close an IBC callback path Tempo lacks.

The launch build differs in the first three only.

## Builds

| | Code at `0x…0a00` | Owner |
|---|---|---|
| Before T12 | the launch build, `5b6b126`, keccak `0x893a…7c0e`; only EOAs write | none |
| From T12 | `layout/proxy.bin`, keccak `0xaaa5…890d`, over `deployment.json`'s `implementation` | `_owner`, slot 11 |

T12 puts the proxy over the launch build once the implementation is deployed, and copies the
validator registry's owner into slot 11. A chain that starts at T12 has the proxy from genesis,
with the owner its genesis names. The testnet launched on the launch build and takes T12 as a hard
fork; mainnet starts at T12.

## State

The chain repo's dump writer puts the corpus into genesis: every registry, record version,
status, role and index, under the same ids. What the old chain records after the snapshot is not
in it, so the snapshot is taken from a chain that has stopped.

## Ownership

The old chain's module admin is a Cosmos multisig that no EVM key signs for. The dump keeps its
address in `_formerAdmin`, which nothing reads. On Tempo the owner seeds registry admins,
upgrades the implementation and hands itself on; it holds no role, though it can seed one for any
address, its own included.

Registry roles carry over as they are, and a key has the same address on both chains, so registry
admins keep their registries. One whose only admin cannot sign on Tempo, such as registry 1,
stays frozen until the owner seeds an admin.

## Funds

The contract holds none and Tempo refuses calls to it that carry value. Account balances are not
anchoring state and do not move with it.
