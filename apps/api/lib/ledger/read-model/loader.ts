import type { Prisma, PrismaClient } from '@prisma/client'
import { getCurrencyExponent, normalizeCurrencyCode } from '../../settlement/money/registry'
import { createMoney } from '../../ledger-contract/money'
import type { CurrencyDescriptor, LedgerActivityItem, MigrationState, PendingOperation } from '../../ledger-contract'
import { prisma } from '../../prisma'
import { profileDisplayName } from '../../profile-display-name'
import {
  buildAccountLedgerSummary,
  buildGroupLedgerProjection,
  buildGroupLedgerReadEnvelope,
  readOnlyMigrationState,
} from './projection'
import {
  LedgerReadModelError,
  type AccountProjectionResult,
  type GroupLedgerProjection,
  type RawReadModelAllocationPath,
  type RawReadModelExpense,
  type RawReadModelExpenseSplit,
  type RawReadModelFriendship,
  type RawReadModelGroup,
  type RawReadModelTransaction,
  type RawReadModelUser,
  type ReadModelAccountSource,
  type ReadModelBuildOptions,
  type ReadModelExpenseSource,
  type ReadModelFriendSource,
  type ReadModelGroupSource,
  type ReadModelMemberSource,
  type ReadModelSettlementSource,
} from './types'

type ReadModelDb = PrismaClient | Prisma.TransactionClient

type LoadedPendingOperation = PendingOperation & { groupId: string | null }

type RawActivityLog = {
  id: string
  userId: string
  type: string
  description: string
  metadata: Prisma.JsonValue | null
  createdAt: Date
}

const userSelect = {
  id: true,
  username: true,
  name: true,
  preferredName: true,
  email: true,
  externalIdentities: {
    select: { id: true, provider: true, subject: true, metadata: true },
  },
} as const

const groupInclude = {
  members: {
    select: { id: true, userId: true, role: true, user: { select: userSelect } },
    orderBy: { joinedAt: 'asc' },
  },
  participants: {
    select: { id: true, userId: true, displayName: true, status: true, user: { select: userSelect } },
    orderBy: { id: 'asc' },
  },
  expenses: {
    select: {
      id: true,
      description: true,
      paidById: true,
      createdById: true,
      currency: true,
      amountMinorUnits: true,
      currencyExponent: true,
      splitType: true,
      date: true,
      createdAt: true,
      updatedAt: true,
      isDeleted: true,
      splits: {
        select: {
          id: true,
          userId: true,
          amountMinorUnits: true,
          currencyExponent: true,
          percentage: true,
          shares: true,
        },
        orderBy: { id: 'asc' },
      },
    },
    orderBy: [{ date: 'asc' }, { id: 'asc' }],
  },
  transactions: {
    select: {
      id: true,
      senderId: true,
      receiverId: true,
      currency: true,
      amountMinorUnits: true,
      currencyExponent: true,
      payerParticipantId: true,
      recipientParticipantId: true,
      actorUserId: true,
      createdAt: true,
      allocation: {
        select: {
          paths: {
            select: {
              payerParticipantId: true,
              recipientParticipantId: true,
              flowMinorUnits: true,
              obligationComponentKey: true,
            },
            orderBy: { sequence: 'asc' },
          },
        },
      },
      reversal: { select: { id: true, actorUserId: true, createdAt: true } },
    },
    orderBy: [{ createdAt: 'asc' }, { id: 'asc' }],
  },
} satisfies Prisma.GroupInclude

function isoDate(value: Date): string {
  return value.toISOString()
}

function exactMoneyFromDatabase(
  minorUnits: bigint | null,
  currencyExponent: number | null,
  currencyCode: string,
  groupId: string,
  recordId: string
) {
  if (minorUnits === null || currencyExponent === null) {
    throw new LedgerReadModelError(
      'MONEY_REPRESENTATION_UNAVAILABLE',
      `Exact money is unavailable for ${recordId}`,
      { groupId, recordId, currencyCode }
    )
  }
  try {
    return createMoney(minorUnits, normalizeCurrencyCode(currencyCode), currencyExponent)
  } catch (error) {
    throw new LedgerReadModelError(
      'MONEY_REPRESENTATION_UNAVAILABLE',
      `Exact money is invalid for ${recordId}`,
      { groupId, recordId, currencyCode, cause: error instanceof Error ? error.message : String(error) }
    )
  }
}

