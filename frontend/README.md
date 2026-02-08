# Frontend

This Astro frontend uses Vue components through the `@astrojs/vue` integration (configured in `astro.config.mjs` via `integrations: [vue()]`).

When wiring wallet clients with viem in browser code, import `viem/window` to type `window.ethereum`.

Design system + brand guide: `frontend/brand/README.md`.

## Local env

Create `frontend/.env` with:

```bash
PUBLIC_VEIL_BATCH_HOOK_ADDRESS=0x...
PUBLIC_EXECUTOR_ADDRESS=0x...
PUBLIC_DEPLOYMENT_BLOCK=12345678
```

Docs references:
- Uniswap v4 hooks: https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 AsyncSwap: https://docs.uniswap.org/contracts/v4/quickstart/hooks/async-swap
- OpenZeppelin Uniswap Hooks base contracts: not used in frontend setup.
