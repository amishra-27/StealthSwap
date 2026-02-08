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
const txExplorerUrl = ref<string | null>(null);

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
  txExplorerUrl.value = null;
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
    txExplorerUrl.value = `${explorerBaseUrl}/tx/${hash}`;
    pending.value = true;
    message.value = "Transaction submitted. Waiting for confirmation...";
    pushToast("Swap queued. Waiting for confirmation.", "info");

    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") {
      throw new Error("Transaction reverted.");
    }
    pending.value = false;
    message.value = "Swap intent confirmed.";
    pushToast("Swap intent confirmed.", "success");
    window.dispatchEvent(new CustomEvent(INTENTS_REFRESH_EVENT));
  } catch (error) {
    pending.value = false;
    if (error instanceof WalletProviderError || error instanceof ChainMismatchError) {
      message.value = error.message;
    } else if (error instanceof Error) {
      message.value = error.message;
      pushToast(error.message, "error");
    } else {
      message.value = "Failed to queue swap.";
      pushToast("Failed to queue swap.", "error");
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
    <p class="callout">This is a hackathon demo. Review contract before using real funds.</p>
    <div class="signed-info">
      <p class="helper-text">
        You will sign one transaction for <span class="mono">queueSwapExactIn(amountIn, minOut, recipient)</span>.
      </p>
    </div>
    <div class="field-grid">
      <label class="field">
        <span class="field-label">Amount In</span>
        <input class="input mono" v-model="amountIn" inputmode="numeric" placeholder="1000000" />
        <span class="field-help">Raw token units (uint128)</span>
      </label>
      <label class="field">
        <span class="field-label">Min Out</span>
        <input class="input mono" v-model="minOut" inputmode="numeric" placeholder="950000" />
        <span class="field-help">Slippage guard floor (uint128)</span>
      </label>
      <label class="field">
        <span class="field-label">Recipient</span>
        <input class="input mono" v-model="recipient" placeholder="0x..." />
        <span class="field-help">Defaults to connected wallet if left blank.</span>
      </label>
    </div>
    <div class="button-row">
      <button class="btn btn-primary" type="submit" :disabled="busy">
        {{ busy ? (pending ? "Pending..." : "Queueing...") : "Queue Swap" }}
      </button>
      <span v-if="pending" class="chip chip-warning">Pending Confirmation</span>
    </div>
    <p class="status-line">{{ message }}</p>
    <p v-if="txHash" class="helper-text mono">
      Tx:
      <a class="micro-link" :href="txExplorerUrl ?? '#'" target="_blank" rel="noreferrer">
        {{ txHash }}
      </a>
    </p>
  </form>
</template>

<style scoped>
.panel {
  display: grid;
  gap: 0.75rem;
}
</style>
