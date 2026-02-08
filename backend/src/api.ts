/*
Docs references:
- Uniswap v4 hooks concept (hook semantics enforced onchain): https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 PoolManager lifecycle overview: https://docs.uniswap.org/contracts/v4/overview
- viem Wallet Client: https://viem.sh/docs/clients/wallet
- viem getContract: https://viem.sh/docs/contract/getContract
- Express route handlers/listen: https://expressjs.com/
*/

import express from "express";
import { z } from "zod";
import { isAddress, type Address } from "viem";

import { getHookContract, publicClient } from "./clients.js";
import { stealthBatchHookAbi } from "./abi/stealthBatchHookAbi.js";

// Read-only API: all state is derived from onchain reads/events.
// Hook execution rules remain enforced by the onchain hook + PoolManager lifecycle.
const apiEnvSchema = z.object({
  HOOK_ADDRESS: z.string().regex(/^0x[0-9a-fA-F]{40}$/),
  API_PORT: z.coerce.number().int().positive().default(8787),
  API_EVENT_LOOKBACK_BLOCKS: z.coerce.number().int().positive().default(100_000),
  API_RPC_BACKOFF_BASE_MS: z.coerce.number().int().positive().default(300),
  API_RPC_BACKOFF_MAX_MS: z.coerce.number().int().positive().default(4_000),
  API_RPC_MAX_RETRIES: z.coerce.number().int().nonnegative().default(2),
});

type ApiConfig = z.infer<typeof apiEnvSchema>;

const sleep = (ms: number) =>
  new Promise<void>((resolve) => {
    setTimeout(resolve, ms);
  });

async function withBackoff<T>(
  label: string,
  fn: () => Promise<T>,
  config: ApiConfig
): Promise<T> {
  let attempt = 0;
  let delayMs = config.API_RPC_BACKOFF_BASE_MS;

  for (;;) {
    try {
      return await fn();
    } catch (error) {
      attempt += 1;
      if (attempt > config.API_RPC_MAX_RETRIES) {
        throw error;
      }

      console.warn(
        `[api-rpc-backoff] ${label} failed (attempt ${attempt}/${config.API_RPC_MAX_RETRIES}), retry in ${delayMs}ms`
      );
      await sleep(delayMs);
      delayMs = Math.min(delayMs * 2, config.API_RPC_BACKOFF_MAX_MS);
    }
  }
}

function parseWindowId(value: string): bigint | null {
  if (!/^\d+$/.test(value)) return null;
  try {
    return BigInt(value);
  } catch {
    return null;
  }
}

function parseAddress(value: string): Address | null {
  if (!isAddress(value)) return null;
  return value as Address;
}

function normalizeAddress(value: Address): Address {
  return value.toLowerCase() as Address;
}

function intentKey(windowId: bigint, intentId: bigint): string {
  return `${windowId.toString()}:${intentId.toString()}`;
}

async function getWindowMeta(config: ApiConfig, hookAddress: Address) {
  const hook = getHookContract({ abi: stealthBatchHookAbi, address: hookAddress });
  const [currentBlock, startBlock, blocksPerWindow] = await Promise.all([
    withBackoff("getBlockNumber()", async () => publicClient.getBlockNumber(), config),
    withBackoff("read.startBlock()", async () => hook.read.startBlock(), config),
    withBackoff("read.blocksPerWindow()", async () => hook.read.blocksPerWindow(), config),
  ]);

  if (currentBlock < startBlock) {
    return {
      currentBlock,
      startBlock,
      blocksPerWindow,
      currentWindowId: null as bigint | null,
      endBlock: startBlock - 1n,
    };
  }

  const currentWindowId = (currentBlock - startBlock) / blocksPerWindow;
  const windowStart = startBlock + currentWindowId * blocksPerWindow;
  const windowEndExclusive = windowStart + blocksPerWindow;
  const endBlock = windowEndExclusive - 1n;

  return {
    currentBlock,
    startBlock,
    blocksPerWindow,
    currentWindowId,
    endBlock,
  };
}

