import { parseMoney, moneyEquals, addMoney, compareMoney } from './money'
import {
  LEDGER_CLIENT_CONTRACT,
  LEDGER_CONTRACT_VERSION,
  type AccountBalanceSurface,
  type AccountGroupSummary,
  type AccountLedgerReadModel,
  type AuthorityMarkers,
  type CurrencyBalanceSurface,
  type CurrencyDescriptor,
  type ExpenseCreateMutationBody,
  type GroupBalanceSurface,
  type GroupLedgerReadModel,
  type IdempotencyReceipt,
  type LedgerActivityItem,
  type LedgerConflictEnvelope,
  type LedgerExpense,
  type LedgerExpenseSplit,
  type LedgerMemberIdentity,
  type LedgerMutationHeaders,
  type LedgerMutationRequest,
  type LedgerMutationResultEnvelope,
  type LedgerReadData,
  type LedgerReadEnvelope,
  type LedgerActivityItem as ActivityItem,
  type MemberBalanceSurface,
  type MigrationState,
  type MutationFixture,
  type PendingOperation,
  type SettlementHistoryItem,
  type SettlementPlan,
  type SettlementTransfer,
  type SharedGroupScope,
  type SharedLedgerFixture,
  type SplitMethod,
  type StaleState,
} from './types'
import type { Money } from './types'

export class LedgerContractValidationError extends Error {
  constructor(
    public readonly path: string,
    message: string
  ) {
    super(`${path}: ${message}`)
    this.name = 'LedgerContractValidationError'
  }
}

type RecordValue = Record<string, unknown>

function fail(path: string, message: string): never {
  throw new LedgerContractValidationError(path, message)
}

function record(value: unknown, path: string): RecordValue {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    return fail(path, 'expected an object')
  }
  return value as RecordValue
}

function required(value: RecordValue, key: string, path: string): unknown {
  if (!(key in value)) return fail(`${path}.${key}`, 'is required')
  return value[key]
}

function stringValue(value: unknown, path: string): string {
  if (typeof value !== 'string' || value.length === 0 || /\s/.test(value)) {
    return fail(path, 'must be a non-empty string without whitespace')
  }
  return value
}

function textValue(value: unknown, path: string): string {
  if (typeof value !== 'string' || value.length === 0) return fail(path, 'must be a non-empty string')
  return value
}

function nullableText(value: unknown, path: string): string | null {
  if (value === null) return null
  return textValue(value, path)
}

function integerValue(value: unknown, path: string, minimum = 0): number {
  if (typeof value !== 'number' || !Number.isInteger(value) || value < minimum) {
    return fail(path, `must be an integer greater than or equal to ${minimum}`)
  }
  return value
}

function booleanValue(value: unknown, path: string): boolean {
  if (typeof value !== 'boolean') return fail(path, 'must be a boolean')
  return value
}

function literal<T extends string | number | boolean>(value: unknown, expected: T, path: string): T {
  if (value !== expected) return fail(path, `must equal ${String(expected)}`)
  return expected
}

function arrayValue(value: unknown, path: string): unknown[] {
  if (!Array.isArray(value)) return fail(path, 'must be an array')
  return value
}

function idList(value: unknown, path: string): string[] {
  const values = arrayValue(value, path).map((entry, index) => stringValue(entry, `${path}[${index}]`))
  if (new Set(values).size !== values.length) return fail(path, 'must not contain duplicate IDs')
  return values
}

function isoDate(value: unknown, path: string): string {
  const result = textValue(value, path)
  if (!result.endsWith('Z') || Number.isNaN(Date.parse(result))) {
    return fail(path, 'must be an ISO-8601 UTC timestamp')
  }
  return result
}

function hashValue(value: unknown, path: string): string {
  const result = stringValue(value, path)
  if (!/^[a-f0-9]{64}$/.test(result)) return fail(path, 'must be a lowercase SHA-256 hex digest')
  return result
}

function moneyValue(value: unknown, path: string): Money {
  try {
    return parseMoney(value)
  } catch (error) {
    const message = error instanceof Error ? error.message : 'invalid money'
    return fail(path, message)
  }
}

function currencyDescriptor(value: unknown, path: string): CurrencyDescriptor {
  const money = moneyValue(
    { minorUnits: '0', ...(record(value, path) as RecordValue) },
    path
  )
  return { currencyCode: money.currencyCode, currencyExponent: money.currencyExponent }
}

function authorityValue(value: unknown, path: string): AuthorityMarkers {
  const object = record(value, path)
  literal(object.serverAuthoritative, true, `${path}.serverAuthoritative`)
  literal(object.source, 'server', `${path}.source`)
  literal(object.readModel, 'server', `${path}.readModel`)
  literal(object.ledger, 'server', `${path}.ledger`)
  literal(object.balances, 'server', `${path}.balances`)
  literal(object.settlementPlan, 'server', `${path}.settlementPlan`)
  literal(object.settlementHistory, 'server', `${path}.settlementHistory`)
  literal(object.identity, 'server', `${path}.identity`)
  literal(object.cacheRole, 'offline-cache', `${path}.cacheRole`)
  return object as unknown as AuthorityMarkers
}

