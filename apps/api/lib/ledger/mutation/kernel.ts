import { randomUUID } from 'node:crypto'
import type { Prisma, PrismaClient } from '@prisma/client'
import { LedgerMoneyError } from '../../ledger-contract/money'
import { prisma } from '../../prisma'
import { parseMutationMoney, exactMoneyFields, legacyMajorUnits, sameMutationMoney, sumMutationMoney, type CanonicalMutationMoney } from './money'
import { conflictReadModel, LedgerMutationError, MutationConflictError } from './errors'
import {
  hashCanonicalRequest,
  hashMutationRequest,
  hashRequest,
  mutationRequestHash,
} from './canonical'
import {
  allocateSettlementPaths,
  buildPlan,
} from '../../settlement/ledger/projections'
import type { GroupLedgerInput, SettlementRecord } from '../../settlement/ledger/types'
import type {
  ExpenseMutationInput,
  ExpenseSplitMutationInput,
  LedgerMutationRequest,
  LedgerMutationResult,
  MembershipMutationInput,
  MutationKind,
  MutationPayload,
  MutationReadModelHint,
  MutationResult,
  MutationTransaction,
  PreparedMutation,
  ReversalMutationInput,
  SettingsMutationInput,
  SettlementMutationInput,
} from './types'

type GroupSnapshot = {
  id: string
  settlementVersion: number
  simplifyDebts: boolean
  isArchived: boolean
  finalizedAt: Date | null
  currency?: string
}

type NormalizedRequest = {
  groupId: string
  operationId: string
  accountId: string
  actorUserId: string
  expectedRevision: number
  kind: CanonicalMutationKind
  payload: MutationPayload
  requestHash: string
}

type CanonicalMutationKind =
  | 'expense.create'
  | 'expense.edit'
  | 'expense.delete'
  | 'membership.add'
  | 'membership.remove'
  | 'membership.update'
  | 'settlement.create'
  | 'settlement.reverse'
  | 'settings.update'

type MutationKernelOptions = {
  db?: PrismaClient
  now?: () => Date
  maxRetries?: number
  retentionDays?: number
}

type LedgerOperationRow = {
  id: string
  groupId: string | null
  requestHash: string
  state: string
  resultRevision: number | null
  resultRecordId: string | null
  createdAt?: Date
  failureCode?: string | null
}

const DEFAULT_RETENTION_DAYS = 30

const EVENT_TYPES: Record<CanonicalMutationKind, string> = {
  'expense.create': 'expense_created',
  'expense.edit': 'expense_updated',
  'expense.delete': 'expense_deleted',
  'membership.add': 'membership_changed',
  'membership.remove': 'membership_changed',
  'membership.update': 'membership_changed',
  'settlement.create': 'settlement_created',
  'settlement.reverse': 'settlement_reversed',
  'settings.update': 'setting_changed',
}

const TRANSIENT_ERROR_CODES = new Set(['P2034', '40P01', '40001'])

function asRecord(value: unknown, field: string): Record<string, unknown> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new LedgerMutationError('INVALID_MUTATION', 400, `${field} must be an object`)
  }
  return value as Record<string, unknown>
}

function requiredString(value: unknown, field: string): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new LedgerMutationError('INVALID_MUTATION', 400, `${field} is required`)
  }
  return value
}

function optionalString(value: unknown, field: string): string | undefined {
  if (value === undefined || value === null) return undefined
  return requiredString(value, field)
}

function normalizeRevision(request: LedgerMutationRequest): number {
  const raw =
    (request.expectedRevision ?? request.expectedGroupRevision ?? request.expectedVersion) as
      | number
      | string
      | undefined
  const revision = typeof raw === 'string' ? Number(raw) : raw
  if (typeof revision !== 'number' || !Number.isInteger(revision) || revision < 0) {
    throw new LedgerMutationError(
      'INVALID_MUTATION',
      400,
      'expectedRevision is required and must be a non-negative integer'
    )
  }
  return revision
}

function canonicalKind(value: unknown): CanonicalMutationKind {
  const aliases: Record<string, CanonicalMutationKind> = {
    'expense.create': 'expense.create',
    'expense.edit': 'expense.edit',
    'expense.update': 'expense.edit',
    'expense.delete': 'expense.delete',
    'membership.add': 'membership.add',
    'membership.remove': 'membership.remove',
    'membership.update': 'membership.update',
    'membership.change': 'membership.update',
    'settlement.create': 'settlement.create',
    'settlement.settle': 'settlement.create',
    'settlement.reverse': 'settlement.reverse',
    'reversal.create': 'settlement.reverse',
    'settings.update': 'settings.update',
    'setting.update': 'settings.update',
  }
  const kind = typeof value === 'string' ? aliases[value] : undefined
  if (!kind) throw new LedgerMutationError('INVALID_MUTATION', 400, 'Unsupported mutation kind')
  return kind
}

function normalizeRequest(request: LedgerMutationRequest): NormalizedRequest {
  const groupId = requiredString(request.groupId, 'groupId')
  const operationId = requiredString(request.operationId, 'operationId')
  const accountId = requiredString(
    request.accountId ?? request.actorUserId ?? request.userId ?? request.actorId,
    'accountId/actorUserId'
  )
  const actorUserId = requiredString(
    request.actorUserId ?? request.userId ?? request.actorId ?? request.accountId,
    'actorUserId'
  )
  const kind = canonicalKind(request.kind ?? request.mutationType)
  const payload = (request.payload ?? request.body ?? request.input) as MutationPayload | undefined
  if (!payload) throw new LedgerMutationError('INVALID_MUTATION', 400, 'payload is required')

  const expectedRevision = normalizeRevision(request)
  return {
    groupId,
    operationId,
    accountId,
    actorUserId,
    expectedRevision,
    kind,
    payload,
    requestHash: mutationRequestHash({ groupId, kind, payload }),
  }
}

