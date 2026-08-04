import {
  addMoney,
  createMoney,
  moneyEquals,
  moneyToBigInt,
  negateMoney,
} from '../../ledger-contract/money'
import { LEDGER_CONTRACT_VERSION } from '../../ledger-contract/types'
import { buildPlanTransferId } from '../../settlement/money/transfer-id'
import type {
  AccountLedgerReadModel,
  AuthorityMarkers,
  CurrencyBalanceSurface,
  GroupBalanceSurface,
  GroupLedgerReadModel,
  LedgerActivityItem,
  LedgerExpense,
  LedgerMemberIdentity,
  LedgerReadEnvelope,
  Money,
  PendingOperation,
  SettlementHistoryItem,
  SettlementPlan,
  SettlementTransfer,
  StaleState,
  MigrationState,
} from '../../ledger-contract'
import {
  type AccountActivityItem,
  type AccountLedgerSummary,
  type AccountProjectionResult,
  type GroupLedgerProjection,
  LedgerReadModelError,
  type LedgerFriend,
  type LedgerReadProjection,
  type LedgerReadOnlyGroupSummary,
  type ReadModelAccountSource,
  type ReadModelBuildOptions,
  type ReadModelGroupSource,
  type ReadModelSettlementSource,
} from './types'

const AUTHORITY: AuthorityMarkers = {
  serverAuthoritative: true,
  source: 'server',
  readModel: 'server',
  ledger: 'server',
  balances: 'server',
  settlementPlan: 'server',
  settlementHistory: 'server',
  identity: 'server',
  cacheRole: 'offline-cache',
}

type CurrencyKey = string

type ObligationEdge = {
  currency: Money
  debtorMemberId: string
  creditorMemberId: string
  minorUnits: bigint
  componentIds: string[]
}

type MemberCurrencyTotals = Map<string, Map<CurrencyKey, bigint>>

function currencyKey(money: Money): CurrencyKey {
  return `${money.currencyCode}:${money.currencyExponent}`
}

function sortMoney(a: Money, b: Money): number {
  return a.currencyCode.localeCompare(b.currencyCode) || a.currencyExponent - b.currencyExponent
}

function sortIds(values: string[]): string[] {
  return Array.from(new Set(values)).sort((a, b) => a.localeCompare(b))
}

function exactMoney(minorUnits: bigint, currency: Money): Money {
  return createMoney(minorUnits, currency.currencyCode, currency.currencyExponent)
}

function zeroMoney(currency: Money): Money {
  return exactMoney(0n, currency)
}

function normalizeObservedAt(value: Date | string | undefined): string {
  if (value instanceof Date) return value.toISOString()
  if (typeof value === 'string') {
    const parsed = new Date(value)
    if (!Number.isNaN(parsed.getTime())) return parsed.toISOString()
  }
  return '1970-01-01T00:00:00.000Z'
}

function staleState(readRevision: number, observedAt: string): StaleState {
  return {
    isStale: false,
    reason: 'none',
    observedAt,
    readRevision,
    serverRevision: readRevision,
  }
}

function memberMap(source: ReadModelGroupSource): Map<string, LedgerMemberIdentity> {
  const members = new Map<string, LedgerMemberIdentity>()
  for (const member of source.members) {
    if (members.has(member.memberId)) {
      throw new LedgerReadModelError(
        'INVALID_LEDGER_RECORD',
        `Duplicate ledger member ${member.memberId}`,
        { groupId: source.groupId, memberId: member.memberId }
      )
    }
    members.set(member.memberId, member)
  }
  return members
}

function assertMember(
  members: Map<string, LedgerMemberIdentity>,
  memberId: string,
  source: ReadModelGroupSource,
  recordId: string
): void {
  if (!members.has(memberId)) {
    throw new LedgerReadModelError(
      'INVALID_LEDGER_RECORD',
      `Ledger record ${recordId} references unknown member ${memberId}`,
      { groupId: source.groupId, recordId, memberId }
    )
  }
}

