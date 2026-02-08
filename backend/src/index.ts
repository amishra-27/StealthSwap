/*
Docs references:
- viem Wallet Client: https://viem.sh/docs/clients/wallet
- viem getContract: https://viem.sh/docs/contract/getContract
- Uniswap v4 hooks concept (executor context): https://docs.uniswap.org/contracts/v4/concepts/hooks
*/

export { getHookContract, publicClient, walletClient } from "./clients.js";
export { stealthBatchHookAbi } from "./abi/stealthBatchHookAbi.js";
export type { StealthBatchHookAbi } from "./abi/stealthBatchHookAbi.js";
export { runExecutorLoop } from "./executor.js";
