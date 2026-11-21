/**
 * The settle-up state machines, named in one place.
 * Full tables, guards and TLA+ models: docs/state-machines/settlement.md,
 * specs/tla/settlement/.
 */

// ---------------------------------------------------------------------------
// SettlementOutbox row
//
//   PENDING --lease--> LEASED --published--> PUBLISHED   (final)
//                        |  \--publish failed--> PENDING (backoff)
//                        \--lease expired, reclaimed--> PENDING
//
// FAILED exists in the enum but nothing writes it: rows retry for ever.
// Only the worker that holds the current lease token may move a LEASED row.
// A worker whose lease expired and was taken over must not write: before
// this rule a slow, failing worker could move a PUBLISHED row back to
// PENDING and the event was sent again.
// ---------------------------------------------------------------------------

export type OutboxState = 'PENDING' | 'LEASED' | 'PUBLISHED' | 'FAILED'
export type OutboxEvent = 'lease' | 'published' | 'publishFailed' | 'reclaimExpired'

const outboxTransitions: Record<OutboxEvent, { from: OutboxState; to: OutboxState }> = {
  lease: { from: 'PENDING', to: 'LEASED' },
  published: { from: 'LEASED', to: 'PUBLISHED' },
  publishFailed: { from: 'LEASED', to: 'PENDING' },
  reclaimExpired: { from: 'LEASED', to: 'PENDING' },
}

export function outboxTransition(event: OutboxEvent): { from: OutboxState; to: OutboxState } {
  return outboxTransitions[event]
}

/** Unique per lease, so a stale worker can be told apart from the holder. */
export function outboxLeaseToken(owner: string, nonce: string): string {
  return `${owner}:${nonce}`
}

// ---------------------------------------------------------------------------
// Group settle-up completion (Group.hadOpenTransfers, settlementCompletedAt)
//
//   OPEN       plan has transfers        hadOpen = true,  completedAt = null
//   SETTLED    plan empty                hadOpen = false, completedAt = time of
//                                        the latest settle/reverse journal row
//   (no settle/reverse yet and plan empty: hadOpen = false, completedAt kept)
//
// Recomputed after every settle/reverse request, with the group row locked so
// two requests cannot write their results out of order. It is derived from
// the ledger and the journal, not from the previous flags, so a replayed
// request, a later expense, or a missed update (crash) cannot leave an old
// date behind once the next settle/reverse request runs.
// ---------------------------------------------------------------------------

export type CompletionFlags = { hadOpenTransfers: boolean; settlementCompletedAt: Date | null }

export function deriveCompletionFlags(input: {
  planIsEmpty: boolean
  latestSettleEventAt: Date | null
  current: CompletionFlags
  now: Date
}): CompletionFlags {
  if (!input.planIsEmpty) return { hadOpenTransfers: true, settlementCompletedAt: null }
  return {
    hadOpenTransfers: false,
    // Groups imported before the journal existed have no row: keep the old rule.
    settlementCompletedAt:
      input.latestSettleEventAt ?? input.current.settlementCompletedAt ?? input.now,
  }
}

/** Journal event types that count as a settle-up action. */
export const SETTLE_EVENT_TYPES = ['settlement_created', 'settlement_reversed'] as const

// ---------------------------------------------------------------------------
// Payment (Transaction + SettlementAllocation [+ SettlementReversal])
//
//   (none) --settle--> RECORDED --reverse--> REVERSED   (final)
//
// Guards live in lib/ledger/mutation/kernel.ts (prepareSettlement,
// prepareReversal) and in the database (SettlementReversal.transactionId is
// unique). A reversal is not a payment, so it cannot be reversed
// (SETTLEMENT_NOT_FOUND). Reversal is allowed in a finalized group
// (docs/api-contracts.md: finalized groups still accept settlements).
// ---------------------------------------------------------------------------