function addTotal(
  totals: MemberCurrencyTotals,
  memberId: string,
  money: Money,
  delta: bigint
): void {
  const byCurrency = totals.get(memberId) ?? new Map<CurrencyKey, bigint>()
  byCurrency.set(currencyKey(money), (byCurrency.get(currencyKey(money)) ?? 0n) + delta)
  totals.set(memberId, byCurrency)
}

function addCurrency(currencies: Map<CurrencyKey, Money>, money: Money): void {
  const existing = currencies.get(currencyKey(money))
  if (existing && !moneyEquals(zeroMoney(existing), zeroMoney(money))) {
    throw new LedgerReadModelError(
      'INVALID_LEDGER_RECORD',
      `Currency descriptor drift for ${money.currencyCode}`,
      { currencyCode: money.currencyCode, currencyExponent: money.currencyExponent }
    )
  }
  currencies.set(currencyKey(money), zeroMoney(money))
}

function validateExpense(
  expense: LedgerExpense,
  source: ReadModelGroupSource,
  members: Map<string, LedgerMemberIdentity>
): void {
  assertMember(members, expense.paidByMemberId, source, expense.expenseId)
  if (expense.splits.length === 0) {
    throw new LedgerReadModelError(
      'INVALID_LEDGER_RECORD',
      `Expense ${expense.expenseId} has no exact splits`,
      { groupId: source.groupId, expenseId: expense.expenseId }
    )
  }

  let splitTotal = expense.splits[0].amount
  for (const split of expense.splits.slice(1)) {
    splitTotal = addMoney(splitTotal, split.amount)
  }
  if (!moneyEquals(expense.amount, splitTotal)) {
    throw new LedgerReadModelError(
      'INVALID_LEDGER_RECORD',
      `Expense ${expense.expenseId} split amounts do not equal the expense amount`,
      { groupId: source.groupId, expenseId: expense.expenseId }
    )
  }

  for (const split of expense.splits) {
    assertMember(members, split.memberId, source, `${expense.expenseId}:${split.splitId}`)
    if (split.amount.currencyCode !== expense.amount.currencyCode || split.amount.currencyExponent !== expense.amount.currencyExponent) {
      throw new LedgerReadModelError(
        'INVALID_LEDGER_RECORD',
        `Expense ${expense.expenseId} contains a mixed-currency split`,
        { groupId: source.groupId, expenseId: expense.expenseId, splitId: split.splitId }
      )
    }
  }
}