function migrationValue(value: unknown, path: string): MigrationState {
  const object = record(value, path)
  const status = required(object, 'status', path)
  if (!['not_required', 'pending', 'in_progress', 'complete', 'blocked'].includes(String(status))) {
    return fail(`${path}.status`, 'contains an unknown migration status')
  }
  const source = required(object, 'source', path)
  if (source !== 'none' && source !== 'cloudkit') return fail(`${path}.source`, 'contains an unknown source')
  const migrationId = object.migrationId === null ? null : stringValue(object.migrationId, `${path}.migrationId`)
  const importedAt = object.importedAt === null ? null : isoDate(object.importedAt, `${path}.importedAt`)
  literal(object.dualWriteEnabled, false, `${path}.dualWriteEnabled`)
  return {
    status: status as MigrationState['status'],
    source: source as MigrationState['source'],
    migrationId,
    importedAt,
    dualWriteEnabled: false,
    recoveryReadOnly: booleanValue(required(object, 'recoveryReadOnly', path), `${path}.recoveryReadOnly`),
  }
}

function staleValue(value: unknown, path: string): StaleState {
  const object = record(value, path)
  const reason = required(object, 'reason', path)
  if (!['none', 'offline', 'revision_gap', 'server_unavailable', 'conflict'].includes(String(reason))) {
    return fail(`${path}.reason`, 'contains an unknown stale reason')
  }
  const serverRevision = object.serverRevision === null ? null : integerValue(object.serverRevision, `${path}.serverRevision`)
  return {
    isStale: booleanValue(required(object, 'isStale', path), `${path}.isStale`),
    reason: reason as StaleState['reason'],
    observedAt: isoDate(required(object, 'observedAt', path), `${path}.observedAt`),
    readRevision: integerValue(required(object, 'readRevision', path), `${path}.readRevision`),
    serverRevision,
  }
}

function pendingOperation(value: unknown, path: string): PendingOperation {
  const object = record(value, path)
  const status = required(object, 'status', path)
  if (!['queued', 'in_flight', 'failed', 'applied', 'conflicted'].includes(String(status))) {
    return fail(`${path}.status`, 'contains an unknown operation status')
  }
  return {
    operationId: stringValue(required(object, 'operationId', path), `${path}.operationId`),
    idempotencyKey: stringValue(required(object, 'idempotencyKey', path), `${path}.idempotencyKey`),
    kind: stringValue(required(object, 'kind', path), `${path}.kind`),
    expectedRevision: integerValue(required(object, 'expectedRevision', path), `${path}.expectedRevision`),
    status: status as PendingOperation['status'],
    createdAt: isoDate(required(object, 'createdAt', path), `${path}.createdAt`),
    requestHash: hashValue(required(object, 'requestHash', path), `${path}.requestHash`),
  }
}

function memberIdentity(value: unknown, path: string): LedgerMemberIdentity {
  const object = record(value, path)
  const role = required(object, 'role', path)
  const status = required(object, 'status', path)
  if (role !== 'owner' && role !== 'member') return fail(`${path}.role`, 'must be owner or member')
  if (status !== 'active' && status !== 'departed') return fail(`${path}.status`, 'must be active or departed')
  return {
    memberId: stringValue(required(object, 'memberId', path), `${path}.memberId`),
    accountId: stringValue(required(object, 'accountId', path), `${path}.accountId`),
    localIdentityId: nullableText(required(object, 'localIdentityId', path), `${path}.localIdentityId`),
    displayName: textValue(required(object, 'displayName', path), `${path}.displayName`),
    email: nullableText(required(object, 'email', path), `${path}.email`),
    role: role as LedgerMemberIdentity['role'],
    status: status as LedgerMemberIdentity['status'],
  }
}

function splitMethod(value: unknown, path: string): SplitMethod {
  if (value !== 'EQUAL' && value !== 'EXACT' && value !== 'PERCENTAGE' && value !== 'SHARES') {
    return fail(path, 'must be EQUAL, EXACT, PERCENTAGE, or SHARES')
  }
  return value
}

function percentageValue(value: unknown, path: string): string | null {
  if (value === null) return null
  if (typeof value !== 'string' || !/^\d+(?:\.\d+)?$/.test(value)) {
    return fail(path, 'must be a decimal string when present')
  }
  return value
}

function ledgerExpenseSplit(value: unknown, path: string): LedgerExpenseSplit {
  const object = record(value, path)
  const shares = object.shares === null ? null : integerValue(object.shares, `${path}.shares`)
  return {
    splitId: stringValue(required(object, 'splitId', path), `${path}.splitId`),
    memberId: stringValue(required(object, 'memberId', path), `${path}.memberId`),
    amount: moneyValue(required(object, 'amount', path), `${path}.amount`),
    percentage: percentageValue(required(object, 'percentage', path), `${path}.percentage`),
    shares,
  }
}