function exactBaseCurrency(currencyCode: string, groupId: string): CurrencyDescriptor {
  const normalized = normalizeCurrencyCode(currencyCode)
  const exponent = getCurrencyExponent(normalized)
  if (exponent === null) {
    throw new LedgerReadModelError(
      'UNSUPPORTED_CURRENCY',
      `Unsupported group currency ${normalized}`,
      { groupId, currencyCode: normalized }
    )
  }
  return { currencyCode: normalized, currencyExponent: exponent }
}

function displayName(user: RawReadModelUser, fallback: string): string {
  return profileDisplayName(user, fallback)
}

function localIdentityId(user: RawReadModelUser): string | null {
  const candidate = user.externalIdentities?.find((identity) => {
    if (!identity.metadata || typeof identity.metadata !== 'object' || Array.isArray(identity.metadata)) return false
    return typeof (identity.metadata as Record<string, unknown>).localIdentityId === 'string'
  })
  if (!candidate || !candidate.metadata || typeof candidate.metadata !== 'object' || Array.isArray(candidate.metadata)) return null
  const value = (candidate.metadata as Record<string, unknown>).localIdentityId
  return typeof value === 'string' && value.length > 0 ? value : null
}

function status(value: string): 'active' | 'departed' {
  return value === 'DEPARTED' ? 'departed' : 'active'
}

function role(value: string): 'owner' | 'member' {
  return value === 'ADMIN' || value === 'OWNER' ? 'owner' : 'member'
}

function memberSources(raw: RawReadModelGroup): ReadModelMemberSource[] {
  const groupMembers = new Map(raw.members.map((member) => [member.userId, member]))
  const members = new Map<string, ReadModelMemberSource>()
  for (const participant of raw.participants) {
    const groupMember = groupMembers.get(participant.userId)
    members.set(participant.id, {
      memberId: participant.id,
      accountId: participant.userId,
      localIdentityId: localIdentityId(participant.user),
      displayName: displayName(
        participant.user,
        participant.displayName.trim() || participant.userId
      ),
      email: participant.user.email,
      role: groupMember ? role(groupMember.role) : 'member',
      status: status(participant.status),
    })
  }

  if (members.size === 0) {
    for (const groupMember of raw.members) {
      members.set(groupMember.id, {
        memberId: groupMember.id,
        accountId: groupMember.userId,
        localIdentityId: localIdentityId(groupMember.user),
        displayName: displayName(groupMember.user, groupMember.userId),
        email: groupMember.user.email,
        role: role(groupMember.role),
        status: 'active',
      })
    }
  }
  return Array.from(members.values()).sort((a, b) => a.memberId.localeCompare(b.memberId))
}

function expenseSource(
  raw: RawReadModelExpense,
  groupId: string,
  participants: Map<string, string>
): ReadModelExpenseSource {
  const amount = exactMoneyFromDatabase(raw.amountMinorUnits, raw.currencyExponent, raw.currency, groupId, raw.id)
  const splits: RawReadModelExpenseSplit[] = raw.splits
  const memberId = (userId: string, recordId: string, role: string): string => {
    const participantId = participants.get(userId)
    if (!participantId) {
      throw new LedgerReadModelError(
        'INVALID_LEDGER_RECORD',
        `Expense ${recordId} ${role} user ${userId} is missing a participant identity`,
        { groupId, recordId, userId }
      )
    }
    return participantId
  }
  const paidByMemberId = memberId(raw.paidById, raw.id, 'payer')
  return {
    expenseId: raw.id,
    description: raw.description,
    paidByMemberId,
    createdByMemberId: raw.createdById
      ? participants.get(raw.createdById) ?? paidByMemberId
      : paidByMemberId,
    amount,
    splitMethod: raw.splitType as ReadModelExpenseSource['splitMethod'],
    splits: splits.map((split) => ({
      splitId: split.id,
      memberId: memberId(split.userId, `${raw.id}:${split.id}`, 'split'),
      amount: exactMoneyFromDatabase(split.amountMinorUnits, split.currencyExponent, raw.currency, groupId, split.id),
      percentage: split.percentage === null ? null : String(split.percentage),
      shares: split.shares,
    })),
    status: raw.isDeleted ? 'voided' : 'active',
    createdAt: isoDate(raw.date),
    updatedAt: isoDate(raw.updatedAt),
  }
}