function groupReadModel(group: GroupSnapshot): MutationReadModelHint {
  return conflictReadModel({
    groupId: group.id,
    revision: group.settlementVersion,
    simplifyDebts: group.simplifyDebts,
    isArchived: group.isArchived,
    finalizedAt: group.finalizedAt,
  })
}

function revisionConflict(
  request: NormalizedRequest,
  group: GroupSnapshot,
  message?: string
): MutationConflictError {
  const readModel = groupReadModel(group)
  return new MutationConflictError(
    'REVISION_CONFLICT',
    {
      groupId: request.groupId,
      operationId: request.operationId,
      expectedRevision: request.expectedRevision,
      currentRevision: group.settlementVersion,
      currentVersion: group.settlementVersion,
      retryable: true,
      serverAuthoritative: true,
      readModel,
      currentReadModel: readModel,
    },
    message
  )
}

async function readGroup(tx: MutationTransaction, groupId: string): Promise<GroupSnapshot> {
  const group = await tx.group.findUnique({
    where: { id: groupId },
    select: {
      id: true,
      settlementVersion: true,
      simplifyDebts: true,
      isArchived: true,
      finalizedAt: true,
      currency: true,
    },
  })
  if (!group) throw new LedgerMutationError('GROUP_NOT_FOUND', 404, 'Group not found')
  return group as GroupSnapshot
}

function assertExpectedRevision(request: NormalizedRequest, group: GroupSnapshot): void {
  if (group.settlementVersion !== request.expectedRevision) {
    throw revisionConflict(request, group)
  }
  if (group.isArchived) throw new LedgerMutationError('GROUP_ARCHIVED', 403, 'Group is archived')
}

async function ensureActiveMember(
  tx: MutationTransaction,
  request: NormalizedRequest,
  requireAdmin = false
): Promise<{ id: string; role: 'ADMIN' | 'MEMBER'; userId: string }> {
  const member = await tx.groupMember.findUnique({
    where: { groupId_userId: { groupId: request.groupId, userId: request.actorUserId } },
    select: { id: true, role: true, userId: true },
  })
  if (!member) throw new LedgerMutationError('FORBIDDEN', 403, 'Actor is not a group member')
  if (requireAdmin && member.role !== 'ADMIN') {
    throw new LedgerMutationError('FORBIDDEN', 403, 'An administrator is required')
  }
  return member as { id: string; role: 'ADMIN' | 'MEMBER'; userId: string }
}

function assertNotFinalized(group: GroupSnapshot): void {
  if (group.finalizedAt) {
    throw new LedgerMutationError('GROUP_FINALIZED', 409, 'Group is finalized')
  }
}

async function upsertOperation(
  tx: MutationTransaction,
  request: NormalizedRequest
): Promise<LedgerOperationRow> {
  const operation = await tx.ledgerOperation.upsert({
    where: {
      accountId_operationKey: {
        accountId: request.accountId,
        operationKey: request.operationId,
      },
    },
    create: {
      id: randomUUID(),
      accountId: request.accountId,
      groupId: request.groupId,
      operationKey: request.operationId,
      requestHash: request.requestHash,
      expectedRevision: request.expectedRevision,
      state: 'PENDING',
    },
    update: {},
  })
  return operation as LedgerOperationRow
}

async function idempotencyConflict(
  tx: MutationTransaction,
  request: NormalizedRequest,
  operation: LedgerOperationRow
): Promise<MutationConflictError> {
  const group = await readGroup(tx, request.groupId)
  const readModel = groupReadModel(group)
  return new MutationConflictError('IDEMPOTENCY_KEY_REUSED', {
    groupId: request.groupId,
    operationId: request.operationId,
    expectedRevision: request.expectedRevision,
    currentRevision: group.settlementVersion,
    currentVersion: group.settlementVersion,
    retryable: false,
    serverAuthoritative: true,
    readModel,
    currentReadModel: readModel,
    expectedRequestHash: request.requestHash,
    existingRequestHash: operation.requestHash,
  })
}

function eventTypeFor(kind: CanonicalMutationKind, recordId: string): string {
  if (kind === 'settings.update' && recordId.length === 0) return 'setting_noop'
  return EVENT_TYPES[kind]
}

function resultFromOperation(
  request: NormalizedRequest,
  operation: LedgerOperationRow,
  now: Date,
  retentionDays: number
): LedgerMutationResult {
  const revision = operation.resultRevision
  if (revision === null || revision === undefined) {
    throw new LedgerMutationError('MUTATION_IN_PROGRESS', 409, 'The operation has not committed yet')
  }
  const recordId = operation.resultRecordId ?? ''
  const eventType = eventTypeFor(request.kind, recordId)
  return buildResult({
    request,
    outcome: 'replayed',
    revision,
    recordId,
    eventType,
    now: operation.createdAt ?? now,
    retentionDays,
    noop: eventType === 'setting_noop',
  })
}

