/*
Docs references:
- viem getContract: https://viem.sh/docs/contract/getContract
- Uniswap v4 hooks concept (pool-scoped hook execution): https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 PoolManager lifecycle overview: https://docs.uniswap.org/contracts/v4/overview
- Uniswap v4 AsyncSwap/custom accounting context: https://docs.uniswap.org/contracts/v4/quickstart/hooks/async-swap
*/

// This ABI must match the deployed contract interface exactly.
export const stealthBatchHookAbi = [
  {
    type: "function",
    name: "queueSwapExactIn",
    stateMutability: "nonpayable",
    inputs: [
      { name: "amountIn", type: "uint128" },
      { name: "minOut", type: "uint128" },
      { name: "recipient", type: "address" },
    ],
    outputs: [
      { name: "windowId", type: "uint64" },
      { name: "intentId", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "clear",
    stateMutability: "nonpayable",
    inputs: [{ name: "windowId", type: "uint64" }],
    outputs: [],
  },
  {
    type: "function",
    name: "claim",
    stateMutability: "nonpayable",
    inputs: [
      { name: "windowId", type: "uint64" },
      { name: "intentId", type: "uint256" },
    ],
    outputs: [{ name: "amountOut", type: "uint256" }],
  },
  {
    type: "function",
    name: "blocksPerWindow",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint64" }],
  },
  {
    type: "function",
    name: "startBlock",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint64" }],
  },
  {
    type: "function",
    name: "getWindowId",
    stateMutability: "view",
    inputs: [{ name: "blockNumber", type: "uint256" }],
    outputs: [{ name: "windowId", type: "uint64" }],
  },
  {
    type: "function",
    name: "getWindow",
    stateMutability: "view",
    inputs: [{ name: "windowId", type: "uint64" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "totalIn", type: "uint256" },
          { name: "totalOut", type: "uint256" },
          { name: "intentCount", type: "uint256" },
          { name: "terminalIntentCount", type: "uint256" },
          { name: "claimedOutSum", type: "uint256" },
          { name: "cleared", type: "bool" },
          { name: "dustSwept", type: "bool" },
        ],
      },
    ],
  },
  {
    type: "function",
    name: "getIntent",
    stateMutability: "view",
    inputs: [
      { name: "windowId", type: "uint64" },
      { name: "intentId", type: "uint256" },
    ],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "user", type: "address" },
          { name: "recipient", type: "address" },
          { name: "amountIn", type: "uint128" },
          { name: "minOut", type: "uint128" },
          { name: "windowId", type: "uint64" },
          { name: "zeroForOne", type: "bool" },
          { name: "claimed", type: "bool" },
        ],
      },
    ],
  },
  {
    type: "event",
    name: "IntentQueued",
    anonymous: false,
    inputs: [
      { indexed: true, name: "poolId", type: "bytes32" },
      { indexed: true, name: "windowId", type: "uint64" },
      { indexed: true, name: "intentId", type: "uint256" },
      { indexed: false, name: "user", type: "address" },
      { indexed: false, name: "amountIn", type: "uint128" },
      { indexed: false, name: "zeroForOne", type: "bool" },
    ],
  },
  {
    type: "event",
    name: "WindowCleared",
    anonymous: false,
    inputs: [
      { indexed: true, name: "poolId", type: "bytes32" },
      { indexed: true, name: "windowId", type: "uint64" },
      { indexed: false, name: "totalIn", type: "uint256" },
      { indexed: false, name: "totalOut", type: "uint256" },
    ],
  },
  {
    type: "event",
    name: "Claimed",
    anonymous: false,
    inputs: [
      { indexed: true, name: "poolId", type: "bytes32" },
      { indexed: true, name: "windowId", type: "uint64" },
      { indexed: true, name: "intentId", type: "uint256" },
      { indexed: false, name: "user", type: "address" },
      { indexed: false, name: "amountOut", type: "uint256" },
    ],
  },
] as const;

export type StealthBatchHookAbi = typeof stealthBatchHookAbi;