function participantByUser(raw: RawReadModelGroup): Map<string, string> {
  const map = new Map(raw.participants.map((participant) => [participant.userId, participant.id]))
  if (map.size > 0) return map
  return new Map(raw.members.map((member) => [member.userId, member.id]))
}

function settlementSource(raw: RawReadModelTransaction, group: RawReadModelGroup): ReadModelSettlementSource {
  const participants = participantByUser(group)
  const payerMemberId = raw.payerParticipantId ?? participants.get(raw.senderId)
  const recipientMemberId = raw.recipientParticipantId ?? participants.get(raw.receiverId)
  if (!payerMemberId || !recipientMemberId) {
    throw new LedgerReadModelError(
      'INVALID_LEDGER_RECORD',
      `Settlement ${raw.id} is missing participant identities`,
      { groupId: group.id, settlementId: raw.id }
    )
  }
  const actorMemberId = (raw.actorUserId ? participants.get(raw.actorUserId) : undefined) ?? payerMemberId
  const amount = exactMoneyFromDatabase(raw.amountMinorUnits, raw.currencyExponent, raw.currency, group.id, raw.id)
  const allocationPaths: RawReadModelAllocationPath[] = raw.allocation?.paths ?? []
  return {
    settlementId: raw.id,
    payerMemberId,
    recipientMemberId,
    amount,
    actorMemberId,
    createdAt: isoDate(raw.createdAt),
    reversed: raw.reversal !== null,
    reversal: raw.reversal
      ? {
          reversalId: raw.reversal.id,
          actorMemberId: (raw.reversal.actorUserId ? participants.get(raw.reversal.actorUserId) : undefined) ?? actorMemberId,
          createdAt: isoDate(raw.reversal.createdAt),
        }
      : null,
    allocationPaths: allocationPaths.map((path) => ({
      payerMemberId: path.payerParticipantId,
      recipientMemberId: path.recipientParticipantId,
      amount: createMoney(path.flowMinorUnits, amount.currencyCode, amount.currencyExponent),
      obligationComponentIds: path.obligationComponentKey.split(',').filter(Boolean),
    })),
  }
}

function metadataRecord(value: Prisma.JsonValue | null): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {}
}

function metadataText(metadata: Record<string, unknown>, key: string): string | undefined {
  const value = metadata[key]
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : undefined
}

function activityMoney(
  metadata: Record<string, unknown>,
  raw: RawReadModelGroup,
  baseCurrency: CurrencyDescriptor,
  referenceId?: string
) {
  const value = metadata.amount
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    const money = value as Record<string, unknown>
    if (
      typeof money.minorUnits === 'string' &&
      typeof money.currencyCode === 'string' &&
      typeof money.currencyExponent === 'number'
    ) {
      try {
        return createMoney(money.minorUnits, money.currencyCode, money.currencyExponent)
      } catch {
        // A malformed narrative record must not make the financial read model unavailable.
      }
    }
  }
  const expense = referenceId ? raw.expenses.find((entry) => entry.id === referenceId) : undefined
  if (expense && expense.amountMinorUnits !== null && expense.currencyExponent !== null) {
    return createMoney(expense.amountMinorUnits, expense.currency, expense.currencyExponent)
  }
  const settlement = referenceId ? raw.transactions.find((entry) => entry.id === referenceId) : undefined
  if (settlement && settlement.amountMinorUnits !== null && settlement.currencyExponent !== null) {
    return createMoney(settlement.amountMinorUnits, settlement.currency, settlement.currencyExponent)
  }
  return createMoney('0', baseCurrency.currencyCode, baseCurrency.currencyExponent)
}

