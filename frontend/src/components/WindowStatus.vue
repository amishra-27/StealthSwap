<script setup lang="ts">
/*
Docs references:
- viem getContract reads: https://viem.sh/docs/contract/getContract
- Uniswap v4 hooks concept (pool-scoped hook execution): https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 PoolManager lifecycle overview: https://docs.uniswap.org/contracts/v4/overview
- Uniswap v4 AsyncSwap/custom accounting context: https://docs.uniswap.org/contracts/v4/quickstart/hooks/async-swap
  Rationale: intents clear after a batching window, so the UI tracks window progress and remaining blocks.
- OpenZeppelin Uniswap Hooks base contracts: not used in this frontend component.
*/

import { getContract } from "viem";
import { onMounted, onUnmounted, ref } from "vue";

import { stealthBatchHookAbi } from "../abi/stealthBatchHookAbi";
import {
  INVALID_CONTRACT_ADDRESS_MESSAGE,
  MISSING_CONTRACT_ADDRESS_MESSAGE,
  getVeilBatchHookAddress,
} from "../lib/viem/contractConfig";
import { publicClient } from "../lib/viem/clients";

const address = getVeilBatchHookAddress();

const blockNumber = ref<bigint | null>(null);
const windowId = ref<bigint | null>(null);
const endBlock = ref<bigint | null>(null);
const blocksRemaining = ref<bigint | null>(null);
const message = ref("Loading window state...");
const busy = ref(false);
let intervalId: number | undefined;

function addressError(): string {
  if (!import.meta.env.PUBLIC_VEIL_BATCH_HOOK_ADDRESS) {
    return MISSING_CONTRACT_ADDRESS_MESSAGE;
  }
  return INVALID_CONTRACT_ADDRESS_MESSAGE;
}

async function refresh(): Promise<void> {
  if (!address) {
    message.value = addressError();
    return;
  }

  busy.value = true;
  try {
    const contract = getContract({
      address,
      abi: stealthBatchHookAbi,
      client: publicClient,
    });

    const [latestBlock, startBlock, blocksPerWindow] = await Promise.all([
      publicClient.getBlockNumber(),
      contract.read.startBlock(),
      contract.read.blocksPerWindow(),
    ]);

    blockNumber.value = latestBlock;

    const activeWindowId = latestBlock >= startBlock ? (latestBlock - startBlock) / blocksPerWindow : 0n;

    windowId.value = activeWindowId;
    endBlock.value = startBlock + (activeWindowId + 1n) * blocksPerWindow - 1n;
    blocksRemaining.value =
      endBlock.value >= latestBlock ? endBlock.value - latestBlock + 1n : 0n;

    message.value = "Window status updated.";
  } catch (error) {
    message.value = error instanceof Error ? error.message : "Failed to load window state.";
  } finally {
    busy.value = false;
  }
}

onMounted(() => {
  void refresh();
  intervalId = window.setInterval(() => {
    void refresh();
  }, 5000);
});

onUnmounted(() => {
  if (intervalId !== undefined) {
    window.clearInterval(intervalId);
  }
});
</script>

<template>
  <div class="panel">
    <div class="actions">
      <button class="button" type="button" :disabled="busy" @click="refresh">
        {{ busy ? "Refreshing..." : "Refresh" }}
      </button>
    </div>

    <dl class="stats">
      <div>
        <dt>Block Number</dt>
        <dd>{{ blockNumber ?? "—" }}</dd>
      </div>
      <div>
        <dt>Window ID</dt>
        <dd>{{ windowId ?? "—" }}</dd>
      </div>
      <div>
        <dt>Countdown (blocks)</dt>
        <dd>{{ blocksRemaining ?? "—" }}</dd>
      </div>
    </dl>
    <p class="message">{{ message }}</p>
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

.stats {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0.5rem 1rem;
}

dt {
  font-size: 0.8rem;
  color: #5b5b5b;
}

dd {
  margin: 0;
  font-weight: 600;
}

.message {
  margin: 0;
  font-size: 0.9rem;
}
</style>