function buildResult(input: {
  request: NormalizedRequest
  outcome: 'applied' | 'replayed'
  revision: number
  recordId: string
  eventType: string
  now: Date
  retentionDays: number
  noop?: boolean
  metadata?: Record<string, unknown>
}): LedgerMutationResult {
  const retainedUntil = new Date(
    input.now.getTime() + input.retentionDays * 24 * 60 * 60 * 1000
  ).toISOString()
  const result: MutationResult = {
    recordId: input.recordId,
    eventType: input.eventType,
    ...(input.metadata ? { metadata: input.metadata } : {}),
  }
  return {
    groupId: input.request.groupId,
    operationId: input.request.operationId,
    outcome: input.outcome,
    replayed: input.outcome === 'replayed',
    revision: input.revision,
    readRevision: input.revision,
    currentRevision: input.revision,
    requestHash: input.request.requestHash,
    recordId: input.recordId,
    eventType: input.eventType,
    result,
    idempotency: {
      key: input.request.operationId,
      requestHash: input.request.requestHash,
      replayed: input.outcome === 'replayed',
      resultRevision: input.revision,
      retainedUntil,
    },
    authority: {
      serverAuthoritative: true,
      moneyAuthority: 'minor_units',
      revisionAuthority: 'group',
    },
    ...(input.noop ? { noop: true } : {}),
  }
}

function parseExpenseSplits(value: unknown): Array<{
  input: ExpenseSplitMutationInput
  money: CanonicalMutationMoney
}> {
  if (!Array.isArray(value) || value.length === 0) {
    throw new LedgerMutationError('INVALID_MUTATION', 400, 'splits must contain at least one item')
  }
  return value.map((entry, index) => {
    const split = asRecord(entry, `splits[${index}]`) as unknown as ExpenseSplitMutationInput
    const userId = requiredString(split.userId, `splits[${index}].userId`)
    const money = parseMutationMoney(split.amount, `splits[${index}].amount`)
    if (split.percentage !== undefined && split.percentage !== null) {
      if (typeof split.percentage !== 'number' || !Number.isFinite(split.percentage)) {
        throw new LedgerMutationError('INVALID_MUTATION', 400, `splits[${index}].percentage is invalid`)
      }
    }
    if (split.shares !== undefined && split.shares !== null) {
      if (!Number.isInteger(split.shares) || split.shares < 1) {
        throw new LedgerMutationError('INVALID_MUTATION', 400, `splits[${index}].shares is invalid`)
      }
    }
    return { input: { ...split, userId }, money }
  })
}

function parseDate(value: unknown, field: string, fallback: Date): Date {
  if (value === undefined || value === null) return fallback
  const date = value instanceof Date ? new Date(value.getTime()) : new Date(String(value))
  if (!Number.isFinite(date.getTime())) {
    throw new LedgerMutationError('INVALID_MUTATION', 400, `${field} is invalid`)
  }
  return date
}

function expensePayload(payload: MutationPayload): ExpenseMutationInput {
  return asRecord(payload, 'payload') as unknown as ExpenseMutationInput
}

async function memberIds(
  tx: MutationTransaction,
  groupId: string
): Promise<Set<string>> {
  const members = await tx.groupMember.findMany({
    where: { groupId },
    select: { userId: true },
  })
  return new Set((members as Array<{ userId: string }>).map((member) => member.userId))
}

async function loadMutationLedger(
  groupId: string,
  db: MutationTransaction
): Promise<GroupLedgerInput> {
  const group = await db.group.findUnique({
    where: { id: groupId },
    select: { id: true, settlementVersion: true, simplifyDebts: true },
  })
  if (!group) throw new LedgerMutationError('GROUP_NOT_FOUND', 404, 'Group not found')

  const participants = await db.groupParticipant.findMany({
    where: { groupId },
    select: { id: true, userId: true, displayName: true, status: true },
  })
  const expenses = await db.expense.findMany({
    where: { groupId, isDeleted: false },
    select: {
      id: true,
      paidById: true,
      currency: true,
      amountMinorUnits: true,
      currencyExponent: true,
      splits: {
        select: {
          id: true,
          userId: true,
          amountMinorUnits: true,
          currencyExponent: true,
        },
      },
    },
  })
  const transactions = await db.transaction.findMany({
    where: { groupId },
    include: {
      allocation: { include: { paths: { orderBy: { sequence: 'asc' } } } },
      reversal: true,
    },
    orderBy: { createdAt: 'asc' },
  })

  const settlements: SettlementRecord[] = transactions
    .filter((transaction) => transaction.amountMinorUnits !== null && transaction.currencyExponent !== null)
    .map((transaction) => ({
      id: transaction.id,
      payerParticipantId: transaction.payerParticipantId ?? '',
      recipientParticipantId: transaction.recipientParticipantId ?? '',
      amount: {
        currencyCode: transaction.currency.toUpperCase(),
        currencyExponent: transaction.currencyExponent!,
        minorUnits: transaction.amountMinorUnits!,
      },
      mode: transaction.settlementMode ?? 'SIMPLIFIED',
      createdAt: transaction.createdAt,
      reversed: Boolean(transaction.reversal),
      snapshot: transaction.allocation
        ? {
            settlementVersion: transaction.allocation.settlementVersion,
            mode: transaction.allocation.mode,
            algorithmVersion: transaction.allocation.algorithmVersion,
            amount: {
              currencyCode: transaction.allocation.currencyCode,
              currencyExponent: transaction.allocation.currencyExponent,
              minorUnits: transaction.allocation.amountMinorUnits,
            },
            paths: transaction.allocation.paths.map((path) => ({
              payerParticipantId: path.payerParticipantId,
              recipientParticipantId: path.recipientParticipantId,
              flowMinorUnits: path.flowMinorUnits,
              obligationComponentKeys: [path.obligationComponentKey],
            })),
          }
        : null,
    }))

  return {
    groupId: group.id,
    settlementVersion: group.settlementVersion,
    simplifyDebts: group.simplifyDebts,
    participants: participants.map((participant) => ({
      id: participant.id,
      userId: participant.userId,
      displayName: participant.displayName,
      status: participant.status,
    })),
    expenses: expenses
      .filter((expense) => expense.amountMinorUnits !== null && expense.currencyExponent !== null)
      .map((expense) => ({
        id: expense.id,
        paidByUserId: expense.paidById,
        currency: expense.currency,
        amountMinorUnits: expense.amountMinorUnits!,
        currencyExponent: expense.currencyExponent!,
        splits: expense.splits
          .filter((split) => split.amountMinorUnits !== null && split.currencyExponent !== null)
          .map((split) => ({
            id: split.id,
            userId: split.userId,
            amountMinorUnits: split.amountMinorUnits!,
            currencyExponent: split.currencyExponent!,
          })),
      })),
    settlements,
  }
}