function activitySource(
  rawActivity: RawActivityLog,
  raw: RawReadModelGroup,
  baseCurrency: CurrencyDescriptor
): LedgerActivityItem | null {
  const metadata = metadataRecord(rawActivity.metadata)
  const participants = participantByUser(raw)
  const actorMemberId = participants.get(rawActivity.userId)
  const action = metadataText(metadata, 'action')
  const expenseId = metadataText(metadata, 'expenseId') ?? metadataText(metadata, 'referenceId')
  const settlementId = metadataText(metadata, 'settlementId') ?? metadataText(metadata, 'referenceId')
  const at = rawActivity.createdAt.toISOString()

  if (rawActivity.type === 'EXPENSE_CREATED' || rawActivity.type === 'EXPENSE_UPDATED' || rawActivity.type === 'EXPENSE_DELETED') {
    if (!expenseId) return null
    const expenseAction = rawActivity.type === 'EXPENSE_UPDATED'
      ? 'updated'
      : rawActivity.type === 'EXPENSE_DELETED' ? 'deleted' : 'created'
    const currentExpense = raw.expenses.find((expense) => expense.id === expenseId)
    return {
      activityId: rawActivity.id,
      type: 'expense',
      action: expenseAction,
      expenseId,
      description: metadataText(metadata, 'description') ?? currentExpense?.description,
      ...(actorMemberId ? { actorMemberId } : {}),
      amount: activityMoney(metadata, raw, baseCurrency, expenseId),
      at,
    }
  }

  if (rawActivity.type === 'PAYMENT_MADE') {
    if (!settlementId) return null
    const transaction = raw.transactions.find((entry) => entry.id === settlementId)
    const payerMemberId = metadataText(metadata, 'payerMemberId') ?? transaction?.payerParticipantId ?? undefined
    const recipientMemberId = metadataText(metadata, 'recipientMemberId') ?? transaction?.recipientParticipantId ?? undefined
    if (action === 'reversed') {
      const reversalId = metadataText(metadata, 'reversalId') ?? metadataText(metadata, 'referenceId')
      if (!reversalId) return null
      return {
        activityId: rawActivity.id,
        type: 'reversal',
        reversalId,
        settlementId,
        ...(actorMemberId ? { actorMemberId } : {}),
        ...(payerMemberId ? { payerMemberId } : {}),
        ...(recipientMemberId ? { recipientMemberId } : {}),
        amount: activityMoney(metadata, raw, baseCurrency, settlementId),
        at,
      }
    }
    return {
      activityId: rawActivity.id,
      type: 'settlement',
      settlementId,
      ...(actorMemberId ? { actorMemberId } : {}),
      ...(payerMemberId ? { payerMemberId } : {}),
      ...(recipientMemberId ? { recipientMemberId } : {}),
      amount: activityMoney(metadata, raw, baseCurrency, settlementId),
      at,
    }
  }

  if (rawActivity.type === 'GROUP_CREATED') {
    return {
      activityId: rawActivity.id,
      type: 'group',
      action: 'created',
      ...(actorMemberId ? { actorMemberId } : {}),
      amount: createMoney('0', baseCurrency.currencyCode, baseCurrency.currencyExponent),
      at,
    }
  }

  if (rawActivity.type === 'GROUP_JOINED') {
    const membershipAction = action === 'removed' || action === 'updated' ? action : 'added'
    const targetAccountId = metadataText(metadata, 'targetAccountId')
    const targetMemberId = (targetAccountId ? participants.get(targetAccountId) : undefined)
      ?? metadataText(metadata, 'memberId')
    return {
      activityId: rawActivity.id,
      type: 'membership',
      action: membershipAction,
      ...(actorMemberId ? { actorMemberId } : {}),
      ...(targetMemberId ? { targetMemberId } : {}),
      amount: createMoney('0', baseCurrency.currencyCode, baseCurrency.currencyExponent),
      at,
    }
  }

  return null
}

