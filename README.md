# nvnmchain-contracts

Application contracts for NVM.

## Anchoring

`x/anchoring`'s precompile as a contract with the same ABI, at the same address on Tempo
(`0x…0a00`), so a caller changes chains and nothing else. Five differences: `registriesByName`
matches exactly, folding ASCII case; timestamps have no sub-second part; revert strings that
format values are shorter; a call carrying value reverts with no reason; a contract may call,
where the precompile took only an EOA.

The corpus arrives through the chain repo's dump writer (`x/anchoring/evmlayout`), not
transactions, so `layout/` is an interface: the slot layout, the slots the contract writes for
`test/SeedFixture.t.sol`'s corpus, and what Tempo deploys and places, from `test/Deployment.t.sol`.

## Develop

```sh
forge build
forge test
make layout        # regenerate layout/
make layout-check  # regenerate, and fail if it differs from git
```
