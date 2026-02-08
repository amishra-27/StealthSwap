<script setup lang="ts">
/*
Docs references:
- viem wallet client writes: https://viem.sh/docs/clients/wallet
- viem getContract helper: https://viem.sh/docs/contract/getContract
- Uniswap v4 hooks concept (pool-scoped hook execution): https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 PoolManager lifecycle overview: https://docs.uniswap.org/contracts/v4/overview
- Uniswap v4 AsyncSwap/custom accounting context: https://docs.uniswap.org/contracts/v4/quickstart/hooks/async-swap
- OpenZeppelin Uniswap Hooks base contracts: not used in this frontend component.
*/

import { ref } from "vue";

import {
  ChainMismatchError,
  WalletProviderError,
  getVeilBatchContract,
  walletClient,
} from "../lib/viem/clients";
import {
  INVALID_CONTRACT_ADDRESS_MESSAGE,
  MISSING_CONTRACT_ADDRESS_MESSAGE,
  getVeilBatchHookAddress,
} from "../lib/viem/contractConfig";

const address = getVeilBatchHookAddress();
const MAX_UINT128 = (1n << 128n) - 1n;

const amountIn = ref("");
const minOut = ref("");
const busy = ref(false);
const message = ref("Enter raw token units and queue your swap intent.");
const txHash = ref<string | null>(null);

function addressError(): string {
  if (!import.meta.env.PUBLIC_VEIL_BATCH_HOOK_ADDRESS) {
    return MISSING_CONTRACT_ADDRESS_MESSAGE;
  }
  return INVALID_CONTRACT_ADDRESS_MESSAGE;
}

function parseUint128(raw: string, fieldName: string): bigint {
  if (!/^\d+$/.test(raw)) {
    throw new Error(`${fieldName} must be a non-negative integer.`);
  }
  const parsed = BigInt(raw);
  if (parsed > MAX_UINT128) {
    throw new Error(`${fieldName} exceeds uint128.`);
  }
  return parsed;
}

async function queueSwap(): Promise<void> {
  txHash.value = null;
  if (!address) {
    message.value = addressError();
    return;
  }
  if (!walletClient) {
    message.value = "No injected wallet detected.";
    return;
  }

  busy.value = true;
  try {
    const parsedAmountIn = parseUint128(amountIn.value.trim(), "amountIn");
    const parsedMinOut = parseUint128(minOut.value.trim(), "minOut");

    const [account] = await walletClient.requestAddresses();
    if (!account) {
      throw new Error("Wallet did not return an account.");
    }

    const contract = await getVeilBatchContract(address);
    const hash = await contract.write.queueSwapExactIn(
      [parsedAmountIn, parsedMinOut, account],
      { account },
    );
    txHash.value = hash;
    message.value = "Swap intent queued. Wait for window clear before claiming.";
  } catch (error) {
    if (error instanceof WalletProviderError || error instanceof ChainMismatchError) {
      message.value = error.message;
    } else if (error instanceof Error) {
      message.value = error.message;
    } else {
      message.value = "Failed to queue swap.";
    }
  } finally {
    busy.value = false;
  }
}
</script>

<template>
  <form class="panel" @submit.prevent="queueSwap">
    <label>
      <span>Amount In (uint128)</span>
      <input v-model="amountIn" inputmode="numeric" placeholder="1000000" />
    </label>
    <label>
      <span>Min Out (uint128)</span>
      <input v-model="minOut" inputmode="numeric" placeholder="950000" />
    </label>
    <button class="button" type="submit" :disabled="busy">
      {{ busy ? "Submitting..." : "Queue Swap" }}
    </button>
    <p class="message">{{ message }}</p>
    <p v-if="txHash" class="tx">Tx: {{ txHash }}</p>
  </form>
</template>

<style scoped>
.panel {
  display: grid;
  gap: 0.75rem;
}

label {
  display: grid;
  gap: 0.35rem;
}

span {
  font-size: 0.85rem;
  color: #404040;
}

input {
  border: 1px solid #c8c8c8;
  border-radius: 0.4rem;
  padding: 0.55rem 0.6rem;
  font: inherit;
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

.message,
.tx {
  margin: 0;
  font-size: 0.9rem;
  word-break: break-all;
}
</style>