function sumMoney(values: readonly Money[], path: string): Money {
  if (values.length === 0) return fail(path, 'must contain at least one money value')
  let total = values[0]
  for (const value of values.slice(1)) {
    try {
      total = addMoney(total, value)
    } catch (error) {
      const message = error instanceof Error ? error.message : 'mixed currencies cannot be added'
      return fail(path, message)
    }
  }
  return total
}

function ledgerExpense(value: unknown, path: string): LedgerExpense {
  const object = record(value, path)
  const status = required(object, 'status', path)
  if (status !== 'active' && status !== 'voided') return fail(`${path}.status`, 'must be active or voided')
  const splits = arrayValue(required(object, 'splits', path), `${path}.splits`).map((entry, index) =>
    ledgerExpenseSplit(entry, `${path}.splits[${index}]`)
  )
  const amount = moneyValue(required(object, 'amount', path), `${path}.amount`)
  const splitTotal = sumMoney(splits.map((split) => split.amount), `${path}.splits`)
  if (!moneyEquals(amount, splitTotal)) return fail(`${path}.splits`, 'split amounts must equal expense amount exactly')
  return {
    expenseId: stringValue(required(object, 'expenseId', path), `${path}.expenseId`),
    description: textValue(required(object, 'description', path), `${path}.description`),
    paidByMemberId: stringValue(required(object, 'paidByMemberId', path), `${path}.paidByMemberId`),
    amount,
    splitMethod: splitMethod(required(object, 'splitMethod', path), `${path}.splitMethod`),
    splits,
    status: status as LedgerExpense['status'],
    createdAt: isoDate(required(object, 'createdAt', path), `${path}.createdAt`),
    updatedAt: isoDate(required(object, 'updatedAt', path), `${path}.updatedAt`),
  }
}

function memberBalanceSurface(value: unknown, path: string): MemberBalanceSurface {
  const object = record(value, path)
  return {
    memberId: stringValue(required(object, 'memberId', path), `${path}.memberId`),
    byCurrency: arrayValue(required(object, 'byCurrency', path), `${path}.byCurrency`).map((entry, index) =>
      moneyValue(entry, `${path}.byCurrency[${index}]`)
    ),
  }
}

function currencyBalanceSurface(value: unknown, path: string): CurrencyBalanceSurface {
  const object = record(value, path)
  const currency = currencyDescriptor(required(object, 'currency', path), `${path}.currency`)
  const totalPositive = moneyValue(required(object, 'totalPositive', path), `${path}.totalPositive`)
  const totalNegative = moneyValue(required(object, 'totalNegative', path), `${path}.totalNegative`)
  const net = moneyValue(required(object, 'net', path), `${path}.net`)
  for (const [label, amount] of [
    ['totalPositive', totalPositive],
    ['totalNegative', totalNegative],
    ['net', net],
  ] as const) {
    if (amount.currencyCode !== currency.currencyCode || amount.currencyExponent !== currency.currencyExponent) {
      return fail(`${path}.${label}`, 'must use the surrounding currency descriptor')
    }
  }
  if (compareMoney(totalPositive, createZero(totalPositive)) < 0) return fail(`${path}.totalPositive`, 'cannot be negative')
  if (compareMoney(totalNegative, createZero(totalNegative)) > 0) return fail(`${path}.totalNegative`, 'cannot be positive')
  let expectedNet: Money
  try {
    expectedNet = addMoney(totalPositive, totalNegative)
  } catch (error) {
    return fail(path, error instanceof Error ? error.message : 'invalid currency totals')
  }
  if (!moneyEquals(expectedNet, net)) return fail(`${path}.net`, 'must equal positive plus negative exactly')
  return { currency, totalPositive, totalNegative, net }
}

function createZero(value: Money): Money {
  return { minorUnits: '0', currencyCode: value.currencyCode, currencyExponent: value.currencyExponent }
}

function groupBalanceSurface(value: unknown, path: string): GroupBalanceSurface {
  const object = record(value, path)
  const byMember = arrayValue(required(object, 'byMember', path), `${path}.byMember`).map((entry, index) =>
    memberBalanceSurface(entry, `${path}.byMember[${index}]`)
  )
  const byCurrency = arrayValue(required(object, 'byCurrency', path), `${path}.byCurrency`).map((entry, index) =>
    currencyBalanceSurface(entry, `${path}.byCurrency[${index}]`)
  )
  const current = record(required(object, 'currentAccount', path), `${path}.currentAccount`)
  return {
    byMember,
    byCurrency,
    currentAccount: {
      accountId: stringValue(required(current, 'accountId', `${path}.currentAccount`), `${path}.currentAccount.accountId`),
      memberId: stringValue(required(current, 'memberId', `${path}.currentAccount`), `${path}.currentAccount.memberId`),
      byCurrency: arrayValue(required(current, 'byCurrency', `${path}.currentAccount`), `${path}.currentAccount.byCurrency`).map(
        (entry, index) => moneyValue(entry, `${path}.currentAccount.byCurrency[${index}]`)
      ),
    },
  }
}