async function prepareExpense(
  tx: MutationTransaction,
  request: NormalizedRequest,
  group: GroupSnapshot,
  now: Date
): Promise<PreparedMutation> {
  const payload = expensePayload(request.payload)
  const expenseId = optionalString(payload.expenseId ?? payload.id, 'expenseId')

  if (request.kind === 'expense.delete') {
    if (!expenseId) throw new LedgerMutationError('INVALID_MUTATION', 400, 'expenseId is required')
    const existing = await tx.expense.findUnique({
      where: { id: expenseId },
      select: { id: true, groupId: true, paidById: true, isDeleted: true },
    })
    if (!existing || existing.groupId !== request.groupId) {
      throw new LedgerMutationError('NOT_FOUND', 404, 'Expense not found')
    }
    if (existing.isDeleted) {
      throw new LedgerMutationError('NOT_FOUND', 404, 'Expense is already deleted')
    }
    if (existing.paidById !== request.actorUserId) {
      throw new LedgerMutationError('FORBIDDEN', 403, 'Only the payer can delete an expense')
    }
    assertNotFinalized(group)
    return {
      kind: 'expense.delete',
      recordId: existing.id,
      eventType: 'expense_deleted',
      data: { id: existing.id },
      existingExpenseId: existing.id,
    }
  }

  const description = requiredString(payload.description, 'description')
  const paidById = requiredString(payload.paidById, 'paidById')
  const amount = parseMutationMoney(payload.amount, 'amount')
  if (payload.currency && payload.currency.trim().toUpperCase() !== amount.currencyCode) {
    throw new LedgerMutationError('INVALID_MONEY', 400, 'currency does not match amount currency')
  }
  if (payload.groupId && payload.groupId !== request.groupId) {
    throw new LedgerMutationError('INVALID_MUTATION', 400, 'Expense groupId cannot change')
  }
  if (group.currency && group.currency.trim().toUpperCase() !== amount.currencyCode) {
    throw new LedgerMutationError('INVALID_MONEY', 400, 'amount currency does not match group currency')
  }
  const splitInputs = parseExpenseSplits(payload.splits)
  const splitMoney = sumMutationMoney(splitInputs.map((split) => split.money))
  if (!splitMoney || !sameMutationMoney(amount, splitMoney)) {
    throw new LedgerMutationError('INVALID_MONEY', 400, 'split amounts must equal expense amount exactly')
  }

  const allMemberIds = await memberIds(tx, request.groupId)
  if (!allMemberIds.has(paidById)) {
    throw new LedgerMutationError('INVALID_MEMBERSHIP', 400, 'Payer is not a group member')
  }
  for (const split of splitInputs) {
    if (!allMemberIds.has(split.input.userId)) {
      throw new LedgerMutationError(
        'INVALID_MEMBERSHIP',
        400,
        `Split user ${split.input.userId} is not a group member`
      )
    }
  }

  if (
    payload.splitType !== undefined &&
    !['EQUAL', 'EXACT', 'PERCENTAGE', 'SHARES'].includes(payload.splitType)
  ) {
    throw new LedgerMutationError('INVALID_MUTATION', 400, 'splitType is invalid')
  }
  const splitData = splitInputs.map(({ input, money }) => ({
    ...(input.id || input.splitId ? { id: input.id ?? input.splitId } : {}),
    userId: input.userId,
    amount: legacyMajorUnits(money),
    amountMinorUnits: money.minorUnits,
    currencyExponent: money.currencyExponent,
    ...(input.percentage !== undefined ? { percentage: input.percentage } : {}),
    ...(input.shares !== undefined ? { shares: input.shares } : {}),
    ...(input.isPaid !== undefined ? { isPaid: input.isPaid } : {}),
  }))
  const date = parseDate(payload.date, 'date', now)
  const recurringEndDate =
    payload.recurringEndDate === undefined || payload.recurringEndDate === null
      ? payload.recurringEndDate ?? null
      : parseDate(payload.recurringEndDate, 'recurringEndDate', now)
  const baseData = {
    description,
    amount: legacyMajorUnits(amount),
    ...exactMoneyFields(amount),
    date,
    category: payload.category ?? 'general',
    groupId: request.groupId,
    paidById,
    splitType: payload.splitType ?? 'EQUAL',
    receiptUrl: payload.receiptUrl ?? null,
    notes: payload.notes ?? null,
    isRecurring: payload.isRecurring ?? false,
    recurringInterval: payload.recurringInterval ?? null,
    recurringEndDate,
  }

  if (request.kind === 'expense.create') {
    assertNotFinalized(group)
    const recordId = expenseId ?? randomUUID()
    return {
      kind: 'expense.create',
      recordId,
      eventType: 'expense_created',
      data: { ...baseData, id: recordId },
      splits: splitData,
    }
  }

  if (!expenseId) throw new LedgerMutationError('INVALID_MUTATION', 400, 'expenseId is required')
  const existing = await tx.expense.findUnique({
    where: { id: expenseId },
    select: { id: true, groupId: true, paidById: true, isDeleted: true },
  })
  if (!existing || existing.groupId !== request.groupId || existing.isDeleted) {
    throw new LedgerMutationError('NOT_FOUND', 404, 'Expense not found')
  }
  if (existing.paidById !== request.actorUserId) {
    throw new LedgerMutationError('FORBIDDEN', 403, 'Only the payer can edit an expense')
  }
  assertNotFinalized(group)
  return {
    kind: 'expense.edit',
    recordId: existing.id,
    eventType: 'expense_updated',
    data: { ...baseData, id: existing.id },
    splits: splitData,
    existingExpenseId: existing.id,
  }
}

