/*
Docs references:
- viem wallet client (`createWalletClient` + `custom(window.ethereum)`): https://viem.sh/docs/clients/wallet
- viem getContract helper: https://viem.sh/docs/contract/getContract
- Uniswap v4 hooks concept (pool-scoped hook execution): https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 PoolManager lifecycle overview: https://docs.uniswap.org/contracts/v4/overview
- Uniswap v4 AsyncSwap/custom accounting context: https://docs.uniswap.org/contracts/v4/quickstart/hooks/async-swap
- OpenZeppelin Uniswap Hooks base contracts: not used in this frontend helper file.
*/

import {
  createPublicClient,
  createWalletClient,
  custom,
  getContract,
  http,
  type Address,
} from "viem";
import { sepolia } from "viem/chains";

import { stealthBatchHookAbi } from "../../abi/stealthBatchHookAbi";

const DEFAULT_SEPOLIA_RPC_URL = "https://ethereum-sepolia-rpc.publicnode.com";
export const targetChain = sepolia;
export const TARGET_CHAIN_ID = targetChain.id;

export const sepoliaRpcUrl =
  import.meta.env.PUBLIC_SEPOLIA_RPC_URL ?? DEFAULT_SEPOLIA_RPC_URL;
export const explorerBaseUrl =
  targetChain.blockExplorers?.default?.url ?? "https://sepolia.etherscan.io";

export const publicClient = createPublicClient({
  chain: targetChain,
  transport: http(sepoliaRpcUrl, { batch: true }),
});

export const ALLOWED_POOL_NOT_CONFIGURED_SELECTOR = "0x2865d89a";
export const HOOK_NOT_CONFIGURED_MESSAGE =
  "Hook pool is not configured yet. Run the deploy+pool init script (or setAllowedPoolIdOnce) before using the app.";

export class WalletProviderError extends Error {
  constructor() {
    super("No injected wallet found. Install MetaMask (or another EIP-1193 wallet).");
    this.name = "WalletProviderError";
  }
}

export class ChainMismatchError extends Error {
  constructor(actualChainId: number) {
    super(
      `Wrong network: connected to chain ${actualChainId}. Please switch wallet to Sepolia (chain ${TARGET_CHAIN_ID}).`,
    );
    this.name = "ChainMismatchError";
  }
}

export function toUserFacingViemError(error: unknown): string {
  if (error instanceof Error) {
    const message = error.message;
    if (
      message.includes(ALLOWED_POOL_NOT_CONFIGURED_SELECTOR) ||
      message.includes("AllowedPoolNotConfigured")
    ) {
      return HOOK_NOT_CONFIGURED_MESSAGE;
    }
    return message;
  }
  return "Contract call failed.";
}

export const walletClient =
  typeof window !== "undefined" && window.ethereum
    ? createWalletClient({
        chain: targetChain,
        transport: custom(window.ethereum),
      })
    : undefined;

export async function assertWalletOnSepolia(): Promise<void> {
  if (!walletClient) {
    throw new WalletProviderError();
  }

  const chainId = await walletClient.getChainId();
  if (chainId !== TARGET_CHAIN_ID) {
    throw new ChainMismatchError(chainId);
  }
}

export async function getVeilBatchContract(address: Address) {
  if (!walletClient) {
    return getContract({
      address,
      abi: stealthBatchHookAbi,
      client: publicClient,
    });
  }

  await assertWalletOnSepolia();

  return getContract({
    address,
    abi: stealthBatchHookAbi,
    client: {
      public: publicClient,
      wallet: walletClient,
    },
  });
}
