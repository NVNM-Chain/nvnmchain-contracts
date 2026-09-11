# nvnmchain-contracts

Application contracts for NVM.

## Anchoring

`x/anchoring`'s precompile as a contract with the same ABI, at the same address on Tempo
(`0x…0a00`), so a caller changes chains and nothing else. It differs in three ways:
`registriesByName` answers exact match only, the timestamps it writes have no sub-second part,
and revert strings that format values are shorter.

The corpus arrives through the chain repo's dump writer (`x/anchoring/evmlayout`), not
transactions, so `layout/` is an interface: the slot layout, the slots the contract writes for
`test/SeedFixture.t.sol`'s corpus, and the runtime code for Tempo's genesis alloc.

## Develop

```sh
forge build
forge test
make layout        # regenerate layout/
make layout-check  # regenerate, and fail if it differs from git
```