function membershipPayload(payload: MutationPayload): MembershipMutationInput {
  return asRecord(payload, 'payload') as unknown as MembershipMutationInput
}

async function prepareMembership(
  tx: MutationTransaction,
  request: NormalizedRequest
): Promise<PreparedMutation> {
  const payload = membershipPayload(request.payload)
  const userId = optionalString(payload.userId, 'userId')
  const memberId = optionalString(payload.memberId ?? payload.membershipId, 'memberId')
  if (request.kind === 'membership.add' && !userId) {
    throw new LedgerMutationError('INVALID_MEMBERSHIP', 400, 'userId is required to add a member')
  }
  if (!userId && !memberId) {
    throw new LedgerMutationError('INVALID_MEMBERSHIP', 400, 'userId or memberId is required')
  }

  const existing = memberId
    ? await tx.groupMember.findUnique({
        where: { id: memberId },
        select: { id: true, groupId: true, userId: true, role: true },
      })
    : await tx.groupMember.findUnique({
        where: { groupId_userId: { groupId: request.groupId, userId: userId! } },
        select: { id: true, groupId: true, userId: true, role: true },
      })

  if (request.kind === 'membership.add') {
    if (existing && existing.groupId === request.groupId) {
      throw new LedgerMutationError('ALREADY_MEMBER', 409, 'User is already a member')
    }
    const user = await tx.user.findUnique({
      where: { id: userId },
      select: { id: true, name: true },
    })
    if (!user) throw new LedgerMutationError('MEMBER_NOT_FOUND', 404, 'User not found')
    if (payload.role !== undefined && payload.role !== 'ADMIN' && payload.role !== 'MEMBER') {
      throw new LedgerMutationError('INVALID_MEMBERSHIP', 400, 'role is invalid')
    }
    const recordId = memberId ?? randomUUID()
    return {
      kind: 'membership.add',
      recordId,
      eventType: 'membership_changed',
      data: {
        id: recordId,
        groupId: request.groupId,
        userId: user.id,
        role: payload.role ?? 'MEMBER',
      },
      participantUserId: user.id,
      participantDisplayName: payload.displayName ?? user.name ?? 'Unknown member',
    }
  }

  if (!existing || existing.groupId !== request.groupId) {
    throw new LedgerMutationError('MEMBER_NOT_FOUND', 404, 'Membership not found')
  }
  if (request.kind === 'membership.remove') {
    return {
      kind: 'membership.remove',
      recordId: existing.id,
      eventType: 'membership_changed',
      data: { id: existing.id, groupId: request.groupId },
      participantUserId: existing.userId,
    }
  }
  if (payload.role !== 'ADMIN' && payload.role !== 'MEMBER') {
    throw new LedgerMutationError('INVALID_MEMBERSHIP', 400, 'role is required')
  }
  return {
    kind: 'membership.update',
    recordId: existing.id,
    eventType: 'membership_changed',
    data: { id: existing.id, role: payload.role },
    participantUserId: existing.userId,
  }
}

function settlementPayload(payload: MutationPayload): SettlementMutationInput {
  return asRecord(payload, 'payload') as unknown as SettlementMutationInput
}

function settlementAmount(payload: SettlementMutationInput): CanonicalMutationMoney {
  if (payload.amount ?? payload.money) {
    return parseMutationMoney(payload.amount ?? payload.money, 'amount')
  }
  if (
    payload.minorUnits === undefined ||
    payload.currencyCode === undefined ||
    payload.currencyExponent === undefined
  ) {
    throw new LedgerMutationError('INVALID_MONEY', 400, 'settlement amount is required')
  }
  return parseMutationMoney(
    {
      minorUnits: payload.minorUnits,
      currencyCode: payload.currencyCode,
      currencyExponent: payload.currencyExponent,
    },
    'amount'
  )
}