function settlementTransfer(value: unknown, path: string): SettlementTransfer {
  const object = record(value, path)
  const mode = required(object, 'mode', path)
  if (mode !== 'DIRECT' && mode !== 'SIMPLIFIED') return fail(`${path}.mode`, 'must be DIRECT or SIMPLIFIED')
  return {
    planTransferId: stringValue(required(object, 'planTransferId', path), `${path}.planTransferId`),
    payerMemberId: stringValue(required(object, 'payerMemberId', path), `${path}.payerMemberId`),
    recipientMemberId: stringValue(required(object, 'recipientMemberId', path), `${path}.recipientMemberId`),
    amount: moneyValue(required(object, 'amount', path), `${path}.amount`),
    mode,
    obligationComponentIds: idList(required(object, 'obligationComponentIds', path), `${path}.obligationComponentIds`),
  }
}

function settlementPlan(value: unknown, path: string): SettlementPlan {
  const object = record(value, path)
  const mode = required(object, 'mode', path)
  if (mode !== 'DIRECT' && mode !== 'SIMPLIFIED') return fail(`${path}.mode`, 'must be DIRECT or SIMPLIFIED')
  return {
    revision: integerValue(required(object, 'revision', path), `${path}.revision`),
    mode,
    transfers: arrayValue(required(object, 'transfers', path), `${path}.transfers`).map((entry, index) =>
      settlementTransfer(entry, `${path}.transfers[${index}]`)
    ),
  }
}

function settlementHistory(value: unknown, path: string): SettlementHistoryItem {
  const object = record(value, path)
  const type = required(object, 'type', path)
  if (type === 'settlement') {
    const status = required(object, 'status', path)
    if (status !== 'active' && status !== 'reversed') return fail(`${path}.status`, 'must be active or reversed')
    return {
      type,
      settlementId: stringValue(required(object, 'settlementId', path), `${path}.settlementId`),
      payerMemberId: stringValue(required(object, 'payerMemberId', path), `${path}.payerMemberId`),
      recipientMemberId: stringValue(required(object, 'recipientMemberId', path), `${path}.recipientMemberId`),
      amount: moneyValue(required(object, 'amount', path), `${path}.amount`),
      status,
      reversalId: nullableText(required(object, 'reversalId', path), `${path}.reversalId`),
      actorMemberId: stringValue(required(object, 'actorMemberId', path), `${path}.actorMemberId`),
      createdAt: isoDate(required(object, 'createdAt', path), `${path}.createdAt`),
    }
  }
  if (type === 'reversal') {
    return {
      type,
      reversalId: stringValue(required(object, 'reversalId', path), `${path}.reversalId`),
      settlementId: stringValue(required(object, 'settlementId', path), `${path}.settlementId`),
      amount: moneyValue(required(object, 'amount', path), `${path}.amount`),
      actorMemberId: stringValue(required(object, 'actorMemberId', path), `${path}.actorMemberId`),
      createdAt: isoDate(required(object, 'createdAt', path), `${path}.createdAt`),
    }
  }
  return fail(`${path}.type`, 'must be settlement or reversal')
}

function activity(value: unknown, path: string): ActivityItem {
  const object = record(value, path)
  const type = required(object, 'type', path)
  const base = {
    activityId: stringValue(required(object, 'activityId', path), `${path}.activityId`),
    amount: moneyValue(required(object, 'amount', path), `${path}.amount`),
    at: isoDate(required(object, 'at', path), `${path}.at`),
  }
  if (type === 'expense') {
    return { ...base, type, expenseId: stringValue(required(object, 'expenseId', path), `${path}.expenseId`) }
  }
  if (type === 'settlement') {
    return { ...base, type, settlementId: stringValue(required(object, 'settlementId', path), `${path}.settlementId`) }
  }
  if (type === 'reversal') {
    return {
      ...base,
      type,
      reversalId: stringValue(required(object, 'reversalId', path), `${path}.reversalId`),
      settlementId: stringValue(required(object, 'settlementId', path), `${path}.settlementId`),
    }
  }
  return fail(`${path}.type`, 'must be expense, settlement, or reversal')
}

function accountBalance(value: unknown, path: string): AccountBalanceSurface {
  const object = record(value, path)
  return {
    accountId: stringValue(required(object, 'accountId', path), `${path}.accountId`),
    memberId: stringValue(required(object, 'memberId', path), `${path}.memberId`),
    byCurrency: arrayValue(required(object, 'byCurrency', path), `${path}.byCurrency`).map((entry, index) =>
      moneyValue(entry, `${path}.byCurrency[${index}]`)
    ),
  }
}

