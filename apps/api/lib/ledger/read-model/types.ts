import type {
  AccountGroupSummary,
  AccountLedgerReadModel,
  AuthorityMarkers,
  CurrencyDescriptor,
  GroupLedgerReadModel,
  LedgerActivityItem,
  LedgerExpense,
  LedgerExpenseSplit,
  LedgerMemberIdentity,
  LedgerReadData,
  LedgerReadEnvelope,
  MigrationState,
  Money,
  PendingOperation,
  SettlementHistoryItem,
  StaleState,
} from '../../ledger-contract'

export type ReadModelMemberSource = LedgerMemberIdentity

export type ReadModelExpenseSource = LedgerExpense

export type ReadModelSettlementPathSource = {
  payerMemberId: string
  recipientMemberId: string
  amount: Money
  obligationComponentIds: string[]
}

export type ReadModelSettlementSource = {
  settlementId: string
  payerMemberId: string
  recipientMemberId: string
  amount: Money
  actorMemberId: string
  createdAt: string
  reversed: boolean
  reversal: {
    reversalId: string
    actorMemberId: string
    createdAt: string
  } | null
  allocationPaths: ReadModelSettlementPathSource[]
}

export type ReadModelGroupSource = {
  groupId: string
  accountId: string
  name: string
  baseCurrency: CurrencyDescriptor
  revision: number
  simplifyDebts: boolean
  localOnly: false
  members: ReadModelMemberSource[]
  expenses: ReadModelExpenseSource[]
  settlements: ReadModelSettlementSource[]
  pendingOperationIds: string[]
  migration: MigrationState
  migrationIssueIds?: string[]
  updatedAt?: string
}

export type ReadModelFriendSource = {
  friendId: string
  accountId: string
  displayName: string
  email: string | null
  createdAt: string
  status: 'accepted'
}

export type ReadModelAccountSource = {
  accountId: string
  groups: ReadModelGroupSource[]
  friends?: ReadModelFriendSource[]
  pendingOperations: PendingOperation[]
  migration?: MigrationState
}

export type ReadModelBuildOptions = {
  observedAt?: Date | string
}

export type LedgerReadOnlyGroupSummary = AccountGroupSummary & {
  readOnly: boolean
  migration: MigrationState
}

export type LedgerFriend = ReadModelFriendSource & {
  sharedGroupIds: string[]
  groupBalances: Array<{
    groupId: string
    memberId: string
    byCurrency: Money[]
  }>
}

export type AccountActivityItem = LedgerActivityItem & {
  groupId: string
  groupName: string
}

export type AccountLedgerSummary = {
  contractVersion: 2
  kind: 'account_read'
  accountId: string
  readRevision: number
  groups: LedgerReadOnlyGroupSummary[]
  balanceByCurrency: Money[]
  friends: LedgerFriend[]
  activity: AccountActivityItem[]
  pendingOperations: PendingOperation[]
  pendingOperationIds: string[]
  migration: MigrationState
  stale: StaleState
  authority: AuthorityMarkers
  readOnly: boolean
}

export type GroupLedgerReadEnvelope = LedgerReadEnvelope<LedgerReadData>

export type GroupLedgerProjection = {
  model: GroupLedgerReadModel
  readOnly: boolean
}

export type LedgerReadProjection = {
  account: AccountLedgerReadModel
  group: GroupLedgerReadModel
  envelope: GroupLedgerReadEnvelope
}

export type AccountProjectionResult = {
  summary: AccountLedgerSummary
  groups: GroupLedgerProjection[]
}

export type LedgerReadModelErrorCode =
  | 'GROUP_NOT_FOUND'
  | 'MONEY_REPRESENTATION_UNAVAILABLE'
  | 'INVALID_LEDGER_RECORD'
  | 'UNSUPPORTED_CURRENCY'

export class LedgerReadModelError extends Error {
  constructor(
    public readonly code: LedgerReadModelErrorCode,
    message: string,
    public readonly details: Record<string, unknown> = {}
  ) {
    super(message)
    this.name = 'LedgerReadModelError'
  }
}

export type RawReadModelUser = {
  id: string
  name: string | null
  preferredName?: string | null
  email: string | null
  externalIdentities?: Array<{
    id: string
    provider: string
    subject: string
    metadata: unknown
  }>
}

export type RawReadModelGroupMember = {
  id: string
  userId: string
  role: string
  user: RawReadModelUser
}

export type RawReadModelParticipant = {
  id: string
  userId: string
  displayName: string
  status: string
  user: RawReadModelUser
}

export type RawReadModelExpenseSplit = {
  id: string
  userId: string
  amountMinorUnits: bigint | null
  currencyExponent: number | null
  percentage: number | null
  shares: number | null
}

export type RawReadModelExpense = {
  id: string
  description: string
  paidById: string
  currency: string
  amountMinorUnits: bigint | null
  currencyExponent: number | null
  splitType: string
  date: Date
  createdAt: Date
  updatedAt: Date
  isDeleted: boolean
  splits: RawReadModelExpenseSplit[]
}

export type RawReadModelAllocationPath = {
  payerParticipantId: string
  recipientParticipantId: string
  flowMinorUnits: bigint
  obligationComponentKey: string
}

export type RawReadModelTransaction = {
  id: string
  senderId: string
  receiverId: string
  currency: string
  amountMinorUnits: bigint | null
  currencyExponent: number | null
  payerParticipantId: string | null
  recipientParticipantId: string | null
  actorUserId: string | null
  createdAt: Date
  allocation: {
    paths: RawReadModelAllocationPath[]
  } | null
  reversal: {
    id: string
    actorUserId: string | null
    createdAt: Date
  } | null
}

export type RawReadModelGroup = {
  id: string
  name: string
  currency: string
  simplifyDebts: boolean
  settlementVersion: number
  updatedAt: Date
  members: RawReadModelGroupMember[]
  participants: RawReadModelParticipant[]
  expenses: RawReadModelExpense[]
  transactions: RawReadModelTransaction[]
}

export type RawReadModelFriendship = {
  id: string
  fromId: string
  toId: string
  createdAt: Date
  from: RawReadModelUser
  to: RawReadModelUser
}
