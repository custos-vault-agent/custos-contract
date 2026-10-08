# custos-contract

This repository holds the on-chain half of Custos, a marketplace for AI trading agents on Monad. Each agent gets its own vault. The agent can trade with the money in the vault, but it can never withdraw it. Anyone can deposit.

The marketplace frontend is in `custos-web`. The reputation badge of a creator comes from NanSigil, which is deployed from this repository and lives in `lib/nansigil-contract`.

## Contracts

| File | What it is | Upgradeable |
|---|---|---|
| `src/CustosCore.sol` | The registry and the authorization layer. It holds no funds and does no trading. | Yes, UUPS |
| `src/CustosProxy.sol` | The permanent address of the core. All registry state lives behind it. | Proxy |
| `src/modules/AccessControl.sol` | Upgrade authority, configuration, and the pause switch | Part of the core |
| `src/modules/AgentRegistry.sol` | `registerAgent` and the creator functions | Part of the core |
| `src/AgentVault.sol` | One ERC-4626 vault per agent. It holds the funds and applies the trading rules. | No |
| `src/VaultFactory.sol` | Deploys an `AgentVault` with `create2`. The salt is the agent id. | No |
| `src/PriceOracle.sol` | Chainlink feed registry. It values a held token in USDC. | No |
| `src/adapters/KuruMarketAdapter.sol` | Wraps one Kuru orderbook as the `IMarket` shape. It keeps no state and no funds. | No |
| `src/adapters/MockYieldSource.sol` | A fixed APY yield source for demos | No |

Two choices in this list are on purpose.

1. Each `AgentVault` is immutable. It is not a proxy, so an upgrade of the core cannot change the rules that a subscriber accepted when they deposited.
2. `VaultFactory` is a separate contract because the `AgentVault` bytecode would be embedded in whichever contract calls `new AgentVault`. Inside `CustosCore` it pushes the core past the 24 KB limit of EIP-170. When the vault changes, deploy a new factory and call `setVaultFactory`. Vaults that already exist are not touched.

## Who can do what

| Role | Can do | Cannot do |
|---|---|---|
| Upgrade authority | Upgrade the core. Pause and unpause the protocol. Set the vault factory, the price oracle, the market adapter, NanSigil, and the minimum seed. Allow a yield source. Allow a market for one vault. Transfer its own role. | Touch a deployed vault directly. Change the accounting asset, which has no setter. |
| Creator | Register an agent. Change the allowance and the period of its vault. Pause, resume, or revoke the agent. Set the marketplace visibility (`setPublic`). Earn the performance fee. | Withdraw subscriber funds. Move the seed. Change anything in the next list. |
| Agent wallet | Call `executeSwap` on its own vault, on an allowed market, inside the allowance. | Deposit, withdraw, redeem, transfer, or approve shares. The vault refuses all of these with `AgentCannotCallThis`. |
| Subscriber | Deposit and mint. Redeem and withdraw at any time. | Nothing is gated by `isPublic`. That flag only controls the marketplace listing. |

After registration the creator can change two values: the allowance and the period length. A change of the period starts a new period at once. The creator can also pause, resume, and revoke. A revoke is permanent.

Everything else is frozen for the life of the vault:

- the creator address and the agent wallet
- the fee rate, `maxDrawdownBps`, and `maxUtilizationBps`
- the yield source and the price oracle
- the asset, which is the accounting asset of the core
- the seed, which is locked at `address(1)`

Redeem and withdraw always work, also when the vault is paused or revoked.

## Rules of the vault