async function prepareSettlement(
  tx: MutationTransaction,
  request: NormalizedRequest,
  group: GroupSnapshot
): Promise<PreparedMutation> {
  await ensureActiveMember(tx, request)
  const payload = settlementPayload(request.payload)
  const payerParticipantId = requiredString(payload.payerParticipantId, 'payerParticipantId')
  const recipientParticipantId = requiredString(
    payload.recipientParticipantId,
    'recipientParticipantId'
  )
  if (payerParticipantId === recipientParticipantId) {
    throw new LedgerMutationError('INVALID_SETTLEMENT', 400, 'Settlement endpoints must differ')
  }
  const [payer, recipient] = await Promise.all([
    tx.groupParticipant.findUnique({
      where: { id: payerParticipantId },
      select: { id: true, groupId: true, userId: true, status: true },
    }),
    tx.groupParticipant.findUnique({
      where: { id: recipientParticipantId },
      select: { id: true, groupId: true, userId: true, status: true },
    }),
  ])
  if (!payer || !recipient || payer.groupId !== request.groupId || recipient.groupId !== request.groupId) {
    throw new LedgerMutationError('INVALID_SETTLEMENT', 400, 'Settlement participant is invalid')
  }
  const actorParticipant = await tx.groupParticipant.findUnique({
    where: {
      groupId_userId: {
        groupId: request.groupId,
        userId: request.actorUserId,
      },
    },
    select: { id: true },
  })
  if (
    !actorParticipant ||
    (actorParticipant.id !== payerParticipantId && actorParticipant.id !== recipientParticipantId)
  ) {
    throw new LedgerMutationError('FORBIDDEN', 403, 'Actor is not a settlement participant')
  }

  const amount = settlementAmount(payload)
  if (group.currency && group.currency.trim().toUpperCase() !== amount.currencyCode) {
    throw new LedgerMutationError('INVALID_MONEY', 400, 'Settlement currency does not match group currency')
  }
  const ledger = await loadMutationLedger(request.groupId, tx)
  const transfers = buildPlan(ledger)
  const transfer = payload.planTransferId
    ? transfers.find((entry) => entry.planTransferId === payload.planTransferId)
    : transfers.find(
        (entry) =>
          entry.payerParticipantId === payerParticipantId &&
          entry.recipientParticipantId === recipientParticipantId &&
          sameMutationMoney(entry.amount, amount)
      )
  if (!transfer) {
    throw new LedgerMutationError('TRANSFER_NOT_FOUND', 404, 'Settlement transfer is no longer available')
  }
  if (
    transfer.payerParticipantId !== payerParticipantId ||
    transfer.recipientParticipantId !== recipientParticipantId ||
    !sameMutationMoney(transfer.amount, amount)
  ) {
    throw new LedgerMutationError('TRANSFER_MISMATCH', 409, 'Settlement transfer changed', {
      requiresReconfirmation: true,
    })
  }

  const mode = payload.mode ?? transfer.mode
  const snapshot = allocateSettlementPaths(
    ledger,
    payerParticipantId,
    recipientParticipantId,
    amount,
    mode
  )
  const recordId = payload.settlementId ?? payload.transactionId ?? randomUUID()
  const allocationId = randomUUID()
  return {
    kind: 'settlement.create',
    recordId,
    eventType: 'settlement_created',
    allocationId,
    transactionData: {
      id: recordId,
      senderId: payer.userId,
      receiverId: recipient.userId,
      amount: legacyMajorUnits(amount),
      ...exactMoneyFields(amount),
      note: payload.note ?? null,
      groupId: request.groupId,
      payerParticipantId,
      recipientParticipantId,
      actorUserId: request.actorUserId,
      settlementMode: mode,
      settlementGroupVersion: request.expectedRevision + 1,
    },
    allocationData: {
      id: allocationId,
      groupId: request.groupId,
      transactionId: recordId,
      settlementVersion: request.expectedRevision,
      mode,
      currencyCode: amount.currencyCode,
      currencyExponent: amount.currencyExponent,
      amountMinorUnits: amount.minorUnits,
      paths: {
        create: snapshot.paths.map((path, sequence) => ({
          sequence,
          flowMinorUnits: path.flowMinorUnits,
          obligationComponentKey: path.obligationComponentKeys.join(','),
          payerParticipantId: path.payerParticipantId,
          recipientParticipantId: path.recipientParticipantId,
        })),
      },
    },
  }
}

function reversalPayload(payload: MutationPayload): ReversalMutationInput {
  return asRecord(payload, 'payload') as unknown as ReversalMutationInput
}

async function prepareReversal(
  tx: MutationTransaction,
  request: NormalizedRequest
): Promise<PreparedMutation> {
  await ensureActiveMember(tx, request)
  const payload = reversalPayload(request.payload)
  const settlementId = requiredString(payload.settlementId, 'settlementId')
  const transaction = await tx.transaction.findUnique({
    where: { id: settlementId },
    select: {
      id: true,
      groupId: true,
      payerParticipantId: true,
      recipientParticipantId: true,
      reversal: { select: { id: true } },
    },
  })
  if (!transaction || transaction.groupId !== request.groupId) {
    throw new LedgerMutationError('SETTLEMENT_NOT_FOUND', 404, 'Settlement not found')
  }
  if (transaction.reversal) {
    throw new LedgerMutationError('ALREADY_REVERSED', 409, 'Settlement is already reversed')
  }
  const actorParticipant = await tx.groupParticipant.findUnique({
    where: {
      groupId_userId: {
        groupId: request.groupId,
        userId: request.actorUserId,
      },
    },
    select: { id: true },
  })
  if (
    !actorParticipant ||
    (actorParticipant.id !== transaction.payerParticipantId &&
      actorParticipant.id !== transaction.recipientParticipantId)
  ) {
    throw new LedgerMutationError('FORBIDDEN', 403, 'Actor is not a settlement participant')
  }
  const reversalId = payload.reversalId ?? randomUUID()
  return {
    kind: 'settlement.reverse',
    recordId: reversalId,
    eventType: 'settlement_reversed',
    data: {
      id: reversalId,
      groupId: request.groupId,
      transactionId: transaction.id,
      actorUserId: request.actorUserId,
    },
  }
}

