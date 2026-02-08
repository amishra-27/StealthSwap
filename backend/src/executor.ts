/*
Docs references:
- Uniswap v4 hooks concept (pool-specific hook behavior): https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 PoolManager lifecycle overview: https://docs.uniswap.org/contracts/v4/overview
- viem Wallet Client: https://viem.sh/docs/clients/wallet
- viem getContract: https://viem.sh/docs/contract/getContract
*/

import { z } from "zod";
import type { Address } from "viem";

import { getHookContract, publicClient } from "./clients.js";
import { stealthBatchHookAbi } from "./abi/stealthBatchHookAbi.js";

const numberWithDefault = (fallback: number) =>
  z.preprocess(
    (value) => (value === undefined || value === null || value === "" ? fallback : value),
    z.coerce.number().int().positive()
  );

const nonNegativeNumberWithDefault = (fallback: number) =>
  z.preprocess(
    (value) => (value === undefined || value === null || value === "" ? fallback : value),
    z.coerce.number().int().nonnegative()
  );

const executorEnvSchema = z.object({
  HOOK_ADDRESS: z.string().regex(/^0x[0-9a-fA-F]{40}$/),
  EXECUTOR_POLL_INTERVAL_MS: numberWithDefault(4_000),
  EXECUTOR_BACKOFF_BASE_MS: numberWithDefault(1_000),
  EXECUTOR_BACKOFF_MAX_MS: numberWithDefault(16_000),
  EXECUTOR_MAX_RETRIES: nonNegativeNumberWithDefault(3),
  EXECUTOR_MAX_WINDOWS_PER_TICK: numberWithDefault(16),
  EXECUTOR_BOOTSTRAP_BLOCK_SPAN: numberWithDefault(5_000),
});

type ExecutorConfig = z.infer<typeof executorEnvSchema>;

type HookContract = ReturnType<typeof getHookContract<typeof stealthBatchHookAbi, Address>>;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function bigintAsc(a: bigint, b: bigint): number {
  if (a < b) return -1;
  if (a > b) return 1;
  return 0;
}

async function withBackoff<T>(
  label: string,
  fn: () => Promise<T>,
  config: ExecutorConfig
): Promise<T> {
  let attempt = 0;
  let delayMs = config.EXECUTOR_BACKOFF_BASE_MS;

  while (true) {
    try {
      return await fn();
    } catch (error) {
      attempt += 1;
      if (attempt > config.EXECUTOR_MAX_RETRIES) {
        throw error;
      }

      console.warn(
        `[rpc-backoff] ${label} failed (attempt ${attempt}/${config.EXECUTOR_MAX_RETRIES}), retry in ${delayMs}ms`
      );
      await sleep(delayMs);
      delayMs = Math.min(delayMs * 2, config.EXECUTOR_BACKOFF_MAX_MS);
    }
  }
}

function getWindowIdFromBlock(
  blockNumber: bigint,
  startBlock: bigint,
  blocksPerWindow: bigint
): bigint | null {
  if (blockNumber < startBlock) return null;
  return (blockNumber - startBlock) / blocksPerWindow;
}

function getWindowStart(windowId: bigint, startBlock: bigint, blocksPerWindow: bigint): bigint {
  return startBlock + windowId * blocksPerWindow;
}

function getWindowEndExclusive(windowId: bigint, startBlock: bigint, blocksPerWindow: bigint): bigint {
  return getWindowStart(windowId, startBlock, blocksPerWindow) + blocksPerWindow;
}

function rememberIntentQueued(
  windowId: bigint,
  intentId: bigint,
  intentsSeenByWindow: Map<bigint, number>,
  pendingWindows: Set<bigint>
): void {
  const current = intentsSeenByWindow.get(windowId) ?? 0;
  intentsSeenByWindow.set(windowId, current + 1);
  pendingWindows.add(windowId);

  console.log(
    `[intent-queued] window=${windowId.toString()} intentId=${intentId.toString()} intentsSeen=${(
      current + 1
    ).toString()}`
  );
}

async function processPendingWindows(params: {
  currentWindowId: bigint;
  hook: HookContract;
  intentsSeenByWindow: Map<bigint, number>;
  pendingWindows: Set<bigint>;
  config: ExecutorConfig;
}): Promise<void> {
  const { currentWindowId, hook, intentsSeenByWindow, pendingWindows, config } = params;

  const windowsToCheck = [...pendingWindows]
    .filter((windowId) => windowId < currentWindowId)
    .sort(bigintAsc)
    .slice(0, config.EXECUTOR_MAX_WINDOWS_PER_TICK);

  for (const windowId of windowsToCheck) {
    try {
      const windowState = await withBackoff(
        `read.getWindow(${windowId.toString()})`,
        async () => hook.read.getWindow([windowId]),
        config
      );

      if (windowState.cleared) {
        pendingWindows.delete(windowId);
        console.log(`[clear-skip] window=${windowId.toString()} alreadyCleared=true`);
        continue;
      }

      if (windowState.intentCount === 0n) {
        pendingWindows.delete(windowId);
        console.log(`[clear-skip] window=${windowId.toString()} intentCount=0`);
        continue;
      }

      const txHash = await withBackoff(
        `write.clear(${windowId.toString()})`,
        async () => hook.write.clear([windowId]),
        config
      );

      console.log(
        `[clear-sent] window=${windowId.toString()} intentsSeen=${(intentsSeenByWindow.get(windowId) ?? 0).toString()} intentCountOnchain=${windowState.intentCount.toString()} txHash=${txHash}`
      );

      await withBackoff(
        `waitForTransactionReceipt(${txHash})`,
        async () => publicClient.waitForTransactionReceipt({ hash: txHash }),
        config
      );

      pendingWindows.delete(windowId);
      console.log(`[clear-mined] window=${windowId.toString()} txHash=${txHash}`);
    } catch (error) {
      console.warn(`[clear-error] window=${windowId.toString()} error=${String(error)}`);
    }
  }
}