function groupSource(
  raw: RawReadModelGroup,
  accountId: string,
  migration: MigrationState,
  migrationIssueIds: string[] = [],
  activityLogs: RawActivityLog[] = []
): ReadModelGroupSource {
  const baseCurrency = exactBaseCurrency(raw.currency, raw.id)
  const participants = participantByUser(raw)
  return {
    groupId: raw.id,
    accountId,
    name: raw.name,
    baseCurrency,
    revision: raw.settlementVersion,
    simplifyDebts: raw.simplifyDebts,
    localOnly: false,
    members: memberSources(raw),
    expenses: raw.expenses.map((expense) => expenseSource(expense, raw.id, participants)),
    settlements: raw.transactions.map((transaction) => settlementSource(transaction, raw)),
    activities: activityLogs
      .map((activity) => activitySource(activity, raw, baseCurrency))
      .filter((activity): activity is LedgerActivityItem => activity !== null),
    pendingOperationIds: [],
    migration,
    migrationIssueIds,
    updatedAt: isoDate(raw.updatedAt),
  }
}

function notRequiredMigration(): MigrationState {
  return {
    status: 'not_required',
    source: 'none',
    migrationId: null,
    importedAt: null,
    dualWriteEnabled: false,
    recoveryReadOnly: false,
  }
}

function migrationFromImport(input: {
  id: string
  sourceSystem: string
  state: string
  completedAt: Date | null
} | null): MigrationState {
  if (!input) return notRequiredMigration()
  const source = input.sourceSystem.toLowerCase() === 'cloudkit' ? 'cloudkit' : 'none'
  if (input.state === 'COMPLETED') {
    return {
      status: 'complete',
      source,
      migrationId: input.id,
      importedAt: input.completedAt?.toISOString() ?? null,
      dualWriteEnabled: false,
      recoveryReadOnly: source === 'cloudkit',
    }
  }
  if (input.state === 'RUNNING') {
    return {
      status: 'in_progress',
      source,
      migrationId: input.id,
      importedAt: null,
      dualWriteEnabled: false,
      recoveryReadOnly: true,
    }
  }
  if (input.state === 'FAILED') {
    return {
      status: 'blocked',
      source,
      migrationId: input.id,
      importedAt: null,
      dualWriteEnabled: false,
      recoveryReadOnly: true,
    }
  }
  return {
    status: 'pending',
    source,
    migrationId: input.id,
    importedAt: null,
    dualWriteEnabled: false,
    recoveryReadOnly: true,
  }
}

function pendingOperation(raw: {
  id: string
  groupId: string | null
  operationKey: string
  requestHash: string
  expectedRevision: number | null
  state: string
  createdAt: Date
}): LoadedPendingOperation {
  const status: PendingOperation['status'] =
    raw.state === 'FAILED' ? 'failed' : raw.state === 'COMMITTED' ? 'applied' : 'queued'
  return {
    operationId: raw.id,
    groupId: raw.groupId,
    idempotencyKey: raw.operationKey,
    kind: raw.operationKey.split(':')[0] || 'ledger.operation',
    expectedRevision: raw.expectedRevision ?? 0,
    status,
    createdAt: raw.createdAt.toISOString(),
    requestHash: raw.requestHash,
  }
}

function friendshipSource(raw: RawReadModelFriendship, accountId: string): ReadModelFriendSource {
  const other = raw.fromId === accountId ? raw.to : raw.from
  return {
    friendId: raw.id,
    accountId: other.id,
    displayName: displayName(other, other.id),
    email: other.email,
    createdAt: raw.createdAt.toISOString(),
    status: 'accepted',
  }
}

async function loadRawGroups(accountId: string, db: ReadModelDb): Promise<RawReadModelGroup[]> {
  return db.group.findMany({
    where: { members: { some: { userId: accountId } }, isArchived: false },
    include: groupInclude,
    orderBy: [{ updatedAt: 'desc' }, { id: 'asc' }],
  }) as unknown as Promise<RawReadModelGroup[]>
}

