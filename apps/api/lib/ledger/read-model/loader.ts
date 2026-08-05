import type { Prisma, PrismaClient } from '@prisma/client'
import { getCurrencyExponent, normalizeCurrencyCode } from '../../settlement/money/registry'
import { createMoney } from '../../ledger-contract/money'
import type { CurrencyDescriptor, MigrationState, PendingOperation } from '../../ledger-contract'
import { prisma } from '../../prisma'
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

const userSelect = {
  id: true,
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
  const value = user.name?.trim() || user.preferredName?.trim() || user.email?.trim() || fallback
  return value || fallback
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
      displayName: participant.displayName.trim() || displayName(participant.user, participant.userId),
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
  return {
    expenseId: raw.id,
    description: raw.description,
    paidByMemberId: memberId(raw.paidById, raw.id, 'payer'),
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

function groupSource(
  raw: RawReadModelGroup,
  accountId: string,
  migration: MigrationState,
  migrationIssueIds: string[] = []
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
    pendingOperationIds: [],
    migration,
    migrationIssueIds,
    updatedAt: isoDate(raw.updatedAt),
  }
}

function migrationFromImport(input: {
  id: string
  sourceSystem: string
  state: string
  completedAt: Date | null
} | null): MigrationState {
  if (!input) {
    return {
      status: 'not_required',
      source: 'none',
      migrationId: null,
      importedAt: null,
      dualWriteEnabled: false,
      recoveryReadOnly: false,
    }
  }
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

async function loadMigration(accountId: string, groupIds: string[], db: ReadModelDb): Promise<{
  account: MigrationState
  byGroup: Map<string, MigrationState>
  issueIds: Map<string, string[]>
}> {
  const [latestImport, issues] = await Promise.all([
    db.ledgerImport.findFirst({
      where: { accountId },
      orderBy: [{ createdAt: 'desc' }, { id: 'desc' }],
      select: { id: true, sourceSystem: true, state: true, completedAt: true },
    }),
    groupIds.length === 0
      ? Promise.resolve([])
      : db.moneyMigrationIssue.findMany({
          where: { groupId: { in: groupIds } },
          select: { id: true, groupId: true },
          orderBy: [{ groupId: 'asc' }, { id: 'asc' }],
        }),
  ])
  const accountMigration = migrationFromImport(latestImport)
  const issueIds = new Map<string, string[]>()
  for (const issue of issues) {
    if (!issue.groupId) continue
    const ids = issueIds.get(issue.groupId) ?? []
    ids.push(issue.id)
    issueIds.set(issue.groupId, ids)
  }
  const byGroup = new Map<string, MigrationState>()
  for (const groupId of groupIds) {
    const ids = issueIds.get(groupId) ?? []
    byGroup.set(groupId, ids.length > 0 ? readOnlyMigrationState(`money-migration:${groupId}`) : accountMigration)
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
  const [rawGroups, pendingOperations, friends] = await Promise.all([
    loadRawGroups(accountId, db),
    loadPendingOperations(accountId, db),
    loadFriends(accountId, db),
  ])
  const publicPendingOperations = pendingOperations.map(({ groupId: _groupId, ...operation }) => operation)
  const migration = await loadMigration(accountId, rawGroups.map((group) => group.id), db)
  const groups = rawGroups.map((rawGroup) => {
    const source = groupSource(
      rawGroup,
      accountId,
      migration.byGroup.get(rawGroup.id) ?? migration.account,
      migration.issueIds.get(rawGroup.id) ?? []
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
  const [rawGroups, pendingOperations] = await Promise.all([
    loadRawGroups(accountId, db),
    loadPendingOperations(accountId, db),
  ])
  const publicPendingOperations = pendingOperations.map(({ groupId: _groupId, ...operation }) => operation)
  const rawGroup = rawGroups.find((group) => group.id === groupId)
  if (!rawGroup) throw new LedgerReadModelError('GROUP_NOT_FOUND', 'Group not found', { groupId, notFound: true })
  const migration = await loadMigration(accountId, rawGroups.map((group) => group.id), db)
  const sources = rawGroups.map((group) => groupSource(
    group,
    accountId,
    migration.byGroup.get(group.id) ?? migration.account,
    migration.issueIds.get(group.id) ?? []
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