1. **Agent binding.** A wallet can be the agent of one vault only. The binding is permanent, and a revoked agent keeps it. A creator cannot name its own wallet as the agent.
2. **Seed.** `registerAgent` needs a seed of at least `minSeed`. The shares of the seed go to `address(1)` and stay there. This defends against the ERC-4626 inflation attack, and it puts the money of the creator at risk next to the money of the subscribers.
3. **Allowance.** The agent can commit at most `allowance` of notional in each period. A buy counts its `amountIn`. A sell counts `maxNotional`, and the unused part returns to the allowance after the swap.
4. **Utilization.** The cap is also `maxUtilizationBps` of `totalAssets`, from 10% to 95%. The smaller of the two limits applies, so some money is always available for redemptions.
5. **Single-swap drawdown.** One swap that lowers the share price by more than `maxDrawdownBps` reverts.
6. **Performance fee.** When the share price is above the high water mark, the vault mints fee shares to the creator for `feeRate` of the profit. The fee is capped at 50%. This happens after each swap and before each redeem or withdraw, so a leaving subscriber does not take the share of the creator with them. The preview functions count the fee.
7. **Circuit breaker.** When the share price falls more than `maxDrawdownBps` below the high water mark, the vault pauses itself. The swap that tripped it still completes. After a breaker, `resume` resets the high water mark to the current price. After a manual pause, `resume` does not reset it, so a creator cannot lower the mark at will.
8. **Idle yield.** If the vault has a yield source, idle USDC goes there after a deposit or a swap, and returns when a buy or a redemption needs it. A vault with `yieldSource == address(0)` is a pure trading vault. The yield source must be on the allowlist of the core at registration. The breaker skips the push, so funds stay idle after a trip.
9. **Valuation.** `totalAssets` is the idle balance, plus the yield position, plus each held base token valued by `PriceOracle`. If the feed of a held token is stale, `totalAssets` reverts, and deposit, redeem, and swap stop until the feed recovers. The vault halts instead of pricing a position at an old value.
10. **Markets.** A market must be allowed for the vault, its quote token must be the accounting asset, and its base token must have a feed in the oracle.

## Commands

```bash
cp .env.example .env
make build       # forge build
make test        # forge test -vvv
make abi         # writes abi/CustosCore.json, AgentVault.json, NanSigil.json, MockERC20.json
make deploy      # full stack on anvil with seeded demo data
```

`make deploy` runs `script/Deploy.s.sol`. It deploys the whole stack with mocks, registers demo agents, runs swaps and deposits, and submits NanSigil attestations. It writes every address to `deployments/anvil.json`.

The staged path is for a real network such as Monad testnet. Each step writes its own keys to `DEPLOYMENT_FILE` and reads the earlier ones from it. An address in the environment overrides the file.

| Command | What it writes or changes |
|---|---|
| `make deployMock` | Deploys a mock USDC, a mock MON, a mock Kuru market, a mock yield source, and a mock MON/USD feed. Writes their keys. It refuses to run outside chain 31337 and 10143. |
| `make deployKuruAdapter` | Deploys one `KuruMarketAdapter` for a real Kuru orderbook and writes it as `market`. It replaces the mock market. Set `KURU_WMON` for a native market. |
| `make deployCore` | Deploys the `CustosCore` implementation and proxy, `VaultFactory`, and `PriceOracle`. It also deploys NanSigil unless one is already set. Nothing is configured yet. |
| `make init` | The upgrade authority sets the factory, the oracle, NanSigil, the market adapter, the minimum seed, the yield source allowlist, and the MON/USD feed. `registerAgent` reverts until this has run. It can run again safely. |
| `make upgradeCore` | Deploys a new `CustosCore` implementation and upgrades the existing proxy to it. |
| `make upgrade` | The same script as `upgradeCore`. |
| `make addresses` | Reads `deployments/anvil.json`, writes `deployments/addresses.json` grouped by contract name, and prints a `contracts:` block for an Envio `config.yaml`. |
| `make verify` | Verifies the deployed contracts on an explorer. See the next section. |
| `make verifyVault VAULT=0x...` | Verifies one `AgentVault`. |

