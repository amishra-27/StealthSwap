<script setup lang="ts">
/*
Docs references:
- Uniswap v4 hooks concept (pool-scoped hook execution): https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 PoolManager lifecycle overview: https://docs.uniswap.org/contracts/v4/overview
- Uniswap v4 AsyncSwap/custom accounting context: https://docs.uniswap.org/contracts/v4/quickstart/hooks/async-swap
- OpenZeppelin Uniswap Hooks base contracts: not used in this frontend component.
*/

import { onMounted, onUnmounted, ref } from "vue";

import { TOAST_EVENT, type ToastPayload } from "../lib/ui/toast";

type ToastEntry = ToastPayload & { timeoutId: number };

const toasts = ref<ToastEntry[]>([]);
const MAX_TOASTS = 4;
const DISPLAY_MS = 4200;

function dismissToast(id: string): void {
  const match = toasts.value.find((toast) => toast.id === id);
  if (match) {
    window.clearTimeout(match.timeoutId);
  }
  toasts.value = toasts.value.filter((toast) => toast.id !== id);
}

function onToast(event: Event): void {
  const custom = event as CustomEvent<ToastPayload>;
  const payload = custom.detail;
  if (!payload?.message) return;

  // Deterministic anti-spam behavior: replace same message/kind instead of stacking duplicates.
  const duplicate = toasts.value.find(
    (toast) => toast.message === payload.message && toast.kind === payload.kind,
  );
  if (duplicate) {
    dismissToast(duplicate.id);
  }

  const timeoutId = window.setTimeout(() => dismissToast(payload.id), DISPLAY_MS);
  const nextToast: ToastEntry = { ...payload, timeoutId };

  toasts.value = [nextToast, ...toasts.value].slice(0, MAX_TOASTS);
}

onMounted(() => {
  window.addEventListener(TOAST_EVENT, onToast as EventListener);
});

onUnmounted(() => {
  window.removeEventListener(TOAST_EVENT, onToast as EventListener);
  toasts.value.forEach((toast) => window.clearTimeout(toast.timeoutId));
});
</script>

<template>
  <aside class="toast-viewport" aria-live="polite" aria-atomic="true">
    <article
      v-for="toast in toasts"
      :key="toast.id"
      class="toast-item"
      :class="`toast-${toast.kind}`"
      role="status"
    >
      <p>{{ toast.message }}</p>
      <button type="button" class="toast-dismiss" @click="dismissToast(toast.id)">Dismiss</button>
    </article>
  </aside>
</template>