function buildBalances(
  source: ReadModelGroupSource,
  members: Map<string, LedgerMemberIdentity>,
  currencies: Map<CurrencyKey, Money>
): { totals: MemberCurrencyTotals; balances: GroupBalanceSurface } {
  const totals: MemberCurrencyTotals = new Map()

  for (const expense of source.expenses) {
    validateExpense(expense, source, members)
    addCurrency(currencies, expense.amount)
    for (const split of expense.splits) addCurrency(currencies, split.amount)
    if (expense.status === 'voided') continue

    addTotal(totals, expense.paidByMemberId, expense.amount, moneyToBigInt(expense.amount))
    for (const split of expense.splits) {
      addTotal(totals, split.memberId, split.amount, -moneyToBigInt(split.amount))
    }
  }

  for (const settlement of source.settlements) {
    assertMember(members, settlement.payerMemberId, source, settlement.settlementId)
    assertMember(members, settlement.recipientMemberId, source, settlement.settlementId)
    addCurrency(currencies, settlement.amount)
    if (settlement.reversed) continue
    addTotal(totals, settlement.payerMemberId, settlement.amount, moneyToBigInt(settlement.amount))
    addTotal(totals, settlement.recipientMemberId, settlement.amount, -moneyToBigInt(settlement.amount))
  }

  const orderedCurrencies = Array.from(currencies.values()).sort(sortMoney)
  const orderedMembers = Array.from(members.values()).sort((a, b) => a.memberId.localeCompare(b.memberId))
  const byMember = orderedMembers.map((member) => ({
    memberId: member.memberId,
    byCurrency: orderedCurrencies.map((currency) =>
      exactMoney(totals.get(member.memberId)?.get(currencyKey(currency)) ?? 0n, currency)
    ),
  }))

  const byCurrency: CurrencyBalanceSurface[] = orderedCurrencies.map((currency) => {
    let totalPositive = 0n
    let totalNegative = 0n
    for (const member of orderedMembers) {
      const value = totals.get(member.memberId)?.get(currencyKey(currency)) ?? 0n
      if (value > 0n) totalPositive += value
      if (value < 0n) totalNegative += value
    }
    const positive = exactMoney(totalPositive, currency)
    const negative = exactMoney(totalNegative, currency)
    return {
      currency: {
        currencyCode: currency.currencyCode,
        currencyExponent: currency.currencyExponent,
      },
      totalPositive: positive,
      totalNegative: negative,
      net: addMoney(positive, negative),
    }
  })

  const currentMember = orderedMembers.find((member) => member.accountId === source.accountId)
  if (!currentMember) {
    throw new LedgerReadModelError(
      'INVALID_LEDGER_RECORD',
      `Account ${source.accountId} is not a member of group ${source.groupId}`,
      { groupId: source.groupId, accountId: source.accountId }
    )
  }

  return {
    totals,
    balances: {
      byMember,
      byCurrency,
      currentAccount: {
        accountId: source.accountId,
        memberId: currentMember.memberId,
        byCurrency: byMember.find((entry) => entry.memberId === currentMember.memberId)!.byCurrency,
      },
    },
  }
}

function edgeKey(currency: Money, debtorMemberId: string, creditorMemberId: string): string {
  return `${currencyKey(currency)}:${debtorMemberId}:${creditorMemberId}`
}

function mergeEdge(
  edges: Map<string, ObligationEdge>,
  edge: ObligationEdge
): void {
  if (edge.minorUnits <= 0n || edge.debtorMemberId === edge.creditorMemberId) return
  const key = edgeKey(edge.currency, edge.debtorMemberId, edge.creditorMemberId)
  const existing = edges.get(key)
  if (!existing) {
    edges.set(key, { ...edge, componentIds: sortIds(edge.componentIds) })
    return
  }
  existing.minorUnits += edge.minorUnits
  existing.componentIds = sortIds([...existing.componentIds, ...edge.componentIds])
}

function netObligationEdges(rawEdges: Map<string, ObligationEdge>): Map<string, ObligationEdge> {
  const net = new Map<string, ObligationEdge>()
  const ordered = Array.from(rawEdges.values()).sort((a, b) =>
    edgeKey(a.currency, a.debtorMemberId, a.creditorMemberId).localeCompare(
      edgeKey(b.currency, b.debtorMemberId, b.creditorMemberId)
    )
  )

  for (const edge of ordered) {
    const reverseKey = edgeKey(edge.currency, edge.creditorMemberId, edge.debtorMemberId)
    const reverse = net.get(reverseKey)
    if (!reverse) {
      const key = edgeKey(edge.currency, edge.debtorMemberId, edge.creditorMemberId)
      net.set(key, { ...edge, componentIds: sortIds(edge.componentIds) })
      continue
    }

    const components = sortIds([...edge.componentIds, ...reverse.componentIds])
    if (reverse.minorUnits > edge.minorUnits) {
      reverse.minorUnits -= edge.minorUnits
      reverse.componentIds = components
      continue
    }
    net.delete(reverseKey)
    if (edge.minorUnits > reverse.minorUnits) {
      const key = edgeKey(edge.currency, edge.debtorMemberId, edge.creditorMemberId)
      net.set(key, {
        ...edge,
        minorUnits: edge.minorUnits - reverse.minorUnits,
        componentIds: components,
      })
    }
  }
  return net
}

