export const LEDGER_CONTRACT_NAME = 'ledger-contract'
export const LEDGER_CONTRACT_VERSION = 2 as const
export const LEDGER_CLIENT_CONTRACT = 'ledger-v2' as const

export type LedgerContractVersion = typeof LEDGER_CONTRACT_VERSION
export type LedgerClientContract = typeof LEDGER_CLIENT_CONTRACT

/**
 * Money is deliberately JSON-safe. `minorUnits` is never a JSON number and
 * is never represented as a floating-point major-unit amount.
 */
export type Money = {
  minorUnits: string
  currencyCode: string
  currencyExponent: number
}

export type CurrencyDescriptor = Pick<Money, 'currencyCode' | 'currencyExponent'>

export type SharedGroupScope = {
  kind: 'shared'
  accountId: string
  groupId: string
  localOnly: false
}

export type AuthorityMarkers = {
  serverAuthoritative: true
  source: 'server'
  readModel: 'server'
  ledger: 'server'
  balances: 'server'
  settlementPlan: 'server'
  settlementHistory: 'server'
  identity: 'server'
  cacheRole: 'offline-cache'
}

export type MigrationState = {
  status: 'not_required' | 'pending' | 'in_progress' | 'complete' | 'blocked'
  source: 'none' | 'cloudkit'
  migrationId: string | null
  importedAt: string | null
  dualWriteEnabled: false
  recoveryReadOnly: boolean
}

export type StaleState = {
  isStale: boolean
  reason: 'none' | 'offline' | 'revision_gap' | 'server_unavailable' | 'conflict'
  observedAt: string
  readRevision: number
  serverRevision: number | null
}

export type PendingOperation = {
  operationId: string
  idempotencyKey: string
  kind: string
  expectedRevision: number
  status: 'queued' | 'in_flight' | 'failed' | 'applied' | 'conflicted'
  createdAt: string
  requestHash: string
}

export type LedgerMemberIdentity = {
  memberId: string
  accountId: string
  localIdentityId: string | null
  displayName: string
  email: string | null
  role: 'owner' | 'member'
  status: 'active' | 'departed'
}

export type SplitMethod = 'EQUAL' | 'EXACT' | 'PERCENTAGE' | 'SHARES'

export type LedgerExpenseSplit = {
  splitId: string
  memberId: string
  amount: Money
  percentage: string | null
  shares: number | null
}

export type LedgerExpense = {
  expenseId: string
  description: string
  paidByMemberId: string
  amount: Money
  splitMethod: SplitMethod
  splits: LedgerExpenseSplit[]
  status: 'active' | 'voided'
  createdAt: string
  updatedAt: string
}

export type MemberBalanceSurface = {
  memberId: string
  byCurrency: Money[]
}

export type CurrencyBalanceSurface = {
  currency: CurrencyDescriptor
  totalPositive: Money
  totalNegative: Money
  net: Money
}

export type GroupBalanceSurface = {
  byMember: MemberBalanceSurface[]
  byCurrency: CurrencyBalanceSurface[]
  currentAccount: {
    accountId: string
    memberId: string
    byCurrency: Money[]
  }
}

export type AccountBalanceSurface = {
  accountId: string
  memberId: string
  byCurrency: Money[]
}

export type SettlementTransfer = {
  planTransferId: string
  payerMemberId: string
  recipientMemberId: string
  amount: Money
  mode: 'DIRECT' | 'SIMPLIFIED'
  obligationComponentIds: string[]
}

export type SettlementPlan = {
  revision: number
  mode: 'DIRECT' | 'SIMPLIFIED'
  transfers: SettlementTransfer[]
}

export type SettlementHistoryItem =
  | {
      type: 'settlement'
      settlementId: string
      payerMemberId: string
      recipientMemberId: string
      amount: Money
      status: 'active' | 'reversed'
      reversalId: string | null
      actorMemberId: string
      createdAt: string
    }
  | {
      type: 'reversal'
      reversalId: string
      settlementId: string
      amount: Money
      actorMemberId: string
      createdAt: string
    }

export type LedgerActivityItem =
  | {
      activityId: string
      type: 'expense'
      expenseId: string
      amount: Money
      at: string
    }
  | {
      activityId: string
      type: 'settlement'
      settlementId: string
      amount: Money
      at: string
    }
  | {
      activityId: string
      type: 'reversal'
      reversalId: string
      settlementId: string
      amount: Money
      at: string
    }

