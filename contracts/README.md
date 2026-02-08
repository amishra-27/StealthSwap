# scaffold-hook

_Develop and test Uniswap v4 Hooks with minimal interfaces for the swap lifecycle (pool creation, liquidity provision, and swapping)_

> _inspired by [scaffold-eth](https://github.com/scaffold-eth/scaffold-eth-2)_

## Features

✅ Template hook with deployment commands

✅ User interfaces for: pool creation, liquidity creation, and swapping

✅ Local network (anvil) with predeployed Uniswap v4

✅ Testnet support

✅ Foundry (hardhat support coming later)

---

# Setup

_requires [foundry](https://book.getfoundry.sh/getting-started/installation) & [node 18+](https://nodejs.org/en/download)_

## Linux / WSL2 (TSTORE)

Please update [foundry.toml](foundry.toml#L9) to use the linux `solc`

Mac users do not need to change anything by default

## Install Dependencies

```bash
forge install

cd nextjs/
npm install
```

## Define environment variables

```bash
cp .env.example .env
```

See [Environment](#environment-variables) additional setup

---

## Get Started

1. Start the local network, with v4 contracts predeployed

   ```bash
   # root of the repository
   cd scaffold-hook/
   npm run anvil
   ```

2. Deploy the template hook

   ```bash
   # root of the repository
   cd scaffold-hook/
   forge build
   npm run deploy:anvil
   ```

3. Update [wagmi.config.ts](nextjs/wagmi.config.ts) with the hook address from [run-latest.json](/broadcast/DeployHook.s.sol/31337/run-latest.json)

4. Regenerate react hooks, addresses, and ABIs

   ```bash
   cd nextjs/
   npm run wagmi
   ```

5. Start the webapp
   ```bash
   cd nextjs/
   npm run dev
   ```

## Hook Configuration

Modifying the file name, contract name, or _hook flags_ will require configuration:

Renaming -- update [.env](.env)

```bash
# Hook Contract, formatted: <filename.sol>:<contractName>
HOOK_CONTRACT="Counter.sol:Counter"
```

Changing hook flags -- update [.env](.env) and ensure `getHookCalls()` is in agreement

```bash
# in .env
# Hook Flags
BEFORE_SWAP=true
AFTER_SWAP=true
BEFORE_MODIFY_POSITION=true
AFTER_MODIFY_POSITION=true
BEFORE_INITIALIZE=false
AFTER_INITIALIZE=false
BEFORE_DONATE=false
AFTER_DONATE=false
```

```solidity
// in Hook Contract
function getHooksCalls() public pure returns (Hooks.Calls memory) {
    return Hooks.Calls({
        beforeInitialize: false,
        afterInitialize: false,
        beforeModifyPosition: true,
        afterModifyPosition: true,
        beforeSwap: true,
        afterSwap: true,
        beforeDonate: false,
        afterDonate: false
    });
}
```

## StealthBatchHook bootstrap notes

<!--
Docs references:
- Uniswap v4 Hooks concepts (pool-specific hooks): https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 Deployments (official PoolManager addresses): https://docs.uniswap.org/contracts/v4/deployments
- Uniswap v4 PoolManager lifecycle: https://docs.uniswap.org/contracts/v4/overview
- Uniswap v4 AsyncSwap/custom accounting: https://docs.uniswap.org/contracts/v4/quickstart/hooks/async-swap
- OpenZeppelin Uniswap Hooks base overview: https://github.com/openzeppelin/uniswap-hooks/blob/master/docs/modules/ROOT/pages/base.adoc
-->

- Hook callbacks are enabled by address-encoded permissions. If hook permissions change, re-mine the hook deployment salt.
- `DeployHook.s.sol` already uses `HookMiner.find(...)` with CREATE2 to target the required permission bits.
- Set `HOOK_CONTRACT="StealthBatchHook.sol:StealthBatchHook"` in `.env` when deploying this hook.
- For `StealthBatchHook`, set flags exactly to:
  - `BEFORE_SWAP=true`
  - `AFTER_SWAP=true`
  - all other flags `false` (unless contract permissions are changed in code)
- If you later enable `AFTER_INITIALIZE` (for start-block anchoring at pool initialize), update flags and re-mine hook salt/address.
- `StealthBaseHook` validates hook permissions in the constructor; wrong address bits/flags will fail deployment or cause unexpected callback behavior.
- `DeployHook.s.sol` reads constructor args from `.env` for `StealthBatchHook`:
  - `START_BLOCK`, `BLOCKS_PER_WINDOW`, `CANCEL_DELAY_BLOCKS`, `MAX_INTENTS_PER_WINDOW`, `MIN_AMOUNT_IN`, `ZERO_FOR_ONE_DIRECTION`
- Ensure `constructorArgs` used during `HookMiner.find(...)` exactly match on-chain deployment args (order, types, values).
- Ensure the CREATE2 deployer address in mining matches the actual deployer contract used on target network.
- Use the real `POOL_MANAGER_ADDR` for target network (not test harness placeholders like `address(1)`).
- `allowedPoolId` is now set once after deployment via `setAllowedPoolIdOnce(key.toId())`; it is no longer a constructor arg.
- `USE_RUNTIME_START_BLOCK=true` anchors window math to the current RPC block for that deployment run.
- For fully fixed demo replayability, set `USE_RUNTIME_START_BLOCK=false` and set explicit `START_BLOCK` (for example `0`).
- `CANCEL_DELAY_BLOCKS=0` means cancel becomes available immediately after window end (`block.number >= windowEndExclusive`).
- `hasQueuedIntent` is intentionally not reset in a window (MVP one-intent-per-address-per-window policy), including after cancel/claim terminalization.
- Claim math uses floor rounding: `floor(windowTotalOut * userIn / windowTotalIn)`; residual dust can be handled via `sweepDust(windowId, to)` after all intents are terminally settled.
- For batched intent execution, plan hook permissions and address mining before testnet deploys to avoid mismatched callback behavior.

## StealthBatchHook Deploy + Pool Initialize (SC-5)

<!--
Docs references:
- Uniswap v4 hook deployment guide (flags + address mining): https://docs.uniswap.org/contracts/v4/guides/hooks/hook-deployment
- Uniswap v4 deployments (official contract addresses): https://docs.uniswap.org/contracts/v4/deployments
- Uniswap v4 hooks concepts (pool-specific attachment at initialize): https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 PoolManager lifecycle overview: https://docs.uniswap.org/contracts/v4/overview
- Uniswap v4 AsyncSwap/custom accounting context: https://docs.uniswap.org/contracts/v4/quickstart/hooks/async-swap
-->

`REVIEW REQUIRED`: deployment + pool init flow below is an MVP scaffold, not production-ready release guidance.

The script `contracts/script/DeployStealthBatchHookAndPool.s.sol` does all of the following:

- validates `HOOK_CONTRACT` is `StealthBatchHook.sol:StealthBatchHook`
- validates hook flags are exactly `beforeSwap + afterSwap` (no extras)
- prints preflight chainId + `POOL_MANAGER_ADDR` and warns on Sepolia mismatch against official v4 deployments docs
- mines salt with `HookMiner.find(...)` for CREATE2 hook deployment
- computes pool id from the final `PoolKey` (`key.toId()`), calls `setAllowedPoolIdOnce(poolId)`, then initializes the pool on `POOL_MANAGER_ADDR`

### Required `.env` values for this script

- constructor args: `USE_RUNTIME_START_BLOCK`, `START_BLOCK` (used only when runtime mode is false), `BLOCKS_PER_WINDOW`, `CANCEL_DELAY_BLOCKS`, `MAX_INTENTS_PER_WINDOW`, `MIN_AMOUNT_IN`, `ZERO_FOR_ONE_DIRECTION`
- pool params: `POOL_TOKEN_A`, `POOL_TOKEN_B`, `POOL_FEE`, `POOL_TICK_SPACING`, `POOL_SQRT_PRICE_X96`, `POOL_HOOK_DATA`
- flags: `BEFORE_SWAP=true`, `AFTER_SWAP=true`, all others `false`

### Local anvil

```bash
cd contracts
npm run anvil
npm run deploy:stealth:anvil:init-pool
```

### Sepolia

```bash
cd contracts
npm run deploy:stealth:sepolia:init-pool
```

### Broadcast artifacts (for submission TxIDs)

`forge script ... --broadcast` writes artifacts under `broadcast/<ScriptName>/<chainId>/run-latest.json`.
Use this file to recover deployment/initialize tx hashes and resolved addresses for hackathon judge deliverables.

### Known mining/permission pitfalls

- If `getHookPermissions()` changes, the hook address bit pattern changes; re-mine salt/address before deploy.
- If you add `afterInitialize` later for start-block anchoring, update flags and re-mine again.
- `StealthBaseHook` calls `Hooks.validateHookPermissions(...)`; wrong address bits/flags can fail deployment or callback routing.
- `constructorArgs` passed into `HookMiner.find(...)` must exactly match the deployed constructor args (types/order/values).
- Use the actual deployer address used for CREATE2 and the real network `POOL_MANAGER_ADDR` for your target chain.
- If `USE_RUNTIME_START_BLOCK=true`, `startBlock` is taken from the current RPC block and is stable only for that run's mined constructor args.
- If `USE_RUNTIME_START_BLOCK=false`, the fixed `START_BLOCK` value is used and must be chosen intentionally for your demo timeline.

## Deploying to Testnets

_Ensure your wallet is funded with testnet gas (ETH)_

- `npm run deploy:anvil`

- `npm run deploy:goerli`

- `npm run deploy:arbitrum-goerli`

- `npm run deploy:arbitrum-sepolia`

- `npm run deploy:optimism-goerli`

- `npm run deploy:base-goerli`

- `npm run deploy:sepolia`

- `npm run deploy:scroll-sepolia`

- `npm run deploy:polygon-mumbai`

- `npm run deploy:polygon-zkevm-testnet`

## Additional Configuration

### Custom Tokens

While `scaffold-hook` ships solmate's `MockERC20` on local and testnet, you can provide your own custom tokens:

1. define them in [wagmi.config.ts](nextjs/wagmi.config.ts#L80), and regenerate the codegen: `npm run wagmi`
2. import the generated addresses and edit [`TOKEN_ADDRESSES`](nextjs/utils/config.ts)

### Debuggable Hook (etherscan-style contract interface)

1. define the hook in [wagmi.config.ts](nextjs/wagmi.config.ts#L15), and regenerate the codegen: `npm run wagmi`
2. import the generated types and edit [`DEBUGGABLE_ADDRESSES`](nextjs/utils/config.ts)

## Environment Variables

- `ANVIL_FORK_URL`: RPC URL for anvil fork mode
- `ETHERSCAN_API_KEY`: Your Etherscan API Key
- `FORGE_PRIVATE_KEY`: The private key of the wallet for testnet deployments

# Learn more

To learn more about [Next.js](https://nextjs.org), [Foundry](https://book.getfoundry.sh/) or [wagmi](https://wagmi.sh), check out the following resources:

- [Foundry Documentation](https://book.getfoundry.sh/) – learn more about the Foundry stack (Anvil, Forge, etc).
- [wagmi Documentation](https://wagmi.sh) – learn about wagmi Hooks and API.
- [wagmi Examples](https://wagmi.sh/examples/connect-wallet) – a suite of simple examples using wagmi.
- [@wagmi/cli Documentation](https://wagmi.sh/cli) – learn more about the wagmi CLI.
- [Next.js Documentation](https://nextjs.org/docs) learn about Next.js features and API.
- [Learn Next.js](https://nextjs.org/learn) - an interactive Next.js tutorial.