function applyDirectSettlement(edges: Map<string, ObligationEdge>, settlement: ReadModelSettlementSource): void {
  const apply = (payerMemberId: string, recipientMemberId: string, amount: Money) => {
    if (amount.minorUnits === '0') return
    const positiveAmount = moneyToBigInt(amount)
    const payer = positiveAmount >= 0n ? payerMemberId : recipientMemberId
    const recipient = positiveAmount >= 0n ? recipientMemberId : payerMemberId
    let remaining = positiveAmount >= 0n ? positiveAmount : -positiveAmount
    const key = edgeKey(amount, payer, recipient)
    const edge = edges.get(key)
    if (!edge) return
    const consumed = remaining < edge.minorUnits ? remaining : edge.minorUnits
    edge.minorUnits -= consumed
    remaining -= consumed
    if (edge.minorUnits === 0n) edges.delete(key)
  }

  if (settlement.allocationPaths.length > 0) {
    for (const path of settlement.allocationPaths) {
      apply(path.payerMemberId, path.recipientMemberId, path.amount)
    }
    return
  }
  apply(settlement.payerMemberId, settlement.recipientMemberId, settlement.amount)
}

function buildObligationEdges(source: ReadModelGroupSource, currencies: Map<CurrencyKey, Money>): Map<string, ObligationEdge> {
  const raw = new Map<string, ObligationEdge>()
  for (const expense of source.expenses) {
    if (expense.status === 'voided') continue
    for (const split of expense.splits) {
      const splitMinor = moneyToBigInt(split.amount)
      if (split.memberId === expense.paidByMemberId || splitMinor === 0n) continue
      const positive = splitMinor > 0n
      const debtorMemberId = positive ? split.memberId : expense.paidByMemberId
      const creditorMemberId = positive ? expense.paidByMemberId : split.memberId
      const amount = positive ? split.amount : negateMoney(split.amount)
      addCurrency(currencies, amount)
      mergeEdge(raw, {
        currency: amount,
        debtorMemberId,
        creditorMemberId,
        minorUnits: moneyToBigInt(amount),
        componentIds: [`${expense.expenseId}:${split.splitId}`],
      })
    }
  }

  const net = netObligationEdges(raw)
  for (const settlement of [...source.settlements].sort((a, b) =>
    a.createdAt.localeCompare(b.createdAt) || a.settlementId.localeCompare(b.settlementId)
  )) {
    if (!settlement.reversed) applyDirectSettlement(net, settlement)
  }
  return net
}

function planTransfer(
  source: ReadModelGroupSource,
  mode: 'DIRECT' | 'SIMPLIFIED',
  payerMemberId: string,
  recipientMemberId: string,
  amount: Money,
  componentIds: string[]
): SettlementTransfer {
  return {
    planTransferId: buildPlanTransferId({
      groupId: source.groupId,
      settlementVersion: source.revision,
      mode,
      amount: {
        currencyCode: amount.currencyCode,
        currencyExponent: amount.currencyExponent,
        minorUnits: moneyToBigInt(amount),
      },
      payerParticipantId: payerMemberId,
      recipientParticipantId: recipientMemberId,
    }),
    payerMemberId,
    recipientMemberId,
    amount,
    mode,
    obligationComponentIds: sortIds(componentIds),
  }
}

