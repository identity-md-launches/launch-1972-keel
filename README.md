# Keel (KEEL)

Keel is a fixed-supply ERC-20. Its constructor mints **1,000,000,000 KEEL**,
with **18 decimals**, once to the immediate deploying address (`msg.sender`).
The production contract is [`src/Keel.sol`](src/Keel.sol), Solidity identifier
`Keel`. It extends the vendored OpenZeppelin ERC20 without changing transfers
or allowances.

## Parameters and assumptions

| Parameter | Value |
| --- | --- |
| Name | `Keel` |
| Symbol | `KEEL` |
| Decimals | `18` |
| `INITIAL_SUPPLY` / initial `totalSupply()` | `1000000000000000000000000000` base units (`10^27`) |
| Constructor arguments | None (`[]`) |
| Initial recipient | Immediate deployer; the launch factory on IdentityMD |
| Launch chain | Ethereum, chain ID `1` |
| Compiler | Solidity `0.8.26` |
| EVM target | `cancun` |
| Optimizer | Enabled, `200` runs |
| Bytecode metadata hash | `none` |
| Application contracts | None |

The brief specifies a simple token, so no fees, burns, rebases, limits, pausing,
blacklists, ownership, roles, signatures, or upgrades are added. There is no
callable mint function or initializer. All supply remains constant after
construction. The constructor makes no external calls and requires no oracle,
registry, privileged address, or other configuration.

`transfer` and `transferFrom` move exactly the requested amount and return `true`
on success. Invalid operations revert with OpenZeppelin's ERC-6093 custom errors.
Transfers to the zero address and approvals of the zero spender are rejected.
Zero-value transfers between valid addresses are allowed and emit `Transfer`.
Self-transfers preserve balances and still require sufficient balance.

`approve` replaces the caller's allowance for a spender. Finite allowances decrease
when used by `transferFrom`; `type(uint256).max` is an unlimited allowance and does
not decrease. `transferFrom` needs an allowance even when its caller is the holder.
As implemented by the vendored OpenZeppelin version, `approve` emits `Approval`,
while allowance consumption in `transferFrom` does not emit an additional
`Approval`; integrations should query `allowance` for its current value.

## Build and check

Foundry and the pinned Solidity compiler must be installed. All Solidity
dependencies and their licenses are included under `lib/` as ordinary files;
there are no submodules or package installation steps. With that compiler
available, builds and tests need no network, RPC, wallet, environment configuration,
FFI, or filesystem cheatcode permissions.

```sh
forge build
FOUNDRY_FUZZ_SEED=0xceffd716d37308f32f966fd814442a68c005e25957fc77c1fe7c1834468cbcb7 forge test
forge fmt --check
sha256sum --check lib/SHA256SUMS
```

Tests never read or modify environment variables. The seed above is passed to
Foundry by the shell, as specified by the assignment. The configuration runs
1,024 cases per fuzz test and 256 invariant sequences of 64 calls each, with
unexpected handler reverts treated as failures.

[`test/Keel.t.sol`](test/Keel.t.sol) covers metadata, constructor mint events,
CREATE2 factory deployment, exact launch allocations and claims, transfers,
approvals, finite/unlimited allowances, zero values, self-transfers, permission
failures, insufficient balances/allowances, atomic rollback, absence of privileged
entry points, and deployment bytecode constraints. Fuzz cases vary recipients,
amounts, balances, and allowances. [`test/Keel.invariant.t.sol`](test/Keel.invariant.t.sol)
compares balances and allowances with an independent ledger across randomized
sequences and checks conservation of the entire supply.

## Deployment handoff

Use the compiled **`src/Keel.sol:Keel`** creation bytecode in
`out/Keel.sol/Keel.json`, with no appended constructor arguments and no ETH value.
There are no linked libraries, proxies, initialization calls, or application
contracts to deploy. `forge inspect src/Keel.sol:Keel bytecode` prints the creation
bytecode for review. Test harnesses are not deployment targets.

The launch factory must create Keel directly, so it receives the full supply and
can perform the launch transfers. A deployment wrapper would receive the tokens
instead; the transaction origin does not receive them merely by funding deployment.
No owner argument or post-deployment ownership handoff is needed.

The network's later manifest step supplies `launch.json`; it is intentionally not
part of this deliverable. The supplied launch terms are external to the token:

- 10% (100,000,000 KEEL) goes from the factory to its MerkleDistributor.
- 88% (880,000,000 KEEL) is the pool allocation, with a 2 ETH initial market cap
  (`initialMarketCapWei = "2000000000000000000"`).
- 2% (20,000,000 KEEL) is the remainder to
  `0x51a9ca901c0cb5c222d244b2ccb0ebfc5c9aba99`.
- The pair is native ETH; its currency sentinel is the zero address. The launch
  pool fee is `12500` (1.25%), tick spacing `60`, and supplied nominal initial price
  is `79228162514264337593543950336`. The launch computes the actual opening price
  from the economics, supply, and deployed address.

These are factory responsibilities, not constructor allocations or token fees.
The token does not embed the factory, pool, distributor, or remainder addresses.
The local factory test verifies exact token movements using isolated test actors;
it does not emulate the Uniswap PoolManager or determine liquidity positions.
The network's protected launch integration checks need its separate harness and
resolved launch manifest and remain part of the subsequent verification step.

## After launch

There are no owner-settable settings, keepers, or ongoing administrative duties.
The network deployer is responsible for checking the deployed bytecode and
metadata, verifying source on the explorer, and verifying that mint and launch
distribution events match the accepted manifest. No transactions are broadcast
by this project or its tests.

Holders are responsible for recipient addresses and spender permissions. Prefer
bounded allowances and revoke unused permissions with `approve(spender, 0)`.
When changing an existing nonzero allowance, first revoke it and confirm that
transaction before granting the replacement; an already-authorized spender may
spend the old allowance before revocation is confirmed. Unlimited allowances let
the spender use future balances too.

The deployer has no special control over holders. Lost keys and mistaken transfers
cannot be recovered administratively. Sending KEEL to its own contract or another
contract without a withdrawal path can permanently lock those tokens; total supply
still includes them. The token has no payable entry point or asset rescue function.

See [`SECURITY.md`](SECURITY.md) for the review scope and
[`THIRD_PARTY.md`](THIRD_PARTY.md) for dependency provenance.
