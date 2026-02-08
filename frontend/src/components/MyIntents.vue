<script setup lang="ts">
/*
Docs references:
- viem getContract helper: https://viem.sh/docs/contract/getContract
- viem contract events (`getContractEvents`): https://viem.sh/docs/contract/getContractEvents
- Uniswap v4 hooks concept (pool-scoped hook execution): https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 PoolManager lifecycle overview: https://docs.uniswap.org/contracts/v4/overview
- Uniswap v4 AsyncSwap/custom accounting context: https://docs.uniswap.org/contracts/v4/quickstart/hooks/async-swap
- Future direction: align with emerging hook metadata/indexing standards for faster caching/indexing.
- OpenZeppelin Uniswap Hooks base contracts: not used in this frontend component.
*/

import { getContract, type Address } from "viem";
import { computed, onMounted, onUnmounted, ref } from "vue";

import { stealthBatchHookAbi } from "../abi/stealthBatchHookAbi";
import {
  ChainMismatchError,
  WalletProviderError,
  explorerBaseUrl,
  getVeilBatchContract,
  publicClient,
  walletClient,
} from "../lib/viem/clients";
import {
  INVALID_CONTRACT_ADDRESS_MESSAGE,
  MISSING_CONTRACT_ADDRESS_MESSAGE,
  getVeilBatchHookAddress,
} from "../lib/viem/contractConfig";
import { pushToast } from "../lib/ui/toast";

type IntentStatus = "Queued" | "Clearable" | "Claimed" | "Failed";

type IntentRow = {
  windowId: bigint;
  intentId: bigint;
  amountIn: bigint;
  minOut: bigint;
  claimed: boolean;
  status: IntentStatus;
  claimableEstimate: bigint | null;
  canClaim: boolean;
  queueTxHash: `0x${string}` | null;
  claimTxHash: `0x${string}` | null;
};

type ClearRow = {
  windowId: bigint;
  totalIn: bigint;
  totalOut: bigint;
  txHash: `0x${string}`;
};

const address = getVeilBatchHookAddress();
const INTENTS_REFRESH_EVENT = "veilswap:intents:refresh";

const intents = ref<IntentRow[]>([]);
const recentClears = ref<ClearRow[]>([]);
const account = ref<Address | null>(null);
const message = ref("Load activity to view intent lifecycle and claim state.");
const loading = ref(false);
const claimBusyKey = ref<string | null>(null);

const hasIntents = computed(() => intents.value.length > 0);
const hasRecentClears = computed(() => recentClears.value.length > 0);

function addressError(): string {
  if (!import.meta.env.PUBLIC_VEIL_BATCH_HOOK_ADDRESS) {
    return MISSING_CONTRACT_ADDRESS_MESSAGE;
  }
  return INVALID_CONTRACT_ADDRESS_MESSAGE;
}

function toKey(windowId: bigint, intentId: bigint): string {
  return `${windowId.toString()}-${intentId.toString()}`;
}

function txExplorerUrl(hash: `0x${string}`): string {
  return `${explorerBaseUrl}/tx/${hash}`;
}

function statusChipClass(status: IntentStatus): string {
  if (status === "Clearable") return "chip-clearable";
  if (status === "Claimed") return "chip-claimed";
  if (status === "Failed") return "chip-failed";
  return "chip-queued";
}

async function ensureAccount(allowPrompt: boolean): Promise<Address | null> {
  if (!walletClient) {
    throw new WalletProviderError();
  }
  const existing = await walletClient.getAddresses();
  if (existing[0]) {
    account.value = existing[0];
    return existing[0];
  }
  if (!allowPrompt) return null;
  const requested = await walletClient.requestAddresses();
  if (!requested[0]) {
    throw new Error("Wallet did not return an account.");
  }
  account.value = requested[0];
  return requested[0];
}