export type AccountGroupSummary = {
  groupId: string
  name: string
  baseCurrency: CurrencyDescriptor
  revision: number
  localOnly: false
  balanceByCurrency: Money[]
}

export type AccountLedgerReadModel = {
  accountId: string
  currentMemberId: string
  readRevision: number
  sharedGroups: AccountGroupSummary[]
  balance: AccountBalanceSurface
  pendingOperations: PendingOperation[]
  migration: MigrationState
  stale: StaleState
  authority: AuthorityMarkers
}

export type GroupLedgerReadModel = {
  groupId: string
  accountId: string
  name: string
  baseCurrency: CurrencyDescriptor
  scope: 'shared'
  localOnly: false
  revision: number
  readRevision: number
  members: LedgerMemberIdentity[]
  expenses: LedgerExpense[]
  balances: GroupBalanceSurface
  settlementPlan: SettlementPlan
  settlementHistory: SettlementHistoryItem[]
  activity: LedgerActivityItem[]
  pendingOperationIds: string[]
  migration: MigrationState
  stale: StaleState
  authority: AuthorityMarkers
}

export type LedgerReadData = {
  account: AccountLedgerReadModel
  group: GroupLedgerReadModel
}

export type LedgerReadEnvelope<T> = {
  contractVersion: LedgerContractVersion
  kind: 'read'
  scope: SharedGroupScope
  revision: number
  readRevision: number
  pendingOperationIds: string[]
  migration: MigrationState
  stale: StaleState
  authority: AuthorityMarkers
  data: T
}

export const LEDGER_HEADERS = {
  idempotencyKey: 'Idempotency-Key',
  expectedRevision: 'Expected-Revision',
  clientContract: 'Client-Contract',
  compatibility: 'Client-Compatibility',
} as const

export type LedgerMutationHeaders = {
  'Idempotency-Key': string
  'Expected-Revision': string
  'Client-Contract': LedgerClientContract
  'Client-Compatibility': LedgerClientContract
}

export type ExpenseCreateMutationBody = {
  kind: 'expense.create'
  expenseId: string
  paidByMemberId: string
  description: string
  amount: Money
  splitMethod: SplitMethod
  splits: LedgerExpenseSplit[]
}

export type LedgerMutationRequest<T> = {
  contractVersion: LedgerContractVersion
  kind: 'mutation_request'
  groupId: string
  operationId: string
  headers: LedgerMutationHeaders
  body: T
}

export type IdempotencyReceipt = {
  key: string
  requestHash: string
  replayed: boolean
  resultRevision: number
  retainedUntil: string
}

export type MutationResult = {
  recordId: string
  eventType: string
}

export type LedgerMutationResultEnvelope = {
  contractVersion: LedgerContractVersion
  kind: 'mutation_result'
  groupId: string
  operationId: string
  outcome: 'applied' | 'replayed'
  revision: number
  readRevision: number
  idempotency: IdempotencyReceipt
  result: MutationResult
  authority: AuthorityMarkers
}

export type LedgerConflictCode =
  | 'REVISION_CONFLICT'
  | 'IDEMPOTENCY_KEY_REUSED'
  | 'CLIENT_CONTRACT_UNSUPPORTED'

export type LedgerConflictEnvelope = {
  contractVersion: LedgerContractVersion
  kind: 'conflict'
  groupId: string
  operationId: string
  revision: number
  readRevision: number
  conflict: {
    code: LedgerConflictCode
    expectedRevision: number | null
    currentRevision: number
    retryable: boolean
    message: string
    serverAuthoritative: true
  }
  idempotency: {
    key: string
    requestHash: string
  }
  snapshot: LedgerReadEnvelope<LedgerReadData> | null
  authority: AuthorityMarkers
}

export type SharedLedgerFixture = {
  fixtureId: string
  contractVersion: LedgerContractVersion
  kind: 'shared_ledger_fixture'
  read: LedgerReadEnvelope<LedgerReadData>
  excludedLocalOnlyGroupIds: string[]
}

export type MutationFixture = {
  fixtureId: string
  contractVersion: LedgerContractVersion
  kind: 'mutation_fixture'
  request: LedgerMutationRequest<ExpenseCreateMutationBody>
  applied: LedgerMutationResultEnvelope
  replayed: LedgerMutationResultEnvelope
  revisionConflict: LedgerConflictEnvelope
  idempotencyConflict: LedgerConflictEnvelope
}
