<!--
Docs references:
- Uniswap v4 hooks concept (pool-scoped hook execution): https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 PoolManager lifecycle overview: https://docs.uniswap.org/contracts/v4/overview
- Uniswap v4 AsyncSwap/custom accounting context: https://docs.uniswap.org/contracts/v4/quickstart/hooks/async-swap
- OpenZeppelin Uniswap Hooks base contracts: not used in this brand guide.
-->

# StealthSwap Brand System

## Positioning

StealthSwap presents privacy as execution quality:

- batching reduces per-user timing leakage
- deterministic rules deliver verifiable outcomes
- Uniswap v4-native mechanics keep behavior auditable

## Color Tokens

- `bg-0`: `#070A0F`
- `bg-1`: `#0B1020`
- `surface`: `rgba(255,255,255,0.04)`
- `border`: `rgba(255,255,255,0.10)`
- `brand-1` (Stealth Mint): `#34F5C5`
- `brand-2` (Aurora Teal): `#16C7FF`
- `brand-3` (Signal Violet): `#8A5CFF`
- `danger`: `#FF4D6D`
- `success`: `#37D67A`
- `warning`: `#FFC857`

Gradient identity: Stealth Aurora (`Mint -> Teal -> Violet`) used for hero glow and primary CTA borders.

## Typography

- Headings: `Space Grotesk`
- Body: `Inter`
- Numeric/state readouts: `JetBrains Mono`

## Component Language

- App shell: sticky top bar + network/wallet status pill.
- Cards: glass panels with soft highlight and 16px radius.
- Primary CTA: dark fill with aurora gradient border and glow-on-hover.
- Inputs: large monospace-friendly fields with inline helper copy.
- Batch timeline: `Collecting -> Clearable -> Cleared -> Settled`.
- Activity rows: status chips, claimable estimate, and explorer tx links.
- Toasts: deterministic, deduplicated event toasts (no spam).

## Accessibility

- Strong focus rings on interactive elements.
- High contrast text on dark surfaces.
- Keyboard-reachable controls and link semantics.
