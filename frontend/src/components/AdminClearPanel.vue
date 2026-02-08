<script setup lang="ts">
/*
Docs references:
- viem getContract helper: https://viem.sh/docs/contract/getContract
- viem wallet client writes (`writeContract` / contract.write): https://viem.sh/docs/clients/wallet
- viem waitForTransactionReceipt: https://viem.sh/docs/actions/public/waitForTransactionReceipt
- Uniswap v4 hooks concept (pool-scoped hook execution): https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 PoolManager lifecycle overview: https://docs.uniswap.org/contracts/v4/overview
- Uniswap v4 AsyncSwap/custom accounting context: https://docs.uniswap.org/contracts/v4/quickstart/hooks/async-swap
  Context: clearing is deferred to window boundaries in AsyncSwap-style batching.
- OpenZeppelin Uniswap Hooks base contracts: not used in this frontend component.

Note: `clear(windowId)` is permissionless in this demo flow, but this panel is intentionally
gated to a configured executor address for predictable hackathon operations.
*/

import { getContract } from "viem";
import { computed, ref } from "vue";

import { stealthBatchHookAbi } from "../abi/stealthBatchHookAbi";
import {
  ChainMismatchError,
  WalletProviderError,
  TARGET_CHAIN_ID,
  getVeilBatchContract,
  publicClient,
  targetChain,
  walletClient,
} from "../lib/viem/clients";
import {
  INVALID_CONTRACT_ADDRESS_MESSAGE,
  INVALID_EXECUTOR_ADDRESS_MESSAGE,
  MISSING_CONTRACT_ADDRESS_MESSAGE,
  MISSING_EXECUTOR_ADDRESS_MESSAGE,
  getExecutorAddress,
  getVeilBatchHookAddress,
} from "../lib/viem/contractConfig";

const address = getVeilBatchHookAddress();
const executorAddress = getExecutorAddress();

const account = ref<`0x${string}` | null>(null);
const chainId = ref<number | null>(null);
const latestBlock = ref<bigint | null>(null);
const previousWindowId = ref<bigint | null>(null);
const previousWindowCleared = ref<boolean | null>(null);
const previousWindowEnded = ref(false);
const message = ref("Connect executor wallet to run manual clear.");
const txHash = ref<string | null>(null);
const loading = ref(false);
const clearing = ref(false);

const normalizedExecutor = executorAddress?.toLowerCase() ?? null;
const normalizedAccount = computed(() => account.value?.toLowerCase() ?? null);
const isAuthorized = computed(
  () => normalizedExecutor !== null && normalizedAccount.value === normalizedExecutor,
);
const canClear = computed(
  () =>
    isAuthorized.value &&
    previousWindowEnded.value &&
    previousWindowId.value !== null &&
    previousWindowCleared.value === false,
);

function contractAddressError(): string {
  if (!import.meta.env.PUBLIC_VEIL_BATCH_HOOK_ADDRESS) {
    return MISSING_CONTRACT_ADDRESS_MESSAGE;
  }
  return INVALID_CONTRACT_ADDRESS_MESSAGE;
}

function executorAddressError(): string {
  if (!import.meta.env.PUBLIC_EXECUTOR_ADDRESS) {
    return MISSING_EXECUTOR_ADDRESS_MESSAGE;
  }
  return INVALID_EXECUTOR_ADDRESS_MESSAGE;
}

async function connectWallet(): Promise<void> {
  if (!walletClient) {
    message.value = "No injected wallet detected.";
    return;
  }
  try {
    const [connected] = await walletClient.requestAddresses();
    account.value = connected ?? null;
    chainId.value = await walletClient.getChainId();
  } catch (error) {
    message.value = error instanceof Error ? error.message : "Failed to connect wallet.";
  }
}