function groupSummary(value: unknown, path: string): AccountGroupSummary {
  const object = record(value, path)
  literal(object.localOnly, false, `${path}.localOnly`)
  return {
    groupId: stringValue(required(object, 'groupId', path), `${path}.groupId`),
    name: textValue(required(object, 'name', path), `${path}.name`),
    baseCurrency: currencyDescriptor(required(object, 'baseCurrency', path), `${path}.baseCurrency`),
    revision: integerValue(required(object, 'revision', path), `${path}.revision`),
    localOnly: false,
    balanceByCurrency: arrayValue(required(object, 'balanceByCurrency', path), `${path}.balanceByCurrency`).map(
      (entry, index) => moneyValue(entry, `${path}.balanceByCurrency[${index}]`)
    ),
  }
}

function accountReadModel(value: unknown, path: string): AccountLedgerReadModel {
  const object = record(value, path)
  const sharedGroups = arrayValue(required(object, 'sharedGroups', path), `${path}.sharedGroups`).map((entry, index) =>
    groupSummary(entry, `${path}.sharedGroups[${index}]`)
  )
  return {
    accountId: stringValue(required(object, 'accountId', path), `${path}.accountId`),
    currentMemberId: stringValue(required(object, 'currentMemberId', path), `${path}.currentMemberId`),
    readRevision: integerValue(required(object, 'readRevision', path), `${path}.readRevision`),
    sharedGroups,
    balance: accountBalance(required(object, 'balance', path), `${path}.balance`),
    pendingOperations: arrayValue(required(object, 'pendingOperations', path), `${path}.pendingOperations`).map(
      (entry, index) => pendingOperation(entry, `${path}.pendingOperations[${index}]`)
    ),
    migration: migrationValue(required(object, 'migration', path), `${path}.migration`),
    stale: staleValue(required(object, 'stale', path), `${path}.stale`),
    authority: authorityValue(required(object, 'authority', path), `${path}.authority`),
  }
}

function groupReadModel(value: unknown, path: string): GroupLedgerReadModel {
  const object = record(value, path)
  literal(object.scope, 'shared', `${path}.scope`)
  literal(object.localOnly, false, `${path}.localOnly`)
  const members = arrayValue(required(object, 'members', path), `${path}.members`).map((entry, index) =>
    memberIdentity(entry, `${path}.members[${index}]`)
  )
  if (new Set(members.map((member) => member.memberId)).size !== members.length) {
    return fail(`${path}.members`, 'must not contain duplicate member IDs')
  }
  const expenses = arrayValue(required(object, 'expenses', path), `${path}.expenses`).map((entry, index) =>
    ledgerExpense(entry, `${path}.expenses[${index}]`)
  )
  const memberIds = new Set(members.map((member) => member.memberId))
  for (const [index, expense] of expenses.entries()) {
    if (!memberIds.has(expense.paidByMemberId)) return fail(`${path}.expenses[${index}].paidByMemberId`, 'must reference a member')
    for (const [splitIndex, split] of expense.splits.entries()) {
      if (!memberIds.has(split.memberId)) return fail(`${path}.expenses[${index}].splits[${splitIndex}].memberId`, 'must reference a member')
    }
  }
  const revision = integerValue(required(object, 'revision', path), `${path}.revision`)
  const readRevision = integerValue(required(object, 'readRevision', path), `${path}.readRevision`)
  const balances = groupBalanceSurface(required(object, 'balances', path), `${path}.balances`)
  for (const [index, balance] of balances.byMember.entries()) {
    if (!memberIds.has(balance.memberId)) return fail(`${path}.balances.byMember[${index}].memberId`, 'must reference a member')
  }
  if (!memberIds.has(balances.currentAccount.memberId)) return fail(`${path}.balances.currentAccount.memberId`, 'must reference a member')
  const plan = settlementPlan(required(object, 'settlementPlan', path), `${path}.settlementPlan`)
  if (plan.revision !== revision) return fail(`${path}.settlementPlan.revision`, 'must equal group revision')
  for (const [index, transfer] of plan.transfers.entries()) {
    if (!memberIds.has(transfer.payerMemberId)) return fail(`${path}.settlementPlan.transfers[${index}].payerMemberId`, 'must reference a member')
    if (!memberIds.has(transfer.recipientMemberId)) return fail(`${path}.settlementPlan.transfers[${index}].recipientMemberId`, 'must reference a member')
  }
  const history = arrayValue(required(object, 'settlementHistory', path), `${path}.settlementHistory`).map((entry, index) =>
    settlementHistory(entry, `${path}.settlementHistory[${index}]`)
  )
  const activityItems = arrayValue(required(object, 'activity', path), `${path}.activity`).map((entry, index) =>
    activity(entry, `${path}.activity[${index}]`)
  )
  return {
    groupId: stringValue(required(object, 'groupId', path), `${path}.groupId`),
    accountId: stringValue(required(object, 'accountId', path), `${path}.accountId`),
    name: textValue(required(object, 'name', path), `${path}.name`),
    baseCurrency: currencyDescriptor(required(object, 'baseCurrency', path), `${path}.baseCurrency`),
    scope: 'shared',
    localOnly: false,
    revision,
    readRevision,
    members,
    expenses,
    balances,
    settlementPlan: plan,
    settlementHistory: history,
    activity: activityItems,
    pendingOperationIds: idList(required(object, 'pendingOperationIds', path), `${path}.pendingOperationIds`),
    migration: migrationValue(required(object, 'migration', path), `${path}.migration`),
    stale: staleValue(required(object, 'stale', path), `${path}.stale`),
    authority: authorityValue(required(object, 'authority', path), `${path}.authority`),
  }
}