function buildSettlementPlan(
  source: ReadModelGroupSource,
  totals: MemberCurrencyTotals,
  currencies: Map<CurrencyKey, Money>,
  edges: Map<string, ObligationEdge>
): SettlementPlan {
  const mode = source.simplifyDebts ? 'SIMPLIFIED' : 'DIRECT'
  const orderedCurrencies = Array.from(currencies.values()).sort(sortMoney)
  const transfers: SettlementTransfer[] = []

  if (!source.simplifyDebts) {
    for (const edge of Array.from(edges.values()).sort((a, b) =>
      sortMoney(a.currency, b.currency) ||
      a.debtorMemberId.localeCompare(b.debtorMemberId) ||
      a.creditorMemberId.localeCompare(b.creditorMemberId)
    )) {
      if (edge.minorUnits <= 0n) continue
      transfers.push(
        planTransfer(
          source,
          mode,
          edge.debtorMemberId,
          edge.creditorMemberId,
          exactMoney(edge.minorUnits, edge.currency),
          edge.componentIds
        )
      )
    }
    return { revision: source.revision, mode, transfers }
  }

  for (const currency of orderedCurrencies) {
    const debtors = Array.from(totals.entries())
      .map(([memberId, byCurrency]) => ({
        memberId,
        minorUnits: byCurrency.get(currencyKey(currency)) ?? 0n,
      }))
      .filter((entry) => entry.minorUnits < 0n)
      .map((entry) => ({ memberId: entry.memberId, amount: -entry.minorUnits }))
      .sort((a, b) => b.amount === a.amount ? a.memberId.localeCompare(b.memberId) : b.amount > a.amount ? 1 : -1)
    const creditors = Array.from(totals.entries())
      .map(([memberId, byCurrency]) => ({
        memberId,
        minorUnits: byCurrency.get(currencyKey(currency)) ?? 0n,
      }))
      .filter((entry) => entry.minorUnits > 0n)
      .map((entry) => ({ memberId: entry.memberId, amount: entry.minorUnits }))
      .sort((a, b) => b.amount === a.amount ? a.memberId.localeCompare(b.memberId) : b.amount > a.amount ? 1 : -1)

    let debtorIndex = 0
    let creditorIndex = 0
    while (debtorIndex < debtors.length && creditorIndex < creditors.length) {
      const debtor = debtors[debtorIndex]
      const creditor = creditors[creditorIndex]
      const amountMinorUnits = debtor.amount < creditor.amount ? debtor.amount : creditor.amount
      const debtorComponents = Array.from(edges.values())
        .filter((edge) => edge.currency.currencyCode === currency.currencyCode && edge.currency.currencyExponent === currency.currencyExponent && edge.debtorMemberId === debtor.memberId)
        .flatMap((edge) => edge.componentIds)
      const fallbackComponents = Array.from(edges.values())
        .filter((edge) => edge.currency.currencyCode === currency.currencyCode && edge.currency.currencyExponent === currency.currencyExponent)
        .flatMap((edge) => edge.componentIds)
      transfers.push(
        planTransfer(
          source,
          mode,
          debtor.memberId,
          creditor.memberId,
          exactMoney(amountMinorUnits, currency),
          debtorComponents.length > 0 ? debtorComponents : fallbackComponents
        )
      )
      debtor.amount -= amountMinorUnits
      creditor.amount -= amountMinorUnits
      if (debtor.amount === 0n) debtorIndex++
      if (creditor.amount === 0n) creditorIndex++
    }
  }

  return {
    revision: source.revision,
    mode,
    transfers: transfers.sort((a, b) =>
      sortMoney(a.amount, b.amount) ||
      a.payerMemberId.localeCompare(b.payerMemberId) ||
      a.recipientMemberId.localeCompare(b.recipientMemberId)
    ),
  }
}

