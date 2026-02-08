<script setup lang="ts">
/*
Docs references:
- viem wallet client (`createWalletClient` + `custom(window.ethereum)`): https://viem.sh/docs/clients/wallet
- viem TypeScript window polyfill (`viem/window`): https://viem.sh/docs/typescript
- Uniswap v4 hooks concept (pool-scoped hook execution): https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 PoolManager lifecycle overview: https://docs.uniswap.org/contracts/v4/overview
- Uniswap v4 AsyncSwap/custom accounting context: https://docs.uniswap.org/contracts/v4/quickstart/hooks/async-swap
- OpenZeppelin Uniswap Hooks base contracts: not used in this frontend component.
*/

import { computed, onMounted, onUnmounted, ref } from "vue";

import { TARGET_CHAIN_ID, targetChain, walletClient } from "../lib/viem/clients";

const account = ref<`0x${string}` | null>(null);
const chainId = ref<number | null>(null);
const busy = ref(false);

const shortAccount = computed(() => {
  if (!account.value) return "Wallet disconnected";
  return `${account.value.slice(0, 6)}...${account.value.slice(-4)}`;
});

const chainLabel = computed(() => {
  if (chainId.value === null) return "Chain: unknown";
  if (chainId.value === TARGET_CHAIN_ID) return `${targetChain.name}`;
  return `Wrong chain (${chainId.value})`;
});

async function refreshState(): Promise<void> {
  if (!walletClient) return;
  const addresses = await walletClient.getAddresses();
  account.value = addresses[0] ?? null;
  chainId.value = await walletClient.getChainId();
}

async function connect(): Promise<void> {
  if (!walletClient) return;
  busy.value = true;
  try {
    const [connected] = await walletClient.requestAddresses();
    account.value = connected ?? null;
    chainId.value = await walletClient.getChainId();
  } finally {
    busy.value = false;
  }
}

function onAccountsChanged(accounts: string[]): void {
  account.value = (accounts[0] as `0x${string}` | undefined) ?? null;
}

function onChainChanged(chainHex: string): void {
  chainId.value = Number.parseInt(chainHex, 16);
}

onMounted(() => {
  void refreshState();
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
  <div class="network-pill" :class="{ 'network-pill-warn': chainId !== null && chainId !== TARGET_CHAIN_ID }">
    <span class="network-label">{{ chainLabel }}</span>
    <span class="network-account">{{ shortAccount }}</span>
    <button v-if="!account" type="button" class="mini-btn" :disabled="busy" @click="connect">
      {{ busy ? "..." : "Connect" }}
    </button>
  </div>
</template>