async function loadActivityLogs(groupIds: string[], db: ReadModelDb): Promise<Map<string, RawActivityLog[]>> {
  const byGroup = new Map<string, RawActivityLog[]>()
  if (groupIds.length === 0) return byGroup
  const operations = await db.ledgerOperation.findMany({
    where: { groupId: { in: groupIds }, state: 'COMMITTED' },
    select: { groupId: true, operationKey: true },
  })
  const groupByOperation = new Map(
    operations.flatMap((operation) => operation.groupId
      ? [[operation.operationKey, operation.groupId] as const]
      : [])
  )
  const logs = await db.activityLog.findMany({
    where: {
      OR: [
        ...groupIds.map((groupId) => ({
          metadata: { path: ['groupId'], equals: groupId },
        })),
        ...Array.from(groupByOperation.keys()).map((operationId) => ({
          metadata: { path: ['operationId'], equals: operationId },
        })),
      ],
    },
    select: {
      id: true,
      userId: true,
      type: true,
      description: true,
      metadata: true,
      createdAt: true,
    },
    orderBy: [{ createdAt: 'asc' }, { id: 'asc' }],
  }) as RawActivityLog[]
  for (const log of logs) {
    const metadata = metadataRecord(log.metadata)
    const groupId = metadataText(metadata, 'groupId')
      ?? groupByOperation.get(metadataText(metadata, 'operationId') ?? '')
    if (!groupId || !groupIds.includes(groupId)) continue
    const groupLogs = byGroup.get(groupId) ?? []
    groupLogs.push(log)
    byGroup.set(groupId, groupLogs)
  }
  return byGroup
}

async function loadMigration(accountId: string, groupIds: string[], db: ReadModelDb): Promise<{
  account: MigrationState
  byGroup: Map<string, MigrationState>
  issueIds: Map<string, string[]>
}> {
  const [groupImportRecords, issues] = await Promise.all([
    groupIds.length === 0
      ? Promise.resolve([])
      : db.ledgerImportRecord.findMany({
          where: {
            accountId,
            targetType: 'group',
            targetId: { in: groupIds },
          },
          orderBy: [{ createdAt: 'desc' }, { id: 'desc' }],
          select: {
            targetId: true,
            ledgerImport: {
              select: {
                id: true,
                sourceSystem: true,
                state: true,
                completedAt: true,
              },
            },
          },
        }),
    groupIds.length === 0
      ? Promise.resolve([])
      : db.moneyMigrationIssue.findMany({
          where: { groupId: { in: groupIds } },
          select: { id: true, groupId: true },
          orderBy: [{ groupId: 'asc' }, { id: 'asc' }],
        }),
  ])
  const accountMigration = notRequiredMigration()
  const issueIds = new Map<string, string[]>()
  for (const issue of issues) {
    if (!issue.groupId) continue
    const ids = issueIds.get(issue.groupId) ?? []
    ids.push(issue.id)
    issueIds.set(issue.groupId, ids)
  }
  const importByGroup = new Map<string, (typeof groupImportRecords)[number]['ledgerImport']>()
  for (const record of groupImportRecords) {
    if (record.targetId && !importByGroup.has(record.targetId)) {
      importByGroup.set(record.targetId, record.ledgerImport)
    }
  }
  const byGroup = new Map<string, MigrationState>()
  for (const groupId of groupIds) {
    const ids = issueIds.get(groupId) ?? []
    byGroup.set(
      groupId,
      ids.length > 0
        ? readOnlyMigrationState(`money-migration:${groupId}`)
        : migrationFromImport(importByGroup.get(groupId) ?? null)
    )
  }
  return { account: accountMigration, byGroup, issueIds }
}

async function loadPendingOperations(accountId: string, db: ReadModelDb): Promise<LoadedPendingOperation[]> {
  const operations = await db.ledgerOperation.findMany({
    where: { accountId, state: { not: 'COMMITTED' } },
    orderBy: [{ createdAt: 'asc' }, { id: 'asc' }],
    select: {
      id: true,
      groupId: true,
      operationKey: true,
      requestHash: true,
      expectedRevision: true,
      state: true,
      createdAt: true,
    },
  })
  return operations.map(pendingOperation)
}

