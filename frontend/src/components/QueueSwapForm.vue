<script setup lang="ts">
/*
Docs references:
- viem wallet client writes: https://viem.sh/docs/clients/wallet
- viem waitForTransactionReceipt: https://viem.sh/docs/actions/public/waitForTransactionReceipt
- viem getContract helper: https://viem.sh/docs/contract/getContract
- Uniswap v4 hooks concept (pool-scoped hook execution): https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 PoolManager lifecycle overview: https://docs.uniswap.org/contracts/v4/overview
- Uniswap v4 AsyncSwap/custom accounting context: https://docs.uniswap.org/contracts/v4/quickstart/hooks/async-swap
  Rationale: hook behavior is pool-scoped, and batched intents clear later in the lifecycle.
- OpenZeppelin Uniswap Hooks base contracts: not used in this frontend component.
*/

import { isAddress, type Address } from "viem";
import { onMounted, ref } from "vue";

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

const address = getVeilBatchHookAddress();
const MAX_UINT128 = (1n << 128n) - 1n;
const INTENTS_REFRESH_EVENT = "veilswap:intents:refresh";

const amountIn = ref("");
const minOut = ref("");
const recipient = ref("");
const busy = ref(false);
const message = ref("Enter raw token units and queue your swap intent.");
const txHash = ref<string | null>(null);
const pending = ref(false);

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

function parseRecipient(raw: string, fallbackRecipient: Address): Address {
  const trimmed = raw.trim();
  if (!trimmed) {
    return fallbackRecipient;
  }
  if (!isAddress(trimmed)) {
    throw new Error("recipient must be a valid 0x address.");
  }
  return trimmed;
}

async function hydrateDefaultRecipient(): Promise<void> {
  if (!walletClient) return;
  const [connectedAccount] = await walletClient.getAddresses();
  if (connectedAccount && !recipient.value.trim()) {
    recipient.value = connectedAccount;
  }
}

async function queueSwap(): Promise<void> {
  txHash.value = null;
  pending.value = false;
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

    message.value = "Confirm transaction in wallet...";
    const [account] = await walletClient.requestAddresses();
    if (!account) {
      throw new Error("Wallet did not return an account.");
    }
    if (!recipient.value.trim()) {
      recipient.value = account;
    }
    const parsedRecipient = parseRecipient(recipient.value, account);

    const contract = await getVeilBatchContract(address);
    const hash = await contract.write.queueSwapExactIn(
      [parsedAmountIn, parsedMinOut, parsedRecipient],
      { account },
    );
    txHash.value = hash;
    pending.value = true;
    message.value = "Transaction submitted. Waiting for confirmation...";

    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") {
      throw new Error("Transaction reverted.");
    }
    pending.value = false;
    message.value = "Swap intent confirmed.";
    window.dispatchEvent(new CustomEvent(INTENTS_REFRESH_EVENT));
  } catch (error) {
    pending.value = false;
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

onMounted(() => {
  void hydrateDefaultRecipient();
});
</script>

<template>
  <form class="panel" @submit.prevent="queueSwap">
    <p class="warning">This is a hackathon demo. Review contract before using real funds.</p>
    <label>
      <span>Amount In (uint128)</span>
      <input v-model="amountIn" inputmode="numeric" placeholder="1000000" />
    </label>
    <label>
      <span>Min Out (uint128)</span>
      <input v-model="minOut" inputmode="numeric" placeholder="950000" />
    </label>
    <label>
      <span>Recipient (default: connected wallet)</span>
      <input v-model="recipient" placeholder="0x..." />
    </label>
    <button class="button" type="submit" :disabled="busy">
      {{ busy ? (pending ? "Pending..." : "Submitting...") : "Queue Swap" }}
    </button>
    <p v-if="pending" class="pending">Pending: intent submitted, waiting for confirmation.</p>
    <p class="message">{{ message }}</p>
    <p v-if="txHash" class="tx">Tx: {{ txHash }}</p>
  </form>
</template>

<style scoped>
.panel {
  display: grid;
  gap: 0.75rem;
}

.warning {
  margin: 0;
  padding: 0.55rem 0.65rem;
  border: 1px solid #f2c28b;
  border-radius: 0.4rem;
  background: #fff6ec;
  color: #834100;
  font-size: 0.88rem;
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

.pending {
  margin: 0;
  font-size: 0.9rem;
  color: #0d4f8a;
}
</style>