CAUTION: THE `Makefile` DOES `-include .env` AND `export`, SO A VALUE IN `.env` WINS OVER YOUR SHELL. PASS VARIABLES ON THE `make` COMMAND LINE, FOR EXAMPLE `make init RPC_URL=...`. THE `.env` OF A WORKING COPY MAY POINT AT MAINNET.

CAUTION: `make deployMock` IS ONLY FOR ANVIL AND A TESTNET. IT OVERWRITES THE TOKEN AND MARKET KEYS (`usdc`, `mon`, `market`, and the mock keys) IN `DEPLOYMENT_FILE`.

## Verification

`make verify` reads the addresses from `DEPLOYMENT_FILE` and the constructor arguments from the chain. It covers:

- the `CustosCore` implementation and the `CustosProxy`
- `VaultFactory`
- `PriceOracle`
- the Kuru adapter
- NanSigil and its proxy

Set `VERIFIER`, `VERIFIER_URL`, and `VERIFIER_API_KEY` for an Etherscan-style or Blockscout explorer. The default is Sourcify, which needs no key. `DRY_RUN=1` prints the arguments and verifies nothing. After an ownership or authority transfer, pass `INIT_AUTHORITY`, `ORACLE_OWNER`, `NANSIGIL_INIT_AUTHORITY`, or `INIT_ATTESTOR`, because the constructors recorded the original values.

`verifyVault` is separate because the constructor of a vault took the allowance and the period, and the creator can change both. The script reads the current values from the vault. If they changed, pass `ALLOWANCE` and `PERIOD` from the `AgentRegistered` event. All vaults share one bytecode, so one verified vault is usually enough for an explorer to recognize the others.

Known failure: on an Etherscan-style explorer, `VaultFactory` reports a bytecode mismatch. The local artifact is byte-identical to the deployment transaction. The cause is that the compiler metadata embeds remapping paths, and those paths are absolute to the machine that built the contract. Sourcify accepts the contract on runtime bytecode. Setting `bytecode_hash = "none"` in `foundry.toml` would make verification independent of the path for future deployments.

## Deployed addresses

| Contract | Monad mainnet (143) | Monad testnet (10143) |
|---|---|---|
| CustosCore proxy | `0x8809926996F45505F17599fda8299d86bA3586af` | `0xd39e810EAE02E8247ec9308c936c5077dBAe2c46` |
| NanSigil | `0x1421E6Acc7C7b3199077CD3b2A7d2A33778dfe9D` | `0xfF86D1b2fd3edaD27B361A9d004f3b6facb43621` |
| USDC | `0x754704Bc059F8C67012fEd69BC8A327a5aafb603` | `0x6f29bb72232770088E7d58b56d6A152354190A6e` (mock) |
| VaultFactory | not listed | `0xa636d4241B9b46e96BC397bedB4F948AdEDA8373` |
| PriceOracle | not listed | `0x9b1C0B50d30c3108646dBEd717189594FF759734` |
| Market adapter | not listed | `0xfd0275B71c22CC80a88729B989F680176dC0fa07` (mock market) |
| MON | not listed | `0x898E658d0C7a9aBc1E138c45BEbA02Acc2F09B02` (mock) |
| Yield source | not listed | `0x7B1a402cd1958D8B0037Eab29B1Db68508CAb57A` (mock) |
| MON/USD feed | not listed | `0x6a549CCe44e18BeB99DD08a6448829A814A2A0DE` (mock) |

Every dependency on testnet is a mock. The mock USDC has a public `mint`, and the mock feed has a public `set`, so anyone can create tokens and move the price.

## Submodule

`lib/nansigil-contract` is a git submodule. A fresh clone needs `git submodule update --init --recursive`. A new NanSigil commit reaches this repository only after the submodule pointer is bumped here.

## What is not proven

- The Kuru adapter has never traded against a real Kuru orderbook. The tests and the testnet use a mock router.
- `PriceOracle` has never read a real Chainlink feed. The testnet feed is a mock.
- Nobody outside the project has audited these contracts.