async function loadIntents(allowPrompt = true): Promise<void> {
  if (!address) {
    message.value = addressError();
    return;
  }

  loading.value = true;
  try {
    const user = await ensureAccount(allowPrompt);
    if (!user) {
      message.value = "Connect wallet, then load activity.";
      intents.value = [];
      recentClears.value = [];
      return;
    }

    const readContract = getContract({
      address,
      abi: stealthBatchHookAbi,
      client: publicClient,
    });

    // Performance guard: use onchain deployment/start marker as bounded log range start.
    const [startBlock, latestBlock] = await Promise.all([
      readContract.read.startBlock(),
      publicClient.getBlockNumber(),
    ]);

    const [queuedLogs, claimedLogs, clearLogs] = await Promise.all([
      publicClient.getContractEvents({
        address,
        abi: stealthBatchHookAbi,
        eventName: "IntentQueued",
        strict: true,
        fromBlock: startBlock,
        toBlock: latestBlock,
      }),
      publicClient.getContractEvents({
        address,
        abi: stealthBatchHookAbi,
        eventName: "Claimed",
        strict: true,
        fromBlock: startBlock,
        toBlock: latestBlock,
      }),
      publicClient.getContractEvents({
        address,
        abi: stealthBatchHookAbi,
        eventName: "WindowCleared",
        strict: true,
        fromBlock: startBlock,
        toBlock: latestBlock,
      }),
    ]);

    recentClears.value = clearLogs
      .slice()
      .sort((a, b) => Number((b.blockNumber ?? 0n) - (a.blockNumber ?? 0n)))
      .slice(0, 5)
      .map((log) => ({
        windowId: log.args.windowId,
        totalIn: log.args.totalIn,
        totalOut: log.args.totalOut,
        txHash: log.transactionHash,
      }));

    const userIntents = queuedLogs.filter(
      (log) => log.args.user.toLowerCase() === user.toLowerCase(),
    );
    const claimedByUser = claimedLogs.filter(
      (log) => log.args.user.toLowerCase() === user.toLowerCase(),
    );

    const claimedTxByKey = new Map(
      claimedByUser.map((log) => [toKey(log.args.windowId, log.args.intentId), log.transactionHash]),
    );

    const uniqueWindows = [...new Set(userIntents.map((log) => log.args.windowId.toString()))].map(
      (value) => BigInt(value),
    );
    const windowPairs = await Promise.all(
      uniqueWindows.map(async (windowId) => {
        const windowData = await readContract.read.getWindow([windowId]);
        return [windowId.toString(), windowData] as const;
      }),
    );
    const windowsById = new Map(windowPairs);

    const rows = await Promise.all(
      userIntents.map(async (log) => {
        const window = log.args.windowId;
        const intent = log.args.intentId;
        const intentData = await readContract.read.getIntent([window, intent]);
        const windowData = windowsById.get(window.toString());

        const claimKey = toKey(window, intent);
        const claimHash = claimedTxByKey.get(claimKey) ?? null;
        const wasClaimed = claimHash !== null || intentData.claimed;
        const isCleared = windowData?.cleared ?? false;
        const claimableEstimate =
          isCleared && !wasClaimed && (windowData?.totalIn ?? 0n) > 0n
            ? (intentData.amountIn * (windowData?.totalOut ?? 0n)) / (windowData?.totalIn ?? 1n)
            : null;

        let status: IntentStatus = "Queued";
        if (wasClaimed) {
          status = "Claimed";
        } else if (isCleared) {
          status = "Clearable";
        }

        return {
          windowId: window,
          intentId: intent,
          amountIn: intentData.amountIn,
          minOut: intentData.minOut,
          claimed: wasClaimed,
          status,
          claimableEstimate,
          canClaim: status === "Clearable",
          queueTxHash: log.transactionHash,
          claimTxHash: claimHash,
        } satisfies IntentRow;
      }),
    );

    rows.sort((a, b) => {
      if (a.windowId === b.windowId) {
        if (a.intentId === b.intentId) return 0;
        return a.intentId > b.intentId ? -1 : 1;
      }
      return a.windowId > b.windowId ? -1 : 1;
    });

    intents.value = rows;
    message.value = rows.length === 0 ? "No intents found for this wallet." : "Activity synced.";
  } catch (error) {
    if (error instanceof WalletProviderError || error instanceof ChainMismatchError) {
      message.value = error.message;
    } else if (error instanceof Error) {
      message.value = error.message;
    } else {
      message.value = "Failed to load intents.";
    }
    pushToast(message.value, "error");
  } finally {
    loading.value = false;
  }
}

function onLoadIntentsClick(): void {
  void loadIntents();
}

function onIntentsRefreshRequested(): void {
  void loadIntents(false);
}

onMounted(() => {
  window.addEventListener(INTENTS_REFRESH_EVENT, onIntentsRefreshRequested);
});

onUnmounted(() => {
  window.removeEventListener(INTENTS_REFRESH_EVENT, onIntentsRefreshRequested);
});

