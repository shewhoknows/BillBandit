/**
 * The shared ledger's state machines, named in one place.
 *
 * Each machine is stored in the database as plain columns (booleans,
 * nullable dates, status strings). This file turns those columns into one
 * named state and says which events each state allows. The kernel asks
 * here instead of checking columns one by one.
 *
 * Written down in docs/state-machines/ledger-kernel.md and model-checked in
 * specs/tla/ledger-kernel/ (LedgerKernel.tla, GroupMembership.tla).
 */
import { LedgerMutationError } from './errors'

// ---------------------------------------------------------------------------
// Group lifecycle: Group.isArchived + Group.finalizedAt
//
//   open ──finalize──▶ finalized ──archive──▶ archived
//     └────────────archive─────────────────────▲
//
// There is no way back: no un-finalize and no un-archive endpoint.

export type GroupLifecycleState = 'open' | 'finalized' | 'archived'

export type GroupLifecycleEvent =
  /** expense.create / expense.edit / expense.delete */
  | 'expense.write'
  /** membership, settlement and settings mutations */
  | 'ledger.write'
  | 'finalize'
  | 'archive'

const GROUP_TRANSITIONS: Record<GroupLifecycleState, Partial<Record<GroupLifecycleEvent, GroupLifecycleState>>> = {
  open: { 'expense.write': 'open', 'ledger.write': 'open', finalize: 'finalized', archive: 'archived' },
  finalized: { 'ledger.write': 'finalized', archive: 'archived' },
  archived: {},
}

export function deriveGroupLifecycle(group: {
  isArchived: boolean
  finalizedAt: Date | null
}): GroupLifecycleState {
  if (group.isArchived) return 'archived'
  if (group.finalizedAt) return 'finalized'
  return 'open'
}

/** Throws the existing refusal for an event the group state does not allow. */
export function assertGroupEvent(
  state: GroupLifecycleState,
  event: GroupLifecycleEvent
): GroupLifecycleState {
  const next = GROUP_TRANSITIONS[state][event]
  if (next) return next
  if (state === 'archived') throw new LedgerMutationError('GROUP_ARCHIVED', 403, 'Group is archived')
  throw new LedgerMutationError('GROUP_FINALIZED', 409, 'Group is finalized')
}

// ---------------------------------------------------------------------------
// Expense lifecycle: Expense row + Expense.isDeleted
//
//   absent ──create──▶ active ──delete──▶ deleted
//                       │  ▲
//                       └──┘ edit
//
// A deleted expense is never edited, deleted again or counted in balances.

export type ExpenseState = 'absent' | 'active' | 'deleted'
export type ExpenseEvent = 'create' | 'edit' | 'delete'

const EXPENSE_TRANSITIONS: Record<ExpenseState, Partial<Record<ExpenseEvent, ExpenseState>>> = {
  absent: { create: 'active' },
  active: { edit: 'active', delete: 'deleted' },
  deleted: {},
}

export function deriveExpenseState(
  row: { groupId: string | null; isDeleted: boolean } | null,
  groupId: string
): ExpenseState {
  if (!row || row.groupId !== groupId) return 'absent'
  return row.isDeleted ? 'deleted' : 'active'
}

/** Throws the existing 404 answers for a transition the expense cannot take. */
export function assertExpenseEvent(state: ExpenseState, event: ExpenseEvent): ExpenseState {
  const next = EXPENSE_TRANSITIONS[state][event]
  if (next) return next
  if (event === 'delete' && state === 'deleted') {
    throw new LedgerMutationError('NOT_FOUND', 404, 'Expense is already deleted')
  }
  throw new LedgerMutationError('NOT_FOUND', 404, 'Expense not found')
}

// ---------------------------------------------------------------------------
// Group membership: GroupMember row (role) + GroupParticipant.status/departedAt
//
//   none ──add──▶ active ──remove──▶ departed ──add──▶ active
//
// "active" has a GroupMember row (ADMIN or MEMBER) and an ACTIVE participant.
// "departed" has no GroupMember row and a DEPARTED participant that keeps its
// expenses and payments. Guards:
//   remove: the person's balance is zero in every currency, and the group
//           keeps at least one ADMIN.
//   update: the last ADMIN cannot be made a MEMBER.
//   every other write: a departed person's balance may only move toward zero.

export type MemberState = 'none' | 'active' | 'departed'

export function deriveMemberState(
  member: { role: string } | null,
  participant: { status: string } | null
): MemberState {
  if (member) return 'active'
  if (participant?.status === 'DEPARTED') return 'departed'
  return 'none'
}

export function assertKeepsAnAdmin(input: {
  targetRole: string
  nextRole: 'ADMIN' | 'MEMBER' | null
  adminCount: number
}): void {
  if (input.targetRole === 'ADMIN' && input.nextRole !== 'ADMIN' && input.adminCount <= 1) {
    throw new LedgerMutationError(
      'LAST_ADMIN',
      409,
      'The group needs an owner. Make someone else an owner first, or delete the group.'
    )
  }
}