function sharedScope(value: unknown, path: string): SharedGroupScope {
  const object = record(value, path)
  literal(object.kind, 'shared', `${path}.kind`)
  literal(object.localOnly, false, `${path}.localOnly`)
  return {
    kind: 'shared',
    accountId: stringValue(required(object, 'accountId', path), `${path}.accountId`),
    groupId: stringValue(required(object, 'groupId', path), `${path}.groupId`),
    localOnly: false,
  }
}

function readData(value: unknown, path: string): LedgerReadData {
  const object = record(value, path)
  return {
    account: accountReadModel(required(object, 'account', path), `${path}.account`),
    group: groupReadModel(required(object, 'group', path), `${path}.group`),
  }
}

export function parseLedgerReadEnvelope(value: unknown): LedgerReadEnvelope<LedgerReadData> {
  const object = record(value, '$.read')
  literal(object.contractVersion, LEDGER_CONTRACT_VERSION, '$.read.contractVersion')
  literal(object.kind, 'read', '$.read.kind')
  const scope = sharedScope(required(object, 'scope', '$.read'), '$.read.scope')
  const data = readData(required(object, 'data', '$.read'), '$.read.data')
  const revision = integerValue(required(object, 'revision', '$.read'), '$.read.revision')
  const readRevision = integerValue(required(object, 'readRevision', '$.read'), '$.read.readRevision')
  if (data.group.groupId !== scope.groupId) return fail('$.read.data.group.groupId', 'must match scope.groupId')
  if (data.group.accountId !== scope.accountId || data.account.accountId !== scope.accountId) {
    return fail('$.read.data', 'account IDs must match scope.accountId')
  }
  if (data.group.revision !== revision || data.group.readRevision !== readRevision) {
    return fail('$.read', 'revision fields must agree with the group read model')
  }
  if (data.account.readRevision !== readRevision) return fail('$.read.data.account.readRevision', 'must match readRevision')
  return {
    contractVersion: LEDGER_CONTRACT_VERSION,
    kind: 'read',
    scope,
    revision,
    readRevision,
    pendingOperationIds: idList(required(object, 'pendingOperationIds', '$.read'), '$.read.pendingOperationIds'),
    migration: migrationValue(required(object, 'migration', '$.read'), '$.read.migration'),
    stale: staleValue(required(object, 'stale', '$.read'), '$.read.stale'),
    authority: authorityValue(required(object, 'authority', '$.read'), '$.read.authority'),
    data,
  }
}

function mutationHeaders(value: unknown, path: string): LedgerMutationHeaders {
  const object = record(value, path)
  const expectedRevision = stringValue(required(object, 'Expected-Revision', path), `${path}.Expected-Revision`)
  if (!/^(0|[1-9]\d*)$/.test(expectedRevision)) return fail(`${path}.Expected-Revision`, 'must be a decimal revision string')
  literal(object['Client-Contract'], LEDGER_CLIENT_CONTRACT, `${path}.Client-Contract`)
  literal(object['Client-Compatibility'], LEDGER_CLIENT_CONTRACT, `${path}.Client-Compatibility`)
  return {
    'Idempotency-Key': stringValue(required(object, 'Idempotency-Key', path), `${path}.Idempotency-Key`),
    'Expected-Revision': expectedRevision,
    'Client-Contract': LEDGER_CLIENT_CONTRACT,
    'Client-Compatibility': LEDGER_CLIENT_CONTRACT,
  }
}

function expenseCreateBody(value: unknown, path: string): ExpenseCreateMutationBody {
  const object = record(value, path)
  literal(object.kind, 'expense.create', `${path}.kind`)
  const splits = arrayValue(required(object, 'splits', path), `${path}.splits`).map((entry, index) =>
    ledgerExpenseSplit(entry, `${path}.splits[${index}]`)
  )
  const amount = moneyValue(required(object, 'amount', path), `${path}.amount`)
  if (!moneyEquals(amount, sumMoney(splits.map((split) => split.amount), `${path}.splits`))) {
    return fail(`${path}.splits`, 'split amounts must equal the mutation amount exactly')
  }
  return {
    kind: 'expense.create',
    expenseId: stringValue(required(object, 'expenseId', path), `${path}.expenseId`),
    paidByMemberId: stringValue(required(object, 'paidByMemberId', path), `${path}.paidByMemberId`),
    description: textValue(required(object, 'description', path), `${path}.description`),
    amount,
    splitMethod: splitMethod(required(object, 'splitMethod', path), `${path}.splitMethod`),
    splits,
  }
}