function settingsPayload(payload: MutationPayload): SettingsMutationInput {
  return asRecord(payload, 'payload') as unknown as SettingsMutationInput
}

async function prepareSettings(
  tx: MutationTransaction,
  request: NormalizedRequest,
  group: GroupSnapshot
): Promise<PreparedMutation> {
  await ensureActiveMember(tx, request, true)
  const payload = settingsPayload(request.payload)
  if (typeof payload.simplifyDebts !== 'boolean') {
    throw new LedgerMutationError('INVALID_MUTATION', 400, 'simplifyDebts must be boolean')
  }
  if (payload.simplifyDebts === group.simplifyDebts) {
    return {
      kind: 'settings.update',
      recordId: '',
      eventType: 'setting_noop',
      data: {},
      noop: true,
    }
  }
  const recordId = randomUUID()
  return {
    kind: 'settings.update',
    recordId,
    eventType: 'setting_changed',
    data: {
      id: recordId,
      groupId: request.groupId,
      actorUserId: request.actorUserId,
      simplifyDebts: payload.simplifyDebts,
    },
  }
}

async function prepareMutation(
  tx: MutationTransaction,
  request: NormalizedRequest,
  group: GroupSnapshot,
  now: Date
): Promise<PreparedMutation> {
  switch (request.kind) {
    case 'expense.create':
    case 'expense.edit':
    case 'expense.delete':
      await ensureActiveMember(tx, request)
      return prepareExpense(tx, request, group, now)
    case 'membership.add':
      await ensureActiveMember(tx, request)
      return prepareMembership(tx, request)
    case 'membership.remove':
    case 'membership.update':
      await ensureActiveMember(tx, request, true)
      return prepareMembership(tx, request)
    case 'settlement.create':
      return prepareSettlement(tx, request, group)
    case 'settlement.reverse':
      return prepareReversal(tx, request)
    case 'settings.update':
      return prepareSettings(tx, request, group)
  }
}

async function commitPreparedMutation(
  tx: MutationTransaction,
  prepared: PreparedMutation
): Promise<void> {
  switch (prepared.kind) {
    case 'expense.create':
      await tx.expense.create({
        data: {
          ...prepared.data,
          id: prepared.recordId,
          splits: { create: prepared.splits ?? [] },
        } as unknown as Prisma.ExpenseUncheckedCreateInput,
      })
      return
    case 'expense.edit':
      await tx.expense.update({
        where: { id: prepared.recordId },
        data: {
          ...prepared.data,
          splits: {
            deleteMany: {},
            create: prepared.splits ?? [],
          },
        } as unknown as Prisma.ExpenseUpdateInput,
      })
      return
    case 'expense.delete':
      await tx.expense.update({
        where: { id: prepared.recordId },
        data: { isDeleted: true },
      })
      return
    case 'membership.add': {
      await tx.groupMember.create({
        data: prepared.data as unknown as Prisma.GroupMemberUncheckedCreateInput,
      })
      const participant = await tx.groupParticipant.findUnique({
        where: {
          groupId_userId: {
            groupId: String(prepared.data.groupId),
            userId: prepared.participantUserId,
          },
        },
      })
      if (participant) {
        await tx.groupParticipant.update({
          where: { id: participant.id },
          data: {
            status: 'ACTIVE',
            departedAt: null,
            displayName: prepared.participantDisplayName ?? 'Unknown member',
          },
        })
      } else {
        await tx.groupParticipant.create({
          data: {
            id: randomUUID(),
            groupId: String(prepared.data.groupId),
            userId: prepared.participantUserId,
            displayName: prepared.participantDisplayName ?? 'Unknown member',
            status: 'ACTIVE',
          } as unknown as Prisma.GroupParticipantUncheckedCreateInput,
        })
      }
      return
    }
    case 'membership.remove':
      await tx.groupMember.delete({ where: { id: prepared.recordId } })
      {
        const participant = await tx.groupParticipant.findUnique({
          where: {
            groupId_userId: {
              groupId: String(prepared.data.groupId ?? ''),
              userId: prepared.participantUserId,
            },
          },
        })
        if (participant) {
          await tx.groupParticipant.update({
            where: { id: participant.id },
            data: { status: 'DEPARTED', departedAt: new Date() },
          })
        }
      }
      return
    case 'membership.update':
      await tx.groupMember.update({
        where: { id: prepared.recordId },
        data: prepared.data as unknown as Prisma.GroupMemberUpdateInput,
      })
      return
    case 'settlement.create':
      await tx.transaction.create({
        data: prepared.transactionData as unknown as Prisma.TransactionUncheckedCreateInput,
      })
      await tx.settlementAllocation.create({
        data: prepared.allocationData as unknown as Prisma.SettlementAllocationUncheckedCreateInput,
      })
      return
    case 'settlement.reverse':
      await tx.settlementReversal.create({
        data: prepared.data as unknown as Prisma.SettlementReversalUncheckedCreateInput,
      })
      return
    case 'settings.update':
      await tx.settlementSettingAudit.create({
        data: prepared.data as unknown as Prisma.SettlementSettingAuditUncheckedCreateInput,
      })
      await tx.group.update({
        where: { id: String(prepared.data.groupId) },
        data: { simplifyDebts: prepared.data.simplifyDebts as boolean },
      })
      return
  }
}

