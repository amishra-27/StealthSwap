<script setup lang="ts">
/*
Docs references:
- viem wallet client (`createWalletClient` + `custom(window.ethereum)`): https://viem.sh/docs/clients/wallet
- viem wallet `switchChain`: https://viem.sh/docs/actions/wallet/switchChain
- viem TypeScript window polyfill (`viem/window`): https://viem.sh/docs/typescript
- Uniswap v4 hooks concept (pool-scoped hook execution): https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 PoolManager lifecycle overview: https://docs.uniswap.org/contracts/v4/overview
- Uniswap v4 AsyncSwap/custom accounting context: https://docs.uniswap.org/contracts/v4/quickstart/hooks/async-swap
- OpenZeppelin Uniswap Hooks base contracts: not used in this frontend component.
*/

import type { Address } from "viem";
import { computed, onMounted, onUnmounted, ref } from "vue";

import {
  ChainMismatchError,
  TARGET_CHAIN_ID,
  WalletProviderError,
  sepoliaRpcUrl,
  targetChain,
  walletClient,
} from "../lib/viem/clients";
import { pushToast } from "../lib/ui/toast";

const emit = defineEmits<{
  connected: [address: Address | null];
}>();

const account = ref<Address | null>(null);
const chainId = ref<number | null>(null);
const message = ref("Connect your wallet to begin.");
const busy = ref(false);
const wrongChain = computed(
  () => chainId.value !== null && chainId.value !== TARGET_CHAIN_ID,
);

const shortAccount = computed(() => {
  if (!account.value) return "Not connected";
  return `${account.value.slice(0, 6)}...${account.value.slice(-4)}`;
});

function formatChainLabel(id: number | null): string {
  if (id === null) return "Unknown";
  if (id === TARGET_CHAIN_ID) return `${targetChain.name} (${id})`;
  return `Wrong network (${id})`;
}

function setConnectedAccount(next: Address | null): void {
  account.value = next;
  emit("connected", next);
}

async function refreshWalletState(silent = false): Promise<void> {
  if (!walletClient) {
    if (!silent) {
      message.value = "No injected wallet detected.";
    }
    return;
  }

  try {
    const addresses = await walletClient.getAddresses();
    setConnectedAccount(addresses[0] ?? null);
    chainId.value = await walletClient.getChainId();

    if (chainId.value !== TARGET_CHAIN_ID) {
      message.value = `Wrong network. Please switch to ${targetChain.name} (${TARGET_CHAIN_ID}).`;
      return;
    }
    message.value = account.value
      ? "Wallet connected on Sepolia."
      : "Wallet detected. Click connect.";
  } catch (error) {
    message.value = error instanceof Error ? error.message : "Failed to read wallet state.";
  }
}

async function connectWallet(): Promise<void> {
  if (!walletClient) {
    message.value = "No injected wallet detected.";
    return;
  }

  busy.value = true;
  try {
    const [connectedAccount] = await walletClient.requestAddresses();
    setConnectedAccount(connectedAccount ?? null);
    chainId.value = await walletClient.getChainId();

    if (chainId.value !== TARGET_CHAIN_ID) {
      throw new ChainMismatchError(chainId.value);
    }
    message.value = "Wallet connected.";
    pushToast("Wallet connected on Sepolia.", "success");
  } catch (error) {
    if (error instanceof WalletProviderError || error instanceof ChainMismatchError) {
      message.value = error.message;
    } else if (error instanceof Error) {
      message.value = error.message;
    } else {
      message.value = "Wallet connection failed.";
    }
  } finally {
    busy.value = false;
  }
}

async function switchToSepolia(): Promise<void> {
  if (!walletClient) {
    message.value = "No injected wallet detected.";
    return;
  }

  busy.value = true;
  try {
    await walletClient.switchChain({ id: TARGET_CHAIN_ID });
    chainId.value = TARGET_CHAIN_ID;
    message.value = `Switched to ${targetChain.name}.`;
    pushToast(`Network switched to ${targetChain.name}.`, "success");
    await refreshWalletState(true);
  } catch (error) {
    const code = typeof error === "object" && error && "code" in error ? error.code : undefined;
    if (code === 4902 && window.ethereum) {
      try {
        await window.ethereum.request({
          method: "wallet_addEthereumChain",
          params: [
            {
              chainId: `0x${TARGET_CHAIN_ID.toString(16)}`,
              chainName: targetChain.name,
              nativeCurrency: targetChain.nativeCurrency,
              rpcUrls: [sepoliaRpcUrl],
              blockExplorerUrls: targetChain.blockExplorers?.default?.url
                ? [targetChain.blockExplorers.default.url]
                : [],
            },
          ],
        });
        await walletClient.switchChain({ id: TARGET_CHAIN_ID });
        chainId.value = TARGET_CHAIN_ID;
        message.value = `Switched to ${targetChain.name}.`;
        pushToast(`Network switched to ${targetChain.name}.`, "success");
        await refreshWalletState(true);
      } catch (addError) {
        message.value = addError instanceof Error ? addError.message : "Failed to add/switch chain.";
      }
      return;
    }
    message.value = error instanceof Error ? error.message : "Failed to switch network.";
  } finally {
    busy.value = false;
  }
}

function onAccountsChanged(accounts: string[]): void {
  setConnectedAccount((accounts[0] as Address | undefined) ?? null);
}

function onChainChanged(chainHex: string): void {
  chainId.value = Number.parseInt(chainHex, 16);
  if (chainId.value !== TARGET_CHAIN_ID) {
    message.value = `Wrong network. Please switch to ${targetChain.name} (${TARGET_CHAIN_ID}).`;
    return;
  }
  message.value = "Wallet connected on Sepolia.";
}

onMounted(() => {
  void refreshWalletState(true);
  if (!window.ethereum) return;
  window.ethereum.on("accountsChanged", onAccountsChanged);
  window.ethereum.on("chainChanged", onChainChanged);
});

onUnmounted(() => {
  if (!window.ethereum) return;
  window.ethereum.removeListener("accountsChanged", onAccountsChanged);
  window.ethereum.removeListener("chainChanged", onChainChanged);
});
</script>

<template>
  <div class="panel">
    <div class="button-row">
      <button type="button" class="btn btn-primary" :disabled="busy" @click="connectWallet">
        {{ busy ? "Connecting..." : "Connect Wallet" }}
      </button>
      <button
        v-if="wrongChain"
        type="button"
        class="btn"
        :disabled="busy"
        @click="switchToSepolia"
      >
        Switch to Sepolia
      </button>
    </div>
    <div class="signed-info">
      <p class="helper-text">
        You will sign wallet prompts only for connect and network-switch requests.
      </p>
    </div>
    <dl class="metric-grid">
      <div class="metric">
        <span class="metric-label">Address</span>
        <span class="metric-value mono">{{ shortAccount }}</span>
      </div>
      <div class="metric">
        <span class="metric-label">Chain ID</span>
        <span class="metric-value mono">{{ chainId ?? "Unknown" }}</span>
      </div>
      <div class="metric">
        <span class="metric-label">Network</span>
        <span class="metric-value">{{ formatChainLabel(chainId) }}</span>
      </div>
    </dl>
    <p v-if="wrongChain" class="callout">Wrong chain detected. Switch wallet to Sepolia.</p>
    <p class="status-line">{{ message }}</p>
  </div>
</template>