function mutationRequest(value: unknown, path: string): LedgerMutationRequest<ExpenseCreateMutationBody> {
  const object = record(value, path)
  literal(object.contractVersion, LEDGER_CONTRACT_VERSION, `${path}.contractVersion`)
  literal(object.kind, 'mutation_request', `${path}.kind`)
  return {
    contractVersion: LEDGER_CONTRACT_VERSION,
    kind: 'mutation_request',
    groupId: stringValue(required(object, 'groupId', path), `${path}.groupId`),
    operationId: stringValue(required(object, 'operationId', path), `${path}.operationId`),
    headers: mutationHeaders(required(object, 'headers', path), `${path}.headers`),
    body: expenseCreateBody(required(object, 'body', path), `${path}.body`),
  }
}

function idempotencyReceipt(value: unknown, path: string): IdempotencyReceipt {
  const object = record(value, path)
  return {
    key: stringValue(required(object, 'key', path), `${path}.key`),
    requestHash: hashValue(required(object, 'requestHash', path), `${path}.requestHash`),
    replayed: booleanValue(required(object, 'replayed', path), `${path}.replayed`),
    resultRevision: integerValue(required(object, 'resultRevision', path), `${path}.resultRevision`),
    retainedUntil: isoDate(required(object, 'retainedUntil', path), `${path}.retainedUntil`),
  }
}

function mutationResult(value: unknown, path: string): LedgerMutationResultEnvelope {
  const object = record(value, path)
  literal(object.contractVersion, LEDGER_CONTRACT_VERSION, `${path}.contractVersion`)
  literal(object.kind, 'mutation_result', `${path}.kind`)
  const outcome = required(object, 'outcome', path)
  if (outcome !== 'applied' && outcome !== 'replayed') return fail(`${path}.outcome`, 'must be applied or replayed')
  const resultObject = record(required(object, 'result', path), `${path}.result`)
  const idempotency = idempotencyReceipt(required(object, 'idempotency', path), `${path}.idempotency`)
  const resultRevision = integerValue(required(object, 'revision', path), `${path}.revision`)
  if (idempotency.resultRevision !== resultRevision) return fail(`${path}.idempotency.resultRevision`, 'must match revision')
  if (outcome === 'applied' && idempotency.replayed) return fail(`${path}.idempotency.replayed`, 'must be false when applied')
  if (outcome === 'replayed' && !idempotency.replayed) return fail(`${path}.idempotency.replayed`, 'must be true when replayed')
  return {
    contractVersion: LEDGER_CONTRACT_VERSION,
    kind: 'mutation_result',
    groupId: stringValue(required(object, 'groupId', path), `${path}.groupId`),
    operationId: stringValue(required(object, 'operationId', path), `${path}.operationId`),
    outcome,
    revision: resultRevision,
    readRevision: integerValue(required(object, 'readRevision', path), `${path}.readRevision`),
    idempotency,
    result: {
      recordId: stringValue(required(resultObject, 'recordId', `${path}.result`), `${path}.result.recordId`),
      eventType: stringValue(required(resultObject, 'eventType', `${path}.result`), `${path}.result.eventType`),
    },
    authority: authorityValue(required(object, 'authority', path), `${path}.authority`),
  }
}

function conflict(value: unknown, path: string): LedgerConflictEnvelope {
  const object = record(value, path)
  literal(object.contractVersion, LEDGER_CONTRACT_VERSION, `${path}.contractVersion`)
  literal(object.kind, 'conflict', `${path}.kind`)
  const conflictObject = record(required(object, 'conflict', path), `${path}.conflict`)
  const code = required(conflictObject, 'code', `${path}.conflict`)
  if (code !== 'REVISION_CONFLICT' && code !== 'IDEMPOTENCY_KEY_REUSED' && code !== 'CLIENT_CONTRACT_UNSUPPORTED') {
    return fail(`${path}.conflict.code`, 'contains an unknown conflict code')
  }
  const expectedRevision = conflictObject.expectedRevision === null
    ? null
    : integerValue(conflictObject.expectedRevision, `${path}.conflict.expectedRevision`)
  const currentRevision = integerValue(required(conflictObject, 'currentRevision', `${path}.conflict`), `${path}.conflict.currentRevision`)
  literal(conflictObject.serverAuthoritative, true, `${path}.conflict.serverAuthoritative`)
  return {
    contractVersion: LEDGER_CONTRACT_VERSION,
    kind: 'conflict',
    groupId: stringValue(required(object, 'groupId', path), `${path}.groupId`),
    operationId: stringValue(required(object, 'operationId', path), `${path}.operationId`),
    revision: integerValue(required(object, 'revision', path), `${path}.revision`),
    readRevision: integerValue(required(object, 'readRevision', path), `${path}.readRevision`),
    conflict: {
      code,
      expectedRevision,
      currentRevision,
      retryable: booleanValue(required(conflictObject, 'retryable', `${path}.conflict`), `${path}.conflict.retryable`),
      message: textValue(required(conflictObject, 'message', `${path}.conflict`), `${path}.conflict.message`),
      serverAuthoritative: true,
    },
    idempotency: {
      key: stringValue(required(record(required(object, 'idempotency', path), `${path}.idempotency`), 'key', `${path}.idempotency`), `${path}.idempotency.key`),
      requestHash: hashValue(required(record(required(object, 'idempotency', path), `${path}.idempotency`), 'requestHash', `${path}.idempotency`), `${path}.idempotency.requestHash`),
    },
    snapshot: object.snapshot === null ? null : parseLedgerReadEnvelope(object.snapshot),
    authority: authorityValue(required(object, 'authority', path), `${path}.authority`),
  }
}

