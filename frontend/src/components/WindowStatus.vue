<script setup lang="ts">
/*
Docs references:
- viem getContract reads: https://viem.sh/docs/contract/getContract
- Uniswap v4 hooks concept (pool-scoped hook execution): https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 PoolManager lifecycle overview: https://docs.uniswap.org/contracts/v4/overview
- Uniswap v4 AsyncSwap/custom accounting context: https://docs.uniswap.org/contracts/v4/quickstart/hooks/async-swap
  Rationale: intents are deferred into windows, so phase transitions are first-class UI state.
- OpenZeppelin Uniswap Hooks base contracts: not used in this frontend component.
*/

import { computed, onMounted, onUnmounted, ref } from "vue";
import { getContract } from "viem";

import { stealthBatchHookAbi } from "../abi/stealthBatchHookAbi";
import {
  INVALID_CONTRACT_ADDRESS_MESSAGE,
  MISSING_CONTRACT_ADDRESS_MESSAGE,
  getVeilBatchHookAddress,
} from "../lib/viem/contractConfig";
import { publicClient, toUserFacingViemError } from "../lib/viem/clients";

type BatchPhase = "Collecting" | "Clearable" | "Cleared" | "Settled";

const address = getVeilBatchHookAddress();
const phaseOrder: BatchPhase[] = ["Collecting", "Clearable", "Cleared", "Settled"];

const blockNumber = ref<bigint | null>(null);
const windowId = ref<bigint | null>(null);
const blocksRemaining = ref<bigint | null>(null);
const phase = ref<BatchPhase>("Collecting");
const phaseHint = ref("Collecting intents in active window.");
const previousWindowId = ref<bigint | null>(null);
const previousWindowCleared = ref<boolean | null>(null);
const previousWindowSettled = ref<boolean | null>(null);
const busy = ref(false);
const message = ref("Tracking batch window...");
let intervalId: number | undefined;

const phaseIndex = computed(() => phaseOrder.indexOf(phase.value));

function addressError(): string {
  if (!import.meta.env.PUBLIC_VEIL_BATCH_HOOK_ADDRESS) {
    return MISSING_CONTRACT_ADDRESS_MESSAGE;
  }
  return INVALID_CONTRACT_ADDRESS_MESSAGE;
}

function updatePhaseHints(nextPhase: BatchPhase): void {
  if (nextPhase === "Collecting") {
    phaseHint.value = "Current batch window is collecting intents.";
  } else if (nextPhase === "Clearable") {
    phaseHint.value = "Previous window ended and can now be cleared.";
  } else if (nextPhase === "Cleared") {
    phaseHint.value = "Window cleared. Claims are now being processed.";
  } else {
    phaseHint.value = "Previous window is fully settled.";
  }
}

async function refresh(): Promise<void> {
  if (busy.value) return;
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

    const activeWindowId =
      latestBlock >= startBlock ? (latestBlock - startBlock) / blocksPerWindow : 0n;
    const endBlock = startBlock + (activeWindowId + 1n) * blocksPerWindow - 1n;
    const remaining = endBlock >= latestBlock ? endBlock - latestBlock + 1n : 0n;

    windowId.value = activeWindowId;
    blocksRemaining.value = remaining;

    let nextPhase: BatchPhase = "Collecting";
    previousWindowId.value = null;
    previousWindowCleared.value = null;
    previousWindowSettled.value = null;

    if (activeWindowId > 0n) {
      const prevId = activeWindowId - 1n;
      const previousWindow = await contract.read.getWindow([prevId]);
      previousWindowId.value = prevId;
      previousWindowCleared.value = previousWindow.cleared;
      previousWindowSettled.value =
        previousWindow.cleared &&
        (previousWindow.totalOut === 0n || previousWindow.claimedOutSum >= previousWindow.totalOut);

      if (!previousWindow.cleared) {
        nextPhase = "Clearable";
      } else if (previousWindowSettled.value) {
        nextPhase = "Settled";
      } else {
        nextPhase = "Cleared";
      }
    }

    phase.value = nextPhase;
    updatePhaseHints(nextPhase);
    message.value = "Window status synced.";
  } catch (error) {
    message.value = toUserFacingViemError(error);
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
    <div class="button-row">
      <button class="btn" type="button" :disabled="busy" @click="refresh">
        {{ busy ? "Refreshing..." : "Refresh Window" }}
      </button>
      <span class="chip" :class="`chip-${phase.toLowerCase()}`">{{ phase }}</span>
    </div>

    <dl class="metric-grid">
      <div class="metric">
        <span class="metric-label">Current Block</span>
        <span class="metric-value mono pulse-number" :key="`block-${blockNumber}`">
          {{ blockNumber ?? "—" }}
        </span>
      </div>
      <div class="metric">
        <span class="metric-label">Current Window ID</span>
        <span class="metric-value mono">{{ windowId ?? "—" }}</span>
      </div>
      <div class="metric">
        <span class="metric-label">Blocks Remaining</span>
        <span class="metric-value mono pulse-number" :key="`remaining-${blocksRemaining}`">
          {{ blocksRemaining ?? "—" }}
        </span>
      </div>
    </dl>

    <div class="timeline">
      <article
        v-for="(step, idx) in ['Collecting', 'Clearable', 'Cleared', 'Settled']"
        :key="step"
        class="timeline-step"
        :class="{ 'is-done': idx < phaseIndex, 'is-active': idx === phaseIndex }"
      >
        <p>Phase</p>
        <strong>{{ step }}</strong>
      </article>
    </div>

    <p class="status-line">{{ phaseHint }}</p>
    <p class="helper-text">
      Previous window:
      {{ previousWindowId ?? "—" }} / cleared:
      {{ previousWindowCleared === null ? "—" : previousWindowCleared ? "yes" : "no" }} / settled:
      {{ previousWindowSettled === null ? "—" : previousWindowSettled ? "yes" : "no" }}
    </p>
    <p class="status-line">{{ message }}</p>
  </div>
</template>

<style scoped>
.panel {
  display: grid;
  gap: 0.75rem;
}

.pulse-number {
  animation: pulseIn 380ms ease;
}

@keyframes pulseIn {
  0% {
    opacity: 0.55;
    transform: translateY(2px);
  }
  100% {
    opacity: 1;
    transform: translateY(0);
  }
}
</style>
