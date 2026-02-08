# Backend Decisions

<!--
Docs references:
- Uniswap v4 Hooks concept (pool-specific hooks): https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 PoolManager lifecycle overview: https://docs.uniswap.org/contracts/v4/overview
- Uniswap v4 AsyncSwap/custom accounting context: https://docs.uniswap.org/contracts/v4/quickstart/hooks/async-swap
- Hook data usage example (`hookData` encoding/decoding): https://docs.uniswap.org/contracts/v4/guides/hooks/your-first-hook
-->

## Why we don't need Postgres for MVP

- All required UI state can be reconstructed from onchain events:
  - `IntentQueued`
  - `WindowCleared`
  - `Claimed`
- The executor already treats chain state as source-of-truth and uses contract reads to confirm idempotent `clear(windowId)` behavior.
- A database is optional for MVP and mainly acts as a cache/index for faster queries.
- If local caching is useful during demos, SQLite is enough and keeps ops simple.
- For production scale, move to Postgres plus proper indexing/backfill pipelines (e.g. block-range ingestion, reorg-safe reconciliation, and materialized views).
- Hook data standards are still an ecosystem-level convention topic; for MVP, keep indexing centered on canonical emitted events and only add richer `hookData` indexing when needed.

