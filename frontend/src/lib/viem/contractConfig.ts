/*
Docs references:
- Uniswap v4 hooks concept (pool-scoped hook execution): https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 PoolManager lifecycle overview: https://docs.uniswap.org/contracts/v4/overview
- Uniswap v4 AsyncSwap/custom accounting context: https://docs.uniswap.org/contracts/v4/quickstart/hooks/async-swap
- OpenZeppelin Uniswap Hooks base contracts: not used in this frontend config file.
*/

import { isAddress, type Address } from "viem";

const configuredAddress = import.meta.env.PUBLIC_VEIL_BATCH_HOOK_ADDRESS;

export const MISSING_CONTRACT_ADDRESS_MESSAGE =
  "Missing PUBLIC_VEIL_BATCH_HOOK_ADDRESS. Set it in frontend/.env (or your deployment environment).";

export const INVALID_CONTRACT_ADDRESS_MESSAGE =
  "Invalid PUBLIC_VEIL_BATCH_HOOK_ADDRESS. Expected a checksummed 0x address.";

export function getVeilBatchHookAddress(): Address | null {
  if (!configuredAddress) {
    return null;
  }
  return isAddress(configuredAddress) ? configuredAddress : null;
}
