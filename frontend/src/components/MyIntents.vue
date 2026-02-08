<script setup lang="ts">
/*
Docs references:
- viem getContract helper: https://viem.sh/docs/contract/getContract
- viem contract events (`getContractEvents`): https://viem.sh/docs/contract/getContractEvents
- Uniswap v4 hooks concept (pool-scoped hook execution): https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 PoolManager lifecycle overview: https://docs.uniswap.org/contracts/v4/overview
- Uniswap v4 AsyncSwap/custom accounting context: https://docs.uniswap.org/contracts/v4/quickstart/hooks/async-swap
- Future direction: adopt standardized hook metadata/indexing conventions for faster caching/indexing.
- OpenZeppelin Uniswap Hooks base contracts: not used in this frontend component.
*/

import { getContract, type Address } from "viem";
import { computed, onMounted, onUnmounted, ref } from "vue";

import { stealthBatchHookAbi } from "../abi/stealthBatchHookAbi";
import {
  ChainMismatchError,
  WalletProviderError,
  getVeilBatchContract,
  publicClient,
  walletClient,
} from "../lib/viem/clients";
import {
  INVALID_CONTRACT_ADDRESS_MESSAGE,
  MISSING_CONTRACT_ADDRESS_MESSAGE,
  getVeilBatchHookAddress,
} from "../lib/viem/contractConfig";

type IntentRow = {
  windowId: bigint;
  intentId: bigint;
  amountIn: bigint;
  minOut: bigint;
  claimed: boolean;
  status: "Pending Clear" | "Claimable" | "Claimed";
  claimableEstimate: bigint | null;
  canClaim: boolean;
  claimTxHash: string | null;
};

const address = getVeilBatchHookAddress();
const INTENTS_REFRESH_EVENT = "veilswap:intents:refresh";

const intents = ref<IntentRow[]>([]);
const account = ref<Address | null>(null);
const message = ref("Load intents to see claimable entries.");
const loading = ref(false);
const claimBusyKey = ref<string | null>(null);

const hasIntents = computed(() => intents.value.length > 0);

function addressError(): string {
  if (!import.meta.env.PUBLIC_VEIL_BATCH_HOOK_ADDRESS) {
    return MISSING_CONTRACT_ADDRESS_MESSAGE;
  }
  return INVALID_CONTRACT_ADDRESS_MESSAGE;
}

function toKey(windowId: bigint, intentId: bigint): string {
  return `${windowId.toString()}-${intentId.toString()}`;
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
  if (!allowPrompt) {
    return null;
  }
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
      message.value = "Connect wallet, then load intents.";
      intents.value = [];
      return;
    }
    const readContract = getContract({
      address,
      abi: stealthBatchHookAbi,
      client: publicClient,
    });

    // Use contract startBlock as lower bound to keep event scan performant.
    const startBlock = await readContract.read.startBlock();

    const [queuedLogs, claimedLogs] = await Promise.all([
      publicClient.getContractEvents({
        address,
        abi: stealthBatchHookAbi,
        eventName: "IntentQueued",
        strict: true,
        fromBlock: startBlock,
      }),
      publicClient.getContractEvents({
        address,
        abi: stealthBatchHookAbi,
        eventName: "Claimed",
        strict: true,
        fromBlock: startBlock,
      }),
    ]);

    const userIntents = queuedLogs.filter(
      (log) => log.args.user.toLowerCase() === user.toLowerCase(),
    );
    const claimedByUser = claimedLogs.filter(
      (log) => log.args.user.toLowerCase() === user.toLowerCase(),
    );

    const claimedKeys = new Set(
      claimedByUser.map((log) => toKey(log.args.windowId, log.args.intentId)),
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

        const wasClaimed = claimedKeys.has(toKey(window, intent)) || intentData.claimed;
        const isCleared = windowData?.cleared ?? false;
        const claimableEstimate =
          isCleared && !wasClaimed && (windowData?.totalIn ?? 0n) > 0n
            ? (intentData.amountIn * (windowData?.totalOut ?? 0n)) / (windowData?.totalIn ?? 1n)
            : null;

        let status: IntentRow["status"] = "Pending Clear";
        if (wasClaimed) {
          status = "Claimed";
        } else if (isCleared) {
          status = "Claimable";
        }

        return {
          windowId: window,
          intentId: intent,
          amountIn: intentData.amountIn,
          minOut: intentData.minOut,
          claimed: wasClaimed,
          status,
          claimableEstimate,
          canClaim: status === "Claimable",
          claimTxHash: null,
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
    message.value = rows.length === 0 ? "No intents found for this wallet." : "Intents loaded.";
  } catch (error) {
    if (error instanceof WalletProviderError || error instanceof ChainMismatchError) {
      message.value = error.message;
    } else if (error instanceof Error) {
      message.value = error.message;
    } else {
      message.value = "Failed to load intents.";
    }
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
  } catch (error) {
    if (error instanceof WalletProviderError || error instanceof ChainMismatchError) {
      message.value = error.message;
    } else if (error instanceof Error) {
      message.value = error.message;
    } else {
      message.value = "Claim failed.";
    }
  } finally {
    claimBusyKey.value = null;
  }
}
</script>

