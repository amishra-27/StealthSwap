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
  explorerBaseUrl,
  getVeilBatchContract,
  publicClient,
  targetChain,
  toUserFacingViemError,
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
import { pushToast } from "../lib/ui/toast";

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
  if (!import.meta.env.PUBLIC_EXECUTOR_ADDRESS && !import.meta.env.EXECUTOR_ADDRESS) {
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
    if (account.value?.toLowerCase() === normalizedExecutor) {
      pushToast("Executor wallet connected.", "success");
    }
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
    message.value = toUserFacingViemError(error);
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
    pushToast("Clear transaction submitted.", "info");
    await publicClient.waitForTransactionReceipt({ hash });
    message.value = "Window cleared.";
    pushToast("Window clear confirmed.", "success");
    await refreshWindowState();
  } catch (error) {
    message.value = toUserFacingViemError(error);
    pushToast(message.value, "error");
  } finally {
    clearing.value = false;
  }
}

const txExplorerUrl = computed(() =>
  txHash.value ? `${explorerBaseUrl}/tx/${txHash.value}` : null,
);
</script>

<template>
  <div class="panel">
    <p class="helper-text">
      Executor-only helper for demo fallback. If backend executor is off, clear the previous ended
      window manually.
    </p>
    <div class="button-row">
      <button class="btn" type="button" :disabled="loading || clearing" @click="connectWallet">
        Connect Wallet
      </button>
      <button class="btn" type="button" :disabled="loading || clearing" @click="refreshWindowState">
        {{ loading ? "Refreshing..." : "Refresh Window" }}
      </button>
      <button
        v-if="isAuthorized"
        class="btn btn-primary"
        type="button"
        :disabled="!canClear || loading || clearing"
        @click="clearPreviousWindow"
      >
        {{ clearing ? "Clearing..." : "Clear Previous Window" }}
      </button>
      <span v-if="!isAuthorized" class="chip chip-warning">Executor address mismatch</span>
    </div>

    <dl class="metric-grid">
      <div class="metric">
        <span class="metric-label">Executor Address</span>
        <span class="metric-value mono">{{ executorAddress ?? "Not set" }}</span>
      </div>
      <div class="metric">
        <span class="metric-label">Connected Account</span>
        <span class="metric-value mono">{{ account ?? "Not connected" }}</span>
      </div>
      <div class="metric">
        <span class="metric-label">Authorized</span>
        <span class="metric-value">{{ isAuthorized ? "Yes" : "No" }}</span>
      </div>
      <div class="metric">
        <span class="metric-label">Chain</span>
        <span class="metric-value">{{ chainId === null ? "Unknown" : `${targetChain.name} (${chainId})` }}</span>
      </div>
      <div class="metric">
        <span class="metric-label">Latest Block</span>
        <span class="metric-value mono">{{ latestBlock ?? "—" }}</span>
      </div>
      <div class="metric">
        <span class="metric-label">Previous Window</span>
        <span class="metric-value mono">{{ previousWindowId ?? "—" }}</span>
      </div>
      <div class="metric">
        <span class="metric-label">Ended</span>
        <span class="metric-value">{{ previousWindowEnded ? "Yes" : "No" }}</span>
      </div>
      <div class="metric">
        <span class="metric-label">Cleared</span>
        <span class="metric-value">{{
          previousWindowCleared === null ? "—" : previousWindowCleared ? "Yes" : "No"
        }}</span>
      </div>
    </dl>

    <p class="status-line">{{ message }}</p>
    <p v-if="txHash" class="helper-text mono">
      Tx:
      <a class="micro-link" :href="txExplorerUrl ?? '#'" target="_blank" rel="noreferrer">
        {{ txHash }}
      </a>
    </p>
  </div>
</template>

<style scoped>
.panel {
  display: grid;
  gap: 0.75rem;
}
</style>