export function parseSharedLedgerFixture(value: unknown): SharedLedgerFixture {
  const object = record(value, '$')
  literal(object.fixtureId, 'shared-ledger-v2-comprehensive', '$.fixtureId')
  literal(object.contractVersion, LEDGER_CONTRACT_VERSION, '$.contractVersion')
  literal(object.kind, 'shared_ledger_fixture', '$.kind')
  const read = parseLedgerReadEnvelope(required(object, 'read', '$'))
  const excludedLocalOnlyGroupIds = idList(required(object, 'excludedLocalOnlyGroupIds', '$'), '$.excludedLocalOnlyGroupIds')
  const sharedGroupIds = new Set(read.data.account.sharedGroups.map((group) => group.groupId))
  if (excludedLocalOnlyGroupIds.some((groupId) => sharedGroupIds.has(groupId))) {
    return fail('$.excludedLocalOnlyGroupIds', 'must not overlap shared groups')
  }
  return {
    fixtureId: 'shared-ledger-v2-comprehensive',
    contractVersion: LEDGER_CONTRACT_VERSION,
    kind: 'shared_ledger_fixture',
    read,
    excludedLocalOnlyGroupIds,
  }
}

export function parseMutationFixture(value: unknown): MutationFixture {
  const object = record(value, '$')
  literal(object.fixtureId, 'mutation-envelopes-v2', '$.fixtureId')
  literal(object.contractVersion, LEDGER_CONTRACT_VERSION, '$.contractVersion')
  literal(object.kind, 'mutation_fixture', '$.kind')
  const request = mutationRequest(required(object, 'request', '$'), '$.request')
  const applied = mutationResult(required(object, 'applied', '$'), '$.applied')
  const replayed = mutationResult(required(object, 'replayed', '$'), '$.replayed')
  const revisionConflict = conflict(required(object, 'revisionConflict', '$'), '$.revisionConflict')
  const idempotencyConflict = conflict(required(object, 'idempotencyConflict', '$'), '$.idempotencyConflict')
  if (applied.groupId !== request.groupId || replayed.groupId !== request.groupId) return fail('$.request.groupId', 'must match mutation results')
  if (applied.operationId !== replayed.operationId) return fail('$.replayed.operationId', 'must match original operation')
  if (applied.idempotency.key !== replayed.idempotency.key || applied.idempotency.requestHash !== replayed.idempotency.requestHash) {
    return fail('$.replayed.idempotency', 'must retain the original idempotency receipt')
  }
  if (applied.revision !== replayed.revision || applied.readRevision !== replayed.readRevision) {
    return fail('$.replayed', 'must not advance the revision')
  }
  if (revisionConflict.conflict.code !== 'REVISION_CONFLICT') return fail('$.revisionConflict.conflict.code', 'must be REVISION_CONFLICT')
  if (revisionConflict.conflict.expectedRevision === revisionConflict.conflict.currentRevision) {
    return fail('$.revisionConflict.conflict', 'expected and current revisions must differ')
  }
  if (idempotencyConflict.conflict.code !== 'IDEMPOTENCY_KEY_REUSED') return fail('$.idempotencyConflict.conflict.code', 'must be IDEMPOTENCY_KEY_REUSED')
  return {
    fixtureId: 'mutation-envelopes-v2',
    contractVersion: LEDGER_CONTRACT_VERSION,
    kind: 'mutation_fixture',
    request,
    applied,
    replayed,
    revisionConflict,
    idempotencyConflict,
  }
}

export function assertIdempotencyReplay(
  applied: LedgerMutationResultEnvelope,
  replayed: LedgerMutationResultEnvelope
): void {
  if (applied.outcome !== 'applied' || replayed.outcome !== 'replayed') {
    return fail('idempotency', 'a replay pair must be applied followed by replayed')
  }
  if (
    applied.idempotency.key !== replayed.idempotency.key ||
    applied.idempotency.requestHash !== replayed.idempotency.requestHash ||
    applied.revision !== replayed.revision ||
    applied.result.recordId !== replayed.result.recordId
  ) {
    return fail('idempotency', 'a replay must return the original result without advancing revision')
  }
}

export type { LedgerReadData, LedgerReadEnvelope, SharedLedgerFixture, MutationFixture }
