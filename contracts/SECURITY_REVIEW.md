# SECURITY REVIEW

**NOT PRODUCTION READY. FOR HACKATHON ONLY.**

This document captures the current security assumptions for `StealthBatchHook` batching logic.
Uniswap v4 hooks are powerful and can alter pool behavior at lifecycle boundaries, so implementation and deployment must receive careful manual review.

Docs context:
- Uniswap v4 Hooks Concept: https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 Security (hook security): https://docs.uniswap.org/contracts/v4/concepts/security
- OpenZeppelin Uniswap Hooks overview/base: https://github.com/openzeppelin/uniswap-hooks/blob/master/docs/modules/ROOT/pages/base.adoc

## Invariants

- `totalIn` never decreases.
- Once a window is `cleared`, `totalOut` is fixed.
- Claim is only allowed once per intent.
- `minOut` is enforced at claim time (current implementation), not at queue time.

### Current MVP caveat on `totalIn`

- The current cancel flow (`cancelUncleared`) intentionally decrements `window.totalIn` before clear.
- So the strict invariant above only holds if cancellation is disabled, or is interpreted as:
  `totalIn` is monotonic during queueing and fixed after clear.
- Keep this explicitly documented in tests and reviewer notes to avoid accounting confusion.

## Threat Model

- Reentrancy:
  - Risk: token payout/refund paths and external calls during claim/cancel/sweep.
  - Current control: `ReentrancyGuard` on queue/clear/claim/cancel/sweep.
  - Review focus: payout/refund token transfer ordering and state-first updates.

- DoS via many intents:
  - Risk: griefing by filling a window with tiny intents.
  - Current control: `maxIntentsPerWindow`, `minAmountIn`, one intent per address per window.
  - Review focus: verify no unbounded loops in `clear`; maintain pull-claim model.

- Rounding and dust:
  - Risk: pro-rata floor rounding leaves residual output; incorrect dust accounting may leak or lock value.
  - Current policy: `floor(totalOut * userIn / totalIn)` at claim, track `claimedOutSum`, sweep residual via `sweepDust`.
  - Review focus: ensure `claimedOutSum <= totalOut` always and sweep only after terminal settlement.

- Window boundary mistakes:
  - Risk: off-by-one behavior causing premature clear/cancel or missed claims.
  - Current policy: half-open windows `[start, end)`, clear allowed when `block.number >= windowEndExclusive`.
  - Review focus: `startBlock`, `blocksPerWindow`, and cancel delay semantics under edge blocks.

## Manual Review Checklist

- Validate hook permission flags in `getHookPermissions()` exactly match mined deployment address bits.
- Validate constructor args used for `HookMiner.find(...)` exactly match on-chain deployment args.
- Confirm PoolManager address and allowed `PoolId` are correct for the deployed network/pool.
- Confirm no intent can be claimed twice or both canceled and claimed.
- Confirm minOut failure behavior is expected for UX and does not break settlement guarantees.
- Confirm cancel/refund path cannot enable double-spend once escrow transfers are wired.
- Confirm dust sweep authorization model and final accounting invariants.