async function reserveRevision(
  tx: MutationTransaction,
  request: NormalizedRequest
): Promise<number> {
  const update = await tx.group.updateMany({
    where: {
      id: request.groupId,
      settlementVersion: request.expectedRevision,
      isArchived: false,
    },
    data: { settlementVersion: { increment: 1 } },
  })
  if (update.count !== 1) {
    const current = await readGroup(tx, request.groupId)
    if (current.isArchived) {
      throw new LedgerMutationError('GROUP_ARCHIVED', 403, 'Group is archived')
    }
    throw revisionConflict(request, current)
  }
  return request.expectedRevision + 1
}

async function journalMutation(
  tx: MutationTransaction,
  request: NormalizedRequest,
  revision: number,
  result: MutationResult
): Promise<void> {
  await tx.settlementVersionJournal.create({
    data: {
      groupId: request.groupId,
      version: revision,
      recordId: result.recordId || null,
      eventType: result.eventType,
    },
  })
  await tx.settlementOutbox.create({
    data: {
      groupId: request.groupId,
      recordId: result.recordId || request.operationId,
      eventType: result.eventType,
      version: revision,
    },
  })
}

async function executeInTransaction(
  tx: MutationTransaction,
  request: NormalizedRequest,
  options: Required<Pick<MutationKernelOptions, 'now' | 'retentionDays'>>
): Promise<LedgerMutationResult> {
  const operation = await upsertOperation(tx, request)
  if (operation.requestHash !== request.requestHash || operation.groupId !== request.groupId) {
    throw await idempotencyConflict(tx, request, operation)
  }
  if (operation.state === 'COMMITTED') {
    return resultFromOperation(request, operation, options.now(), options.retentionDays)
  }
  if (operation.state === 'FAILED') {
    throw new LedgerMutationError(
      operation.failureCode ?? 'MUTATION_FAILED',
      409,
      'The operation previously failed'
    )
  }

  const group = await readGroup(tx, request.groupId)
  assertExpectedRevision(request, group)
  let prepared: PreparedMutation
  try {
    prepared = await prepareMutation(tx, request, group, options.now())
  } catch (error) {
    if (error instanceof LedgerMoneyError) {
      throw new LedgerMutationError(error.code, 400, error.message)
    }
    throw error
  }
  if ('noop' in prepared && prepared.noop) {
    const operationResult = await tx.ledgerOperation.update({
      where: { id: operation.id },
      data: {
        state: 'COMMITTED',
        resultRevision: group.settlementVersion,
        resultRecordId: null,
        completedAt: options.now(),
      },
    })
    void operationResult
    return buildResult({
      request,
      outcome: 'applied',
      revision: group.settlementVersion,
      recordId: '',
      eventType: 'setting_noop',
      now: options.now(),
      retentionDays: options.retentionDays,
      noop: true,
    })
  }

  const revision = await reserveRevision(tx, request)
  await commitPreparedMutation(tx, prepared)
  const mutationResult: MutationResult = {
    recordId: prepared.recordId,
    eventType: prepared.eventType,
  }
  await journalMutation(tx, request, revision, mutationResult)
  await tx.ledgerOperation.update({
    where: { id: operation.id },
    data: {
      state: 'COMMITTED',
      resultRevision: revision,
      resultRecordId: prepared.recordId || null,
      completedAt: options.now(),
    },
  })
  return buildResult({
    request,
    outcome: 'applied',
    revision,
    recordId: prepared.recordId,
    eventType: prepared.eventType,
    now: options.now(),
    retentionDays: options.retentionDays,
  })
}

function isTransientTransactionError(error: unknown): boolean {
  if (error instanceof LedgerMutationError) return false
  if (!error || typeof error !== 'object') return false
  const value = error as { code?: unknown; message?: unknown }
  if (typeof value.code === 'string' && TRANSIENT_ERROR_CODES.has(value.code)) return true
  return typeof value.message === 'string' && /deadlock|serialization failure/i.test(value.message)
}

/**
 * Execute every shared-ledger write through one transaction. The conditional
 * revision update is the serialization point: concurrent callers with the
 * same expected revision produce one commit and one REVISION_CONFLICT.
 */
export async function executeMutation(
  request: LedgerMutationRequest,
  options: MutationKernelOptions = {}
): Promise<LedgerMutationResult> {
  const normalized = normalizeRequest(request)
  const db = options.db ?? prisma
  const now = options.now ?? (() => new Date())
  const retentionDays = options.retentionDays ?? DEFAULT_RETENTION_DAYS
  const maxRetries = Math.max(0, options.maxRetries ?? 2)

  let attempt = 0
  while (true) {
    try {
      return await db.$transaction((tx) =>
        executeInTransaction(tx, normalized, { now, retentionDays })
      )
    } catch (error) {
      if (!isTransientTransactionError(error) || attempt >= maxRetries) throw error
      attempt += 1
    }
  }
}

export const executeLedgerMutation = executeMutation
export const runMutation = executeMutation
export { hashCanonicalRequest, hashMutationRequest, hashRequest, mutationRequestHash }
export type { MutationKernelOptions, NormalizedRequest }
