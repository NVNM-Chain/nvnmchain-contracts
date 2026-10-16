# nvnmchain-contracts

Application contracts for NVM.

## Anchoring

`x/anchoring`'s precompile as a contract with the same ABI, at the same address on Tempo
(`0x…0a00`); `src/Anchoring.sol` lists what a caller sees differently.

The corpus arrives through the chain repo's dump writer (`x/anchoring/evmlayout`), not
transactions, so `layout/` is an interface: the slot layout, the slots the contract writes for
`test/SeedFixture.t.sol`'s corpus, and what Tempo deploys and places, from `test/Deployment.t.sol`.
`proxy.bin` is runtime only, so placing it also takes slot 11, the owner, and `deployment.json`'s
`implementationSlot` holding `implementation`. That is deployed through `factory` with `salt`, as
its runtime holds the address: anywhere else it answers direct calls and no upgrade returns to it.

An upgrade must leave every entry of `layout/anchoring.json` where it is: `upgradeToAndCall`
checks only that the new code is UUPS, and `make layout-check` fails on any code change.

## Develop

```sh
forge build
forge test
make layout        # regenerate layout/
make layout-check  # regenerate, and fail if it differs from git
```