/** Net balance per participant and currency (positive: the group owes them). */
export type ParticipantBalances = Map<string, Map<string, bigint>>

export type BalanceLedger = {
  participants: Array<{ id: string; userId: string; status: string }>
  expenses: Array<{
    paidByUserId: string
    currency: string
    amountMinorUnits: bigint
    currencyExponent: number
    splits: Array<{ userId: string; amountMinorUnits: bigint }>
  }>
  settlements: Array<{
    payerParticipantId: string
    recipientParticipantId: string
    amount: { currencyCode: string; currencyExponent: number; minorUnits: bigint }
    reversed: boolean
  }>
}

/** The same sums as the read model's buildBalances (deleted and reversed rows skipped by the loader / here). */
export function participantBalances(ledger: BalanceLedger): ParticipantBalances {
  const byUser = new Map(ledger.participants.map((participant) => [participant.userId, participant.id]))
  const balances: ParticipantBalances = new Map()
  const add = (participantId: string | undefined, currency: string, delta: bigint) => {
    if (!participantId) return
    const row = balances.get(participantId) ?? new Map<string, bigint>()
    row.set(currency, (row.get(currency) ?? 0n) + delta)
    balances.set(participantId, row)
  }
  for (const expense of ledger.expenses) {
    const currency = `${expense.currency.toUpperCase()}:${expense.currencyExponent}`
    add(byUser.get(expense.paidByUserId), currency, expense.amountMinorUnits)
    for (const split of expense.splits) add(byUser.get(split.userId), currency, -split.amountMinorUnits)
  }
  for (const settlement of ledger.settlements) {
    if (settlement.reversed) continue
    const currency = `${settlement.amount.currencyCode.toUpperCase()}:${settlement.amount.currencyExponent}`
    add(settlement.payerParticipantId, currency, settlement.amount.minorUnits)
    add(settlement.recipientParticipantId, currency, -settlement.amount.minorUnits)
  }
  return balances
}

/**
 * Checked after a membership.remove, inside the same transaction, so a
 * refusal rolls the removal back: a person must be settled up (zero in every
 * currency) when they leave or are removed.
 *
 * After they left, later writes MAY change their balance (for example an old
 * expense they shared is edited or deleted). Such a debt stays visible, and
 * the departed person or the other side can settle or reverse it
 * (ensureSettlementActor; access matrix "departed with unsettled position").
 */
export function assertLeaverIsSettled(after: BalanceLedger, leavingUserId: string): void {
  const participant = after.participants.find((row) => row.userId === leavingUserId)
  if (!participant) return
  const balances = participantBalances(after).get(participant.id)
  for (const amount of balances?.values() ?? []) {
    if (amount !== 0n) {
      throw new LedgerMutationError(
        'MEMBER_UNSETTLED',
        409,
        "Settle this person's balance in the group before they leave it."
      )
    }
  }
}

/** True when a departed participant still owes or is owed money. */
export function hasUnsettledPosition(ledger: BalanceLedger, participantId: string): boolean {
  for (const amount of participantBalances(ledger).get(participantId)?.values() ?? []) {
    if (amount !== 0n) return true
  }
  return false
}

// ---------------------------------------------------------------------------
// LedgerOperation (idempotency receipt), keyed by (accountId, operationKey)
//
//   absent ──first attempt commits──▶ COMMITTED
//   (PENDING) ── written inside the attempt's own transaction; a rollback
//                removes it, so other requests only ever see absent or
//                COMMITTED (or FAILED, set by group archive for invitations)
//
// Decision for an incoming attempt, in this order:

export type OperationDecision = 'reused-key' | 'replay' | 'failed' | 'execute'

export function decideOperation(
  row: { requestHash: string; groupId: string | null; state: string },
  request: { requestHash: string; groupId: string }
): OperationDecision {
  if (row.requestHash !== request.requestHash || row.groupId !== request.groupId) return 'reused-key'
  if (row.state === 'COMMITTED') return 'replay'
  if (row.state === 'FAILED') return 'failed'
  return 'execute'
}

/**
 * Two attempts with the same key at the same time: Prisma's upsert reads,
 * then inserts, so the second insert fails with P2002 once the first commits.
 * The kernel retries the whole transaction; the retry replays the receipt.
 */
export class OperationKeyRaceError extends Error {
  constructor() {
    super('Another attempt with the same operation key committed first')
    this.name = 'OperationKeyRaceError'
  }
}

export function isOperationKeyUniqueViolation(error: unknown): boolean {
  if (!error || typeof error !== 'object') return false
  const value = error as { code?: unknown; meta?: { modelName?: unknown; target?: unknown } }
  if (value.code !== 'P2002') return false
  if (value.meta?.modelName === 'LedgerOperation') return true
  const target = value.meta?.target
  return Array.isArray(target) ? target.includes('operationKey') : String(target ?? '').includes('operationKey')
}