async function loadFriends(accountId: string, db: ReadModelDb): Promise<ReadModelFriendSource[]> {
  const friendships = await db.friendship.findMany({
    where: {
      status: 'ACCEPTED',
      OR: [{ fromId: accountId }, { toId: accountId }],
    },
    include: {
      from: { select: userSelect },
      to: { select: userSelect },
    },
    orderBy: [{ createdAt: 'asc' }, { id: 'asc' }],
  }) as unknown as RawReadModelFriendship[]
  return friendships.map((friendship) => friendshipSource(friendship, accountId))
}

export async function loadAccountReadModel(
  accountId: string,
  options: ReadModelBuildOptions = {},
  db: ReadModelDb = prisma
): Promise<AccountProjectionResult> {
  const rawGroups = await loadRawGroups(accountId, db)
  const groupIds = rawGroups.map((group) => group.id)
  const [pendingOperations, friends, activityLogs, migration] = await Promise.all([
    loadPendingOperations(accountId, db),
    loadFriends(accountId, db),
    loadActivityLogs(groupIds, db),
    loadMigration(accountId, groupIds, db),
  ])
  const publicPendingOperations = pendingOperations.map(({ groupId: _groupId, ...operation }) => operation)
  const groups = rawGroups.map((rawGroup) => {
    const source = groupSource(
      rawGroup,
      accountId,
      migration.byGroup.get(rawGroup.id) ?? migration.account,
      migration.issueIds.get(rawGroup.id) ?? [],
      activityLogs.get(rawGroup.id) ?? []
    )
    source.pendingOperationIds = pendingOperations
      .filter((operation) => operation.groupId === rawGroup.id && operation.operationId.length > 0)
      .map((operation) => operation.operationId)
    return source
  })
  const readOptions = { ...options, observedAt: options.observedAt ?? new Date() }
  return buildAccountLedgerSummary({ accountId, groups, friends, pendingOperations: publicPendingOperations, migration: migration.account }, readOptions)
}

export async function loadGroupReadModel(
  groupId: string,
  accountId: string,
  options: ReadModelBuildOptions = {},
  db: ReadModelDb = prisma
) {
  const membership = await db.groupMember.findUnique({
    where: { groupId_userId: { groupId, userId: accountId } },
    select: { userId: true },
  })
  if (!membership) {
    throw new LedgerReadModelError('GROUP_NOT_FOUND', 'Forbidden', { groupId, forbidden: true })
  }
  const rawGroups = await loadRawGroups(accountId, db)
  const groupIds = rawGroups.map((group) => group.id)
  const [pendingOperations, activityLogs, migration] = await Promise.all([
    loadPendingOperations(accountId, db),
    loadActivityLogs(groupIds, db),
    loadMigration(accountId, groupIds, db),
  ])
  const publicPendingOperations = pendingOperations.map(({ groupId: _groupId, ...operation }) => operation)
  const rawGroup = rawGroups.find((group) => group.id === groupId)
  if (!rawGroup) throw new LedgerReadModelError('GROUP_NOT_FOUND', 'Group not found', { groupId, notFound: true })
  const sources = rawGroups.map((group) => groupSource(
    group,
    accountId,
    migration.byGroup.get(group.id) ?? migration.account,
    migration.issueIds.get(group.id) ?? [],
    activityLogs.get(group.id) ?? []
  ))
  for (const source of sources) {
    source.pendingOperationIds = pendingOperations
      .filter((operation) => operation.groupId === source.groupId)
      .map((operation) => operation.operationId)
  }
  const source = sources.find((entry) => entry.groupId === groupId)!
  const readOptions = { ...options, observedAt: options.observedAt ?? new Date() }
  return buildGroupLedgerReadEnvelope(source, sources, publicPendingOperations, readOptions)
}

export async function loadGroupProjection(
  groupId: string,
  accountId: string,
  options: ReadModelBuildOptions = {},
  db: ReadModelDb = prisma
): Promise<GroupLedgerProjection> {
  const result = await loadGroupReadModel(groupId, accountId, options, db)
  return { model: result.group, readOnly: result.group.migration.status !== 'complete' && result.group.migration.status !== 'not_required' }
}