export async function runApiServer(): Promise<void> {
  const config = apiEnvSchema.parse(process.env);
  const hookAddress = config.HOOK_ADDRESS as Address;
  const hook = getHookContract({ abi: stealthBatchHookAbi, address: hookAddress });
  const app = express();

  app.get("/status", async (_req, res) => {
    try {
      const meta = await getWindowMeta(config, hookAddress);
      res.json({
        hookAddress,
        currentBlock: meta.currentBlock.toString(),
        currentWindowId: meta.currentWindowId === null ? null : meta.currentWindowId.toString(),
        endBlock: meta.endBlock.toString(),
      });
    } catch (error) {
      res.status(500).json({ error: `status_failed: ${String(error)}` });
    }
  });

  app.get("/windows/:id", async (req, res) => {
    const windowId = parseWindowId(req.params.id);
    if (windowId === null) {
      res.status(400).json({ error: "invalid_window_id" });
      return;
    }

    try {
      const windowState = await withBackoff(
        `read.getWindow(${windowId.toString()})`,
        async () => hook.read.getWindow([windowId]),
        config
      );

      res.json({
        windowId: windowId.toString(),
        totalIn: windowState.totalIn.toString(),
        totalOut: windowState.totalOut.toString(),
        cleared: windowState.cleared,
      });
    } catch (error) {
      res.status(500).json({ error: `window_lookup_failed: ${String(error)}` });
    }
  });

  app.get("/users/:address/intents", async (req, res) => {
    const user = parseAddress(req.params.address);
    if (user === null) {
      res.status(400).json({ error: "invalid_address" });
      return;
    }

    try {
      const latestBlock = await withBackoff(
        "getBlockNumber()",
        async () => publicClient.getBlockNumber(),
        config
      );
      const fromBlock =
        latestBlock > BigInt(config.API_EVENT_LOOKBACK_BLOCKS)
          ? latestBlock - BigInt(config.API_EVENT_LOOKBACK_BLOCKS)
          : 0n;

      const [queuedLogs, claimedLogs] = await Promise.all([
        withBackoff(
          "getEvents.IntentQueued()",
          async () =>
            hook.getEvents.IntentQueued(
              {},
              { fromBlock, toBlock: latestBlock, strict: true }
            ),
          config
        ),
        withBackoff(
          "getEvents.Claimed()",
          async () =>
            hook.getEvents.Claimed(
              {},
              { fromBlock, toBlock: latestBlock, strict: true }
            ),
          config
        ),
      ]);

      const normalizedUser = normalizeAddress(user);
      const claimedSet = new Set<string>();
      for (const log of claimedLogs) {
        const { windowId, intentId } = log.args;
        if (windowId === undefined || intentId === undefined) continue;
        claimedSet.add(intentKey(windowId, intentId));
      }

      const intents: Array<{
        poolId: `0x${string}`;
        windowId: string;
        intentId: string;
        amountIn: string;
        zeroForOne: boolean;
        claimed: boolean;
        blockNumber: string | null;
        transactionHash: `0x${string}` | null;
      }> = [];

      for (const log of queuedLogs) {
        const { user: queuedUser, windowId, intentId, amountIn, zeroForOne, poolId } = log.args;
        if (
          queuedUser === undefined ||
          windowId === undefined ||
          intentId === undefined ||
          amountIn === undefined ||
          zeroForOne === undefined ||
          poolId === undefined
        ) {
          continue;
        }
        if (normalizeAddress(queuedUser) !== normalizedUser) continue;

        const key = intentKey(windowId, intentId);
        intents.push({
          poolId,
          windowId: windowId.toString(),
          intentId: intentId.toString(),
          amountIn: amountIn.toString(),
          zeroForOne,
          claimed: claimedSet.has(key),
          blockNumber: log.blockNumber?.toString() ?? null,
          transactionHash: log.transactionHash ?? null,
        });
      }

      res.json({
        user: normalizedUser,
        fromBlock: fromBlock.toString(),
        toBlock: latestBlock.toString(),
        count: intents.length,
        intents,
      });
    } catch (error) {
      res.status(500).json({ error: `user_intents_failed: ${String(error)}` });
    }
  });

  app.listen(config.API_PORT, () => {
    console.log(`[api-start] listening on http://localhost:${config.API_PORT.toString()}`);
    console.log(`[api-start] hookAddress=${hookAddress}`);
  });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  runApiServer().catch((error: unknown) => {
    console.error(`[api-fatal] ${String(error)}`);
    process.exit(1);
  });
}