<template>
  <div class="panel">
    <div class="actions">
      <button class="button" type="button" :disabled="loading" @click="onLoadIntentsClick">
        {{ loading ? "Loading..." : "Load My Intents" }}
      </button>
    </div>
    <p class="message">{{ message }}</p>

    <div v-if="hasIntents" class="list">
      <article v-for="row in intents" :key="toKey(row.windowId, row.intentId)" class="item">
        <dl>
          <div>
            <dt>Window</dt>
            <dd>{{ row.windowId }}</dd>
          </div>
          <div>
            <dt>Intent</dt>
            <dd>{{ row.intentId }}</dd>
          </div>
          <div>
            <dt>Amount In</dt>
            <dd>{{ row.amountIn }}</dd>
          </div>
          <div>
            <dt>Min Out</dt>
            <dd>{{ row.minOut }}</dd>
          </div>
          <div>
            <dt>Status</dt>
            <dd>{{ row.status }}</dd>
          </div>
          <div>
            <dt>Claimable Estimate</dt>
            <dd>{{ row.claimableEstimate ?? "—" }}</dd>
          </div>
        </dl>

        <button
          class="button"
          type="button"
          :disabled="!row.canClaim || claimBusyKey === toKey(row.windowId, row.intentId)"
          @click="claimIntent(row)"
        >
          {{
            claimBusyKey === toKey(row.windowId, row.intentId)
              ? "Claiming..."
              : row.canClaim
                ? "Claim"
                : row.status
          }}
        </button>
        <p v-if="row.claimTxHash" class="tx">Claim Tx: {{ row.claimTxHash }}</p>
      </article>
    </div>
  </div>
</template>

<style scoped>
.panel {
  display: grid;
  gap: 0.75rem;
}

.actions {
  display: flex;
  gap: 0.75rem;
}

.button {
  border: 1px solid #222;
  background: #101010;
  color: #fff;
  padding: 0.5rem 0.75rem;
  border-radius: 0.4rem;
  font: inherit;
  cursor: pointer;
}

.button:disabled {
  opacity: 0.7;
  cursor: not-allowed;
}

.message {
  margin: 0;
  font-size: 0.9rem;
}

.list {
  display: grid;
  gap: 0.75rem;
}

.item {
  border: 1px solid #d9d9d9;
  border-radius: 0.5rem;
  padding: 0.75rem;
  display: grid;
  gap: 0.6rem;
}

dl {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0.4rem 0.8rem;
}

dt {
  font-size: 0.8rem;
  color: #5b5b5b;
}

dd {
  margin: 0;
  font-weight: 600;
  word-break: break-all;
}

.tx {
  margin: 0;
  font-size: 0.85rem;
  word-break: break-all;
}
</style>
