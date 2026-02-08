/*
Docs references:
- Uniswap v4 hooks concept (pool-scoped hook execution): https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 PoolManager lifecycle overview: https://docs.uniswap.org/contracts/v4/overview
- Uniswap v4 AsyncSwap/custom accounting context: https://docs.uniswap.org/contracts/v4/quickstart/hooks/async-swap
- OpenZeppelin Uniswap Hooks base contracts: not used in this frontend utility file.
*/

export const TOAST_EVENT = "veilswap:toast";

export type ToastKind = "info" | "success" | "warning" | "error";

export type ToastPayload = {
  id: string;
  kind: ToastKind;
  message: string;
};

export function pushToast(
  message: string,
  kind: ToastKind = "info",
): void {
  if (typeof window === "undefined") return;
  const id = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  window.dispatchEvent(
    new CustomEvent<ToastPayload>(TOAST_EVENT, {
      detail: { id, kind, message },
    }),
  );
}
