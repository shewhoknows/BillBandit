import type { Prisma } from '@prisma/client'

export type MutationKind =
  | 'expense.create'
  | 'expense.edit'
  | 'expense.update'
  | 'expense.delete'
  | 'membership.add'
  | 'membership.remove'
  | 'membership.update'
  | 'membership.change'
  | 'settlement.create'
  | 'settlement.settle'
  | 'settlement.reverse'
  | 'reversal.create'
  | 'settings.update'
  | 'setting.update'

export type ExactMoneyInput = {
  minorUnits: string | bigint
  currencyCode: string
  currencyExponent: number
}

export type ExpenseSplitMutationInput = {
  id?: string
  splitId?: string
  userId: string
  amount: ExactMoneyInput
  percentage?: number | null
  shares?: number | null
  isPaid?: boolean
}

export type ExpenseMutationInput = {
  expenseId?: string
  id?: string
  description?: string
  amount?: ExactMoneyInput
  currency?: string
  date?: string | Date
  category?: string
  paidById?: string
  groupId?: string
  splitType?: 'EQUAL' | 'EXACT' | 'PERCENTAGE' | 'SHARES'
  splits?: readonly ExpenseSplitMutationInput[]
  receiptUrl?: string | null
  notes?: string | null
  isRecurring?: boolean
  recurringInterval?: 'DAILY' | 'WEEKLY' | 'MONTHLY' | 'YEARLY' | null
  recurringEndDate?: string | Date | null
}

export type MembershipMutationInput = {
  memberId?: string
  membershipId?: string
  userId?: string
  role?: 'ADMIN' | 'MEMBER'
  displayName?: string
}

export type SettlementMutationInput = {
  settlementId?: string
  transactionId?: string
  planTransferId?: string
  payerParticipantId: string
  recipientParticipantId: string
  amount?: ExactMoneyInput
  money?: ExactMoneyInput
  minorUnits?: string | bigint
  currencyCode?: string
  currencyExponent?: number
  mode?: 'DIRECT' | 'SIMPLIFIED'
  note?: string | null
}

export type ReversalMutationInput = {
  settlementId: string
  reversalId?: string
}

export type SettingsMutationInput = {
  simplifyDebts: boolean
}

export type MutationPayload =
  | ExpenseMutationInput
  | MembershipMutationInput
  | SettlementMutationInput
  | ReversalMutationInput
  | SettingsMutationInput

/**
 * The operation identity is deliberately separate from the mutation body.
 * Expected revision is transport/concurrency metadata and is not part of the
 * request hash, so a stale operation can be retried with a refreshed revision
 * when its first attempt never committed.
 */
export type LedgerMutationRequest = {
  groupId: string
  operationId: string
  kind?: MutationKind | string
  mutationType?: MutationKind | string
  payload?: MutationPayload
  body?: MutationPayload
  input?: MutationPayload
  expectedRevision?: number
  expectedGroupRevision?: number
  expectedVersion?: number
  accountId?: string
  actorId?: string
  actorUserId?: string
  userId?: string
}

export type MutationResult = {
  recordId: string
  eventType: string
  metadata?: Record<string, unknown>
}

export type MutationOutcome = 'applied' | 'replayed'

export type MutationReceipt = {
  key: string
  requestHash: string
  replayed: boolean
  resultRevision: number
  retainedUntil: string
}

export type LedgerMutationResult = {
  groupId: string
  operationId: string
  outcome: MutationOutcome
  replayed: boolean
  revision: number
  readRevision: number
  currentRevision: number
  requestHash: string
  recordId: string
  eventType: string
  result: MutationResult
  idempotency: MutationReceipt
  authority: {
    serverAuthoritative: true
    moneyAuthority: 'minor_units'
    revisionAuthority: 'group'
  }
  noop?: boolean
}

export type MutationReadModelHint = {
  kind: 'shared-ledger'
  groupId: string
  revision: number
  readRevision: number
  simplifyDebts: boolean | null
  isArchived: boolean | null
  finalizedAt: string | null
}

export type MutationConflictDetails = {
  groupId: string
  operationId?: string
  expectedRevision?: number | null
  currentRevision: number
  currentVersion: number
  retryable: boolean
  serverAuthoritative: true
  readModel: MutationReadModelHint
  currentReadModel: MutationReadModelHint
  expectedRequestHash?: string
  existingRequestHash?: string
}

export type MutationTransaction = Prisma.TransactionClient

export type PreparedMutation =
  | {
      kind: 'expense.create' | 'expense.edit' | 'expense.delete'
      recordId: string
      eventType: 'expense_created' | 'expense_updated' | 'expense_deleted'
      data: Record<string, unknown>
      splits?: Record<string, unknown>[]
      existingExpenseId?: string
    }
  | {
      kind: 'membership.add' | 'membership.remove' | 'membership.update'
      recordId: string
      eventType: 'membership_changed'
      data: Record<string, unknown>
      participantUserId: string
      participantDisplayName?: string
    }
  | {
      kind: 'settlement.create'
      recordId: string
      eventType: 'settlement_created'
      transactionData: Record<string, unknown>
      allocationData: Record<string, unknown>
      allocationId: string
    }
  | {
      kind: 'settlement.reverse'
      recordId: string
      eventType: 'settlement_reversed'
      data: Record<string, unknown>
    }
  | {
      kind: 'settings.update'
      recordId: string
      eventType: 'setting_changed'
      data: Record<string, unknown>
      noop?: false
    }
  | {
      kind: 'settings.update'
      recordId: ''
      eventType: 'setting_noop'
      data: Record<string, unknown>
      noop: true
    }