function historyAndActivity(source: ReadModelGroupSource): {
  history: SettlementHistoryItem[]
  activity: LedgerActivityItem[]
} {
  const history: SettlementHistoryItem[] = []
  const activity: LedgerActivityItem[] = []

  for (const expense of source.expenses) {
    activity.push({
      activityId: `activity-${expense.expenseId}`,
      type: 'expense',
      expenseId: expense.expenseId,
      amount: expense.amount,
      at: expense.createdAt,
    })
  }

  for (const settlement of source.settlements) {
    history.push({
      type: 'settlement',
      settlementId: settlement.settlementId,
      payerMemberId: settlement.payerMemberId,
      recipientMemberId: settlement.recipientMemberId,
      amount: settlement.amount,
      status: settlement.reversed ? 'reversed' : 'active',
      reversalId: settlement.reversal?.reversalId ?? null,
      actorMemberId: settlement.actorMemberId,
      createdAt: settlement.createdAt,
    })
    if (!settlement.reversed) {
      activity.push({
        activityId: `activity-${settlement.settlementId}`,
        type: 'settlement',
        settlementId: settlement.settlementId,
        amount: settlement.amount,
        at: settlement.createdAt,
      })
    }
    if (settlement.reversal) {
      history.push({
        type: 'reversal',
        reversalId: settlement.reversal.reversalId,
        settlementId: settlement.settlementId,
        amount: settlement.amount,
        actorMemberId: settlement.reversal.actorMemberId,
        createdAt: settlement.reversal.createdAt,
      })
      activity.push({
        activityId: `activity-${settlement.reversal.reversalId}`,
        type: 'reversal',
        reversalId: settlement.reversal.reversalId,
        settlementId: settlement.settlementId,
        amount: settlement.amount,
        at: settlement.reversal.createdAt,
      })
    }
  }

  const activityOrder = (a: LedgerActivityItem, b: LedgerActivityItem) =>
    a.at.localeCompare(b.at) || a.activityId.localeCompare(b.activityId)
  activity.sort(activityOrder)
  history.sort((a, b) => {
    const byDate = a.createdAt.localeCompare(b.createdAt)
    if (byDate !== 0) return byDate
    if (a.type !== b.type) return a.type === 'settlement' ? -1 : 1
    if (a.type === 'settlement' && b.type === 'settlement') {
      return a.settlementId.localeCompare(b.settlementId)
    }
    if (a.type === 'reversal' && b.type === 'reversal') {
      return a.reversalId.localeCompare(b.reversalId)
    }
    return 0
  })
  return { history, activity }
}

function groupSummary(
  source: ReadModelGroupSource,
  group: GroupLedgerReadModel,
  readOnly: boolean
): LedgerReadOnlyGroupSummary {
  return {
    groupId: source.groupId,
    name: source.name,
    baseCurrency: source.baseCurrency,
    revision: source.revision,
    localOnly: false,
    balanceByCurrency: group.balances.currentAccount.byCurrency,
    readOnly,
    migration: group.migration,
  }
}

function migrationPriority(status: MigrationState['status']): number {
  switch (status) {
    case 'blocked': return 5
    case 'in_progress': return 4
    case 'pending': return 3
    case 'complete': return 2
    case 'not_required': return 1
  }
}

function aggregateMigration(states: MigrationState[]): MigrationState {
  if (states.length === 0) {
    return {
      status: 'not_required',
      source: 'none',
      migrationId: null,
      importedAt: null,
      dualWriteEnabled: false,
      recoveryReadOnly: false,
    }
  }
  return [...states].sort((a, b) => migrationPriority(b.status) - migrationPriority(a.status))[0]
}

