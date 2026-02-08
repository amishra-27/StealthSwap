/*
Docs references:
- viem Wallet Client: https://viem.sh/docs/clients/wallet
- viem getContract: https://viem.sh/docs/contract/getContract
- Uniswap v4 hooks concept (backend executor context): https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 PoolManager lifecycle overview: https://docs.uniswap.org/contracts/v4/overview
- Uniswap v4 AsyncSwap/custom accounting context: https://docs.uniswap.org/contracts/v4/quickstart/hooks/async-swap
*/

import "dotenv/config";

import { z } from "zod";
import {
  type Abi,
  type Address,
  createPublicClient,
  createWalletClient,
  getContract,
  http,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

const envSchema = z.object({
  RPC_URL: z.string().url(),
  PRIVATE_KEY: z.string().regex(/^0x[0-9a-fA-F]{64}$/),
  CHAIN_ID: z.coerce.number().int().positive(),
});

const env = envSchema.parse(process.env);

if (env.CHAIN_ID !== sepolia.id) {
  throw new Error(
    `Unsupported CHAIN_ID=${env.CHAIN_ID}. This backend currently targets Sepolia (${sepolia.id}).`
  );
}

const account = privateKeyToAccount(env.PRIVATE_KEY as `0x${string}`);

export const publicClient = createPublicClient({
  chain: sepolia,
  transport: http(env.RPC_URL),
});

export const walletClient = createWalletClient({
  account,
  chain: sepolia,
  transport: http(env.RPC_URL),
});

export function getHookContract<const TAbi extends Abi, const TAddress extends Address>(params: {
  abi: TAbi;
  address: TAddress;
}) {
  return getContract({
    abi: params.abi,
    address: params.address,
    client: {
      public: publicClient,
      wallet: walletClient,
    },
  });
}