async function claimIntent(row: IntentRow): Promise<void> {
  if (!address) {
    message.value = addressError();
    return;
  }

  const key = toKey(row.windowId, row.intentId);
  claimBusyKey.value = key;

  try {
    if (!walletClient) {
      throw new WalletProviderError();
    }
    const [signer] = await walletClient.requestAddresses();
    if (!signer) {
      throw new Error("Wallet did not return an account.");
    }

    const contract = await getVeilBatchContract(address);
    const hash = await contract.write.claim([row.windowId, row.intentId], { account: signer });
    await publicClient.waitForTransactionReceipt({ hash });

    intents.value = intents.value.map((item) =>
      item.windowId === row.windowId && item.intentId === row.intentId
        ? {
            ...item,
            claimTxHash: hash,
            claimed: true,
            status: "Claimed",
            claimableEstimate: null,
            canClaim: false,
          }
        : item,
    );

    window.dispatchEvent(new CustomEvent(INTENTS_REFRESH_EVENT));
    message.value = "Claim confirmed.";
    pushToast("Claim output confirmed.", "success");
  } catch (error) {
    intents.value = intents.value.map((item) =>
      item.windowId === row.windowId && item.intentId === row.intentId
        ? { ...item, status: "Failed", canClaim: true }
        : item,
    );

    if (error instanceof WalletProviderError || error instanceof ChainMismatchError) {
      message.value = error.message;
    } else if (error instanceof Error) {
      message.value = error.message;
    } else {
      message.value = "Claim failed.";
    }
    pushToast(message.value, "error");
  } finally {
    claimBusyKey.value = null;
  }
}
</script>

<template>
  <div class="panel">
    <div class="button-row">
      <button class="btn" type="button" :disabled="loading" @click="onLoadIntentsClick">
        {{ loading ? "Loading..." : "Refresh Activity" }}
      </button>
      <span class="chip" :class="hasIntents ? 'chip-success' : 'chip-queued'">
        {{ hasIntents ? `${intents.length} intents` : "No intents loaded" }}
      </span>
    </div>

    <p class="status-line">{{ message }}</p>

    <div v-if="hasIntents" class="intent-list">
      <article v-for="row in intents" :key="toKey(row.windowId, row.intentId)" class="intent-item">
        <header class="intent-head">
          <strong class="mono">Window {{ row.windowId }} / Intent {{ row.intentId }}</strong>
          <span class="chip" :class="statusChipClass(row.status)">{{ row.status }}</span>
        </header>

        <dl class="intent-metrics">
          <div class="metric">
            <span class="metric-label">Amount In</span>
            <span class="metric-value mono">{{ row.amountIn }}</span>
          </div>
          <div class="metric">
            <span class="metric-label">Min Out</span>
            <span class="metric-value mono">{{ row.minOut }}</span>
          </div>
          <div class="metric">
            <span class="metric-label">Claimable Estimate</span>
            <span class="metric-value mono">{{ row.claimableEstimate ?? "—" }}</span>
          </div>
          <div class="metric">
            <span class="metric-label">State</span>
            <span class="metric-value">{{ row.status }}</span>
          </div>
        </dl>

        <div class="intent-actions">
          <button
            class="btn btn-primary"
            type="button"
            :disabled="!row.canClaim || claimBusyKey === toKey(row.windowId, row.intentId)"
            @click="claimIntent(row)"
          >
            {{
              claimBusyKey === toKey(row.windowId, row.intentId)
                ? "Claiming..."
                : row.canClaim
                  ? "Claim Output"
                  : row.status
            }}
          </button>

          <a v-if="row.queueTxHash" class="micro-link mono" :href="txExplorerUrl(row.queueTxHash)" target="_blank" rel="noreferrer">
            Queue Tx
          </a>
          <a v-if="row.claimTxHash" class="micro-link mono" :href="txExplorerUrl(row.claimTxHash)" target="_blank" rel="noreferrer">
            Claim Tx
          </a>
        </div>
      </article>
    </div>

    <div v-if="hasRecentClears" class="glass-subpanel">
      <h4 class="section-title">Latest Clears</h4>
      <div class="intent-list">
        <article v-for="clear in recentClears" :key="clear.txHash" class="intent-item">
          <div class="intent-head">
            <strong class="mono">Window {{ clear.windowId }}</strong>
            <span class="chip chip-cleared">Cleared</span>
          </div>
          <dl class="intent-metrics">
            <div class="metric">
              <span class="metric-label">Total In</span>
              <span class="metric-value mono">{{ clear.totalIn }}</span>
            </div>
            <div class="metric">
              <span class="metric-label">Total Out</span>
              <span class="metric-value mono">{{ clear.totalOut }}</span>
            </div>
          </dl>
          <a class="micro-link mono" :href="txExplorerUrl(clear.txHash)" target="_blank" rel="noreferrer">
            View Clear Tx
          </a>
        </article>
      </div>
    </div>
  </div>
</template>

<style scoped>
.panel {
  display: grid;
  gap: 0.8rem;
}

.glass-subpanel {
  display: grid;
  gap: 0.55rem;
}

.glass-subpanel h4 {
  margin: 0;
}
</style>