export function buildGroupLedgerProjection(
  source: ReadModelGroupSource,
  options: ReadModelBuildOptions = {}
): GroupLedgerProjection {
  if (source.localOnly !== false) {
    throw new LedgerReadModelError(
      'INVALID_LEDGER_RECORD',
      `Local-only group ${source.groupId} cannot enter the shared ledger projection`,
      { groupId: source.groupId }
    )
  }

  const members = memberMap(source)
  const currencies = new Map<CurrencyKey, Money>()
  addCurrency(currencies, createMoney('0', source.baseCurrency.currencyCode, source.baseCurrency.currencyExponent))
  const { totals, balances } = buildBalances(source, members, currencies)
  const edges = buildObligationEdges(source, currencies)
  const settlementPlan = buildSettlementPlan(source, totals, currencies, edges)
  const { history, activity } = historyAndActivity(source)
  const observedAt = normalizeObservedAt(options.observedAt)
  const hasMigrationIssues = source.migrationIssueIds !== undefined && source.migrationIssueIds.length > 0
  const migration = hasMigrationIssues
    ? readOnlyMigrationState(`money-migration:${source.groupId}`)
    : source.migration
  const readOnly = hasMigrationIssues || migration.status === 'blocked' || migration.status === 'pending' || migration.status === 'in_progress'

  const model: GroupLedgerReadModel = {
    groupId: source.groupId,
    accountId: source.accountId,
    name: source.name,
    baseCurrency: source.baseCurrency,
    scope: 'shared',
    localOnly: false,
    revision: source.revision,
    readRevision: source.revision,
    members: Array.from(members.values()).sort((a, b) => a.memberId.localeCompare(b.memberId)),
    expenses: [...source.expenses].sort((a, b) => a.createdAt.localeCompare(b.createdAt) || a.expenseId.localeCompare(b.expenseId)),
    balances,
    settlementPlan,
    settlementHistory: history,
    activity,
    pendingOperationIds: [...source.pendingOperationIds].sort((a, b) => a.localeCompare(b)),
    migration,
    stale: staleState(source.revision, observedAt),
    authority: AUTHORITY,
  }
  return { model, readOnly }
}

export function buildGroupLedgerReadEnvelope(
  source: ReadModelGroupSource,
  allGroups: ReadModelGroupSource[] = [source],
  pendingOperations: PendingOperation[] = [],
  options: ReadModelBuildOptions = {}
): LedgerReadProjection {
  const groupProjection = buildGroupLedgerProjection(source, options)
  const projectedGroups = allGroups
    .filter((group) => group.localOnly === false)
    .sort((a, b) => (b.updatedAt ?? '').localeCompare(a.updatedAt ?? '') || a.groupId.localeCompare(b.groupId))
    .map((group) => buildGroupLedgerProjection(group, options))
  const sharedGroups = projectedGroups.map((projection) => groupSummary(
    allGroups.find((group) => group.groupId === projection.model.groupId)!,
    projection.model,
    projection.readOnly
  ))
  const currentMember = groupProjection.model.members.find((member) => member.accountId === source.accountId)
  if (!currentMember) {
    throw new LedgerReadModelError('INVALID_LEDGER_RECORD', `Account ${source.accountId} is not a member of group ${source.groupId}`)
  }
  const accountMigration = aggregateMigration(projectedGroups.map((projection) => projection.model.migration))
  const accountReadRevision = groupProjection.model.readRevision
  const account: AccountLedgerReadModel = {
    accountId: source.accountId,
    currentMemberId: currentMember.memberId,
    readRevision: accountReadRevision,
    sharedGroups: sharedGroups.map(({ readOnly: _readOnly, migration: _migration, ...summary }) => summary),
    balance: {
      accountId: source.accountId,
      memberId: currentMember.memberId,
      byCurrency: groupProjection.model.balances.currentAccount.byCurrency,
    },
    pendingOperations,
    migration: source.migration.status === 'blocked' ? source.migration : accountMigration,
    stale: groupProjection.model.stale,
    authority: AUTHORITY,
  }
  const envelope: LedgerReadEnvelope<{ account: AccountLedgerReadModel; group: GroupLedgerReadModel }> = {
    contractVersion: LEDGER_CONTRACT_VERSION,
    kind: 'read',
    scope: {
      kind: 'shared',
      accountId: source.accountId,
      groupId: source.groupId,
      localOnly: false,
    },
    revision: groupProjection.model.revision,
    readRevision: groupProjection.model.readRevision,
    pendingOperationIds: groupProjection.model.pendingOperationIds,
    migration: groupProjection.model.migration,
    stale: groupProjection.model.stale,
    authority: AUTHORITY,
    data: { account, group: groupProjection.model },
  }
  return { account, group: groupProjection.model, envelope }
}