async function refreshWindowState(): Promise<void> {
  txHash.value = null;
  if (!address) {
    message.value = contractAddressError();
    return;
  }
  if (!executorAddress) {
    message.value = executorAddressError();
    return;
  }
  if (!walletClient) {
    message.value = "No injected wallet detected.";
    return;
  }

  loading.value = true;
  try {
    const [existing] = await walletClient.getAddresses();
    if (existing) {
      account.value = existing;
    }
    chainId.value = await walletClient.getChainId();

    const contract = getContract({
      address,
      abi: stealthBatchHookAbi,
      client: publicClient,
    });
    const [block, startBlock, blocksPerWindow] = await Promise.all([
      publicClient.getBlockNumber(),
      contract.read.startBlock(),
      contract.read.blocksPerWindow(),
    ]);
    latestBlock.value = block;

    if (block < startBlock + blocksPerWindow) {
      previousWindowEnded.value = false;
      previousWindowId.value = null;
      previousWindowCleared.value = null;
      message.value = "No completed window yet.";
      return;
    }

    const currentWindowId = (block - startBlock) / blocksPerWindow;
    const prevWindow = currentWindowId - 1n;
    const prevWindowData = await contract.read.getWindow([prevWindow]);

    previousWindowEnded.value = true;
    previousWindowId.value = prevWindow;
    previousWindowCleared.value = prevWindowData.cleared;

    if (!isAuthorized.value) {
      message.value = "Connected wallet is not EXECUTOR_ADDRESS.";
      return;
    }
    if (previousWindowCleared.value) {
      message.value = `Previous window ${prevWindow.toString()} is already cleared.`;
    } else {
      message.value = `Ready to clear previous window ${prevWindow.toString()}.`;
    }
  } catch (error) {
    message.value = error instanceof Error ? error.message : "Failed to load admin state.";
  } finally {
    loading.value = false;
  }
}

async function clearPreviousWindow(): Promise<void> {
  if (!address) {
    message.value = contractAddressError();
    return;
  }
  if (!canClear.value || previousWindowId.value === null) {
    message.value = "Cannot clear yet.";
    return;
  }
  if (!walletClient) {
    message.value = "No injected wallet detected.";
    return;
  }

  clearing.value = true;
  try {
    const [signer] = await walletClient.requestAddresses();
    if (!signer) {
      throw new WalletProviderError();
    }
    const connectedChainId = await walletClient.getChainId();
    if (connectedChainId !== TARGET_CHAIN_ID) {
      throw new ChainMismatchError(connectedChainId);
    }

    const contract = await getVeilBatchContract(address);
    const hash = await contract.write.clear([previousWindowId.value], { account: signer });
    txHash.value = hash;
    message.value = "Clear transaction submitted. Waiting for confirmation...";
    await publicClient.waitForTransactionReceipt({ hash });
    message.value = "Window cleared.";
    await refreshWindowState();
  } catch (error) {
    message.value = error instanceof Error ? error.message : "Clear transaction failed.";
  } finally {
    clearing.value = false;
  }
}
</script>

<template>
  <div class="panel">
    <p class="helper">
      Executor-only helper for demo fallback. If backend executor is off, clear the previous ended
      window manually.
    </p>
    <div class="actions">
      <button class="button" type="button" :disabled="loading || clearing" @click="connectWallet">
        Connect Wallet
      </button>
      <button class="button" type="button" :disabled="loading || clearing" @click="refreshWindowState">
        {{ loading ? "Refreshing..." : "Refresh Window" }}
      </button>
      <button
        v-if="isAuthorized"
        class="button"
        type="button"
        :disabled="!canClear || loading || clearing"
        @click="clearPreviousWindow"
      >
        {{ clearing ? "Clearing..." : "Clear Previous Window" }}
      </button>
    </div>

    <dl class="stats">
      <div>
        <dt>Executor Address</dt>
        <dd>{{ executorAddress ?? "Not set" }}</dd>
      </div>
      <div>
        <dt>Connected Account</dt>
        <dd>{{ account ?? "Not connected" }}</dd>
      </div>
      <div>
        <dt>Authorized</dt>
        <dd>{{ isAuthorized ? "Yes" : "No" }}</dd>
      </div>
      <div>
        <dt>Chain</dt>
        <dd>{{ chainId === null ? "Unknown" : `${targetChain.name} target (${chainId})` }}</dd>
      </div>
      <div>
        <dt>Latest Block</dt>
        <dd>{{ latestBlock ?? "—" }}</dd>
      </div>
      <div>
        <dt>Previous Window</dt>
        <dd>{{ previousWindowId ?? "—" }}</dd>
      </div>
      <div>
        <dt>Ended</dt>
        <dd>{{ previousWindowEnded ? "Yes" : "No" }}</dd>
      </div>
      <div>
        <dt>Cleared</dt>
        <dd>{{
          previousWindowCleared === null ? "—" : previousWindowCleared ? "Yes" : "No"
        }}</dd>
      </div>
    </dl>

    <p class="message">{{ message }}</p>
    <p v-if="txHash" class="tx">Tx: {{ txHash }}</p>
  </div>
</template>

<style scoped>
.panel {
  display: grid;
  gap: 0.75rem;
}

.helper,
.message,
.tx {
  margin: 0;
  font-size: 0.9rem;
  word-break: break-all;
}

.actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.6rem;
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

@media (max-width: 720px) {
  .stats {
    grid-template-columns: repeat(1, minmax(0, 1fr));
  }
}
</style>