export async function runExecutorLoop(): Promise<void> {
  const config = executorEnvSchema.parse(process.env);
  const hookAddress = config.HOOK_ADDRESS as Address;
  const hook = getHookContract({ abi: stealthBatchHookAbi, address: hookAddress });

  const [startBlock, blocksPerWindow, latestBlock] = await Promise.all([
    withBackoff("read.startBlock()", async () => hook.read.startBlock(), config),
    withBackoff("read.blocksPerWindow()", async () => hook.read.blocksPerWindow(), config),
    withBackoff("getBlockNumber()", async () => publicClient.getBlockNumber(), config),
  ]);

  console.log(
    `[executor-start] hook=${hookAddress} latestBlock=${latestBlock.toString()} startBlock=${startBlock.toString()} blocksPerWindow=${blocksPerWindow.toString()}`
  );

  const intentsSeenByWindow = new Map<bigint, number>();
  const pendingWindows = new Set<bigint>();
  let lastSeenWindow = getWindowIdFromBlock(latestBlock, startBlock, blocksPerWindow);

  if (lastSeenWindow !== null) {
    const windowStart = getWindowStart(lastSeenWindow, startBlock, blocksPerWindow);
    const windowEndExclusive = getWindowEndExclusive(lastSeenWindow, startBlock, blocksPerWindow);
    console.log(
      `[window-open] window=${lastSeenWindow.toString()} range=[${windowStart.toString()},${windowEndExclusive.toString()})`
    );
  } else {
    console.log(
      `[window-wait] currentBlock=${latestBlock.toString()} is before startBlock=${startBlock.toString()}`
    );
  }

  const bootstrapFromBlock =
    latestBlock > BigInt(config.EXECUTOR_BOOTSTRAP_BLOCK_SPAN)
      ? latestBlock - BigInt(config.EXECUTOR_BOOTSTRAP_BLOCK_SPAN)
      : 0n;

  const seedLogs = await withBackoff(
    `getEvents.IntentQueued(from=${bootstrapFromBlock.toString()}, to=${latestBlock.toString()})`,
    async () =>
      hook.getEvents.IntentQueued(
        {},
        {
          fromBlock: bootstrapFromBlock,
          toBlock: latestBlock,
          strict: true,
        }
      ),
    config
  );

  for (const log of seedLogs) {
    const { windowId, intentId } = log.args;
    if (windowId === undefined || intentId === undefined) continue;
    rememberIntentQueued(windowId, intentId, intentsSeenByWindow, pendingWindows);
  }

  console.log(
    `[bootstrap] queuedLogs=${seedLogs.length.toString()} trackedWindows=${pendingWindows.size.toString()} fromBlock=${bootstrapFromBlock.toString()}`
  );

  const unwatchIntentQueued = hook.watchEvent.IntentQueued(
    {},
    {
      strict: true,
      onLogs: (logs) => {
        for (const log of logs) {
          const { windowId, intentId } = log.args;
          if (windowId === undefined || intentId === undefined) continue;
          rememberIntentQueued(windowId, intentId, intentsSeenByWindow, pendingWindows);
        }
      },
      onError: (error) => {
        console.warn(`[watch-error] IntentQueued ${String(error)}`);
      },
    }
  );

  const stop = () => {
    console.log("[executor-stop] signal received, stopping watcher...");
    unwatchIntentQueued();
    process.exit(0);
  };

  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);

  for (;;) {
    try {
      const currentBlock = await withBackoff(
        "getBlockNumber(loop)",
        async () => publicClient.getBlockNumber(),
        config
      );

      const currentWindow = getWindowIdFromBlock(currentBlock, startBlock, blocksPerWindow);

      if (currentWindow !== null) {
        if (lastSeenWindow === null) {
          const windowStart = getWindowStart(currentWindow, startBlock, blocksPerWindow);
          const windowEndExclusive = getWindowEndExclusive(currentWindow, startBlock, blocksPerWindow);
          console.log(
            `[window-open] window=${currentWindow.toString()} range=[${windowStart.toString()},${windowEndExclusive.toString()})`
          );
          lastSeenWindow = currentWindow;
        } else if (currentWindow > lastSeenWindow) {
          for (let windowId = lastSeenWindow; windowId < currentWindow; windowId += 1n) {
            const seen = intentsSeenByWindow.get(windowId) ?? 0;
            console.log(`[window-close] window=${windowId.toString()} intentsSeen=${seen.toString()}`);
            pendingWindows.add(windowId);
          }

          const windowStart = getWindowStart(currentWindow, startBlock, blocksPerWindow);
          const windowEndExclusive = getWindowEndExclusive(currentWindow, startBlock, blocksPerWindow);
          console.log(
            `[window-open] window=${currentWindow.toString()} range=[${windowStart.toString()},${windowEndExclusive.toString()})`
          );
          lastSeenWindow = currentWindow;
        }

        await processPendingWindows({
          currentWindowId: currentWindow,
          hook,
          intentsSeenByWindow,
          pendingWindows,
          config,
        });
      }
    } catch (error) {
      console.warn(`[loop-error] ${String(error)}`);
    }

    await sleep(config.EXECUTOR_POLL_INTERVAL_MS);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  runExecutorLoop().catch((error: unknown) => {
    console.error(`[executor-fatal] ${String(error)}`);
    process.exit(1);
  });
}