export function buildAccountLedgerSummary(
  source: ReadModelAccountSource,
  options: ReadModelBuildOptions = {}
): AccountProjectionResult {
  const groupProjections = source.groups
    .filter((group) => group.localOnly === false)
    .sort((a, b) => (b.updatedAt ?? '').localeCompare(a.updatedAt ?? '') || a.groupId.localeCompare(b.groupId))
    .map((group) => buildGroupLedgerProjection(group, options))
  const groups = groupProjections.map((projection) => {
    const groupSource = source.groups.find((group) => group.groupId === projection.model.groupId)!
    return groupSummary(groupSource, projection.model, projection.readOnly)
  })
  const currencies = new Map<CurrencyKey, Money>()
  const balanceTotals = new Map<CurrencyKey, bigint>()
  for (const projection of groupProjections) {
    for (const money of projection.model.balances.currentAccount.byCurrency) {
      addCurrency(currencies, money)
      const key = currencyKey(money)
      balanceTotals.set(key, (balanceTotals.get(key) ?? 0n) + moneyToBigInt(money))
    }
  }
  const balanceByCurrency = Array.from(currencies.values())
    .sort(sortMoney)
    .map((currency) => exactMoney(balanceTotals.get(currencyKey(currency)) ?? 0n, currency))
  const observedAt = normalizeObservedAt(options.observedAt)
  const readRevision = groupProjections.reduce((max, projection) => Math.max(max, projection.model.readRevision), 0)
  const migration = aggregateMigration([
    ...(source.migration ? [source.migration] : []),
    ...groupProjections.map((projection) => projection.model.migration),
  ])
  const activity: AccountActivityItem[] = []
  for (const projection of groupProjections) {
    const groupSource = source.groups.find((group) => group.groupId === projection.model.groupId)!
    for (const item of projection.model.activity) activity.push({ ...item, groupId: groupSource.groupId, groupName: groupSource.name })
  }
  activity.sort((a, b) => b.at.localeCompare(a.at) || a.groupId.localeCompare(b.groupId) || a.activityId.localeCompare(b.activityId))

  const friends: LedgerFriend[] = (source.friends ?? []).map((friend) => {
    const groupBalances = groupProjections.flatMap((projection) => {
      const member = projection.model.members.find((entry) => entry.accountId === friend.accountId)
      if (!member) return []
      return [{
        groupId: projection.model.groupId,
        memberId: member.memberId,
        byCurrency: projection.model.balances.byMember.find((entry) => entry.memberId === member.memberId)?.byCurrency ?? [],
      }]
    }).sort((a, b) => a.groupId.localeCompare(b.groupId))
    return { ...friend, sharedGroupIds: groupBalances.map((entry) => entry.groupId), groupBalances }
  }).sort((a, b) => a.displayName.localeCompare(b.displayName) || a.accountId.localeCompare(b.accountId))

  const pendingOperationIds = source.pendingOperations
    .filter((operation) => operation.status !== 'applied')
    .map((operation) => operation.operationId)
    .sort((a, b) => a.localeCompare(b))
  const stale = staleState(readRevision, observedAt)
  const summary: AccountLedgerSummary = {
    contractVersion: LEDGER_CONTRACT_VERSION,
    kind: 'account_read',
    accountId: source.accountId,
    readRevision,
    groups,
    balanceByCurrency,
    friends,
    activity,
    pendingOperations: source.pendingOperations,
    pendingOperationIds,
    migration,
    stale,
    authority: AUTHORITY,
    readOnly: groupProjections.some((projection) => projection.readOnly) || migration.status === 'blocked' || migration.status === 'pending' || migration.status === 'in_progress',
  }
  return { summary, groups: groupProjections }
}

export function authorityMarkers(): AuthorityMarkers {
  return AUTHORITY
}

export function readOnlyMigrationState(migrationId: string): MigrationState {
  return {
    status: 'blocked',
    source: 'cloudkit',
    migrationId,
    importedAt: null,
    dualWriteEnabled: false,
    recoveryReadOnly: true,
  }
}
