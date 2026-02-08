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
    <div class="actions">
      <button type="button" class="button" :disabled="busy" @click="connectWallet">
        {{ busy ? "Connecting..." : "Connect Wallet" }}
      </button>
      <button
        v-if="wrongChain"
        type="button"
        class="button button-secondary"
        :disabled="busy"
        @click="switchToSepolia"
      >
        Switch to Sepolia
      </button>
    </div>
    <dl class="details">
      <div>
        <dt>Address</dt>
        <dd>{{ shortAccount }}</dd>
      </div>
      <div>
        <dt>Chain ID</dt>
        <dd>{{ chainId ?? "Unknown" }}</dd>
      </div>
      <div>
        <dt>Network</dt>
        <dd>{{ formatChainLabel(chainId) }}</dd>
      </div>
    </dl>
    <p v-if="wrongChain" class="warning">Wrong chain detected. Switch wallet to Sepolia.</p>
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

.button-secondary {
  background: #ffffff;
  color: #111;
}

.details {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 0.5rem;
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

.warning {
  margin: 0;
  font-size: 0.9rem;
  color: #9e3b00;
}

@media (max-width: 720px) {
  .details {
    grid-template-columns: repeat(1, minmax(0, 1fr));
  }
}
</style>
