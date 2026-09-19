# nvnmchain-contracts

Application contracts for NVM.

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
