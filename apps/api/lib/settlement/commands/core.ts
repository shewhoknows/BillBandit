import { createHash } from 'crypto'
import type { Prisma } from '@prisma/client'
import { prisma } from '@/lib/prisma'
import { amountsEqual } from '../money/canonical'
import { buildPlan, planIsEmpty } from '../ledger/projections'
import { loadGroupLedger } from '../ledger/load'
import type { PlanTransfer } from '../ledger/types'
import { derivePermissions, type CallerAccess } from '../access/matrix'

export class SettlementCommandError extends Error {
  constructor(
    public readonly code: string,
    public readonly status: number,
    public readonly details?: Record<string, unknown>
  ) {
    super(code)
  }
}

export function hashRequest(payload: unknown): string {
  return createHash('sha256').update(JSON.stringify(payload)).digest('hex')
}

export type VersionAdvanceResult = {
  version: number
  recordId: string
  eventType: string
}

export type SettlementCommandResult = VersionAdvanceResult & {
  transactionId?: string
  allocationId?: string
  reversalId?: string
  noop?: boolean
}

async function resolveCallerAccess(
  groupId: string,
  userId: string,
  tx: Prisma.TransactionClient
): Promise<CallerAccess> {
  const [member, participant, plan] = await Promise.all([
    tx.groupMember.findUnique({ where: { groupId_userId: { groupId, userId } } }),
    tx.groupParticipant.findUnique({ where: { groupId_userId: { groupId, userId } } }),
    loadGroupLedger(groupId, tx),
  ])

  const transfers = buildPlan(plan)
  const hasUnsettled = participant
    ? transfers.some(
        (t) =>
          t.payerParticipantId === participant.id ||
          t.recipientParticipantId === participant.id
      )
  : false

  return {
    userId,
    isActiveMember: Boolean(member),
    isAdmin: member?.role === 'ADMIN',
    participantId: participant?.id ?? null,
    participantStatus: participant?.status ?? null,
    hasUnsettledPosition: hasUnsettled,
  }
}

function assertNotArchived(group: { isArchived: boolean }) {
  if (group.isArchived) {
    throw new SettlementCommandError('GROUP_ARCHIVED', 403)
  }
}

export async function findMatchingTransfer(
  groupId: string,
  planTransferId: string,
  payerParticipantId: string,
  recipientParticipantId: string,
  amount: { currencyCode: string; currencyExponent: number; minorUnits: bigint },
  tx: Prisma.TransactionClient
): Promise<PlanTransfer> {
  const ledger = await loadGroupLedger(groupId, tx)
  const transfers = buildPlan(ledger)
  const match = transfers.find((t) => t.planTransferId === planTransferId)
  if (!match) {
    throw new SettlementCommandError('TRANSFER_NOT_FOUND', 404)
  }
  if (
    match.payerParticipantId !== payerParticipantId ||
    match.recipientParticipantId !== recipientParticipantId ||
    !amountsEqual(match.amount, amount)
  ) {
    throw new SettlementCommandError('TRANSFER_MISMATCH', 409, { requiresReconfirmation: true })
  }
  return match
}

export async function checkIdempotency(
  groupId: string,
  operationKey: string,
  requestHash: string,
  tx: Prisma.TransactionClient
): Promise<VersionAdvanceResult | null> {
  const existing = await tx.idempotentOperation.findUnique({
    where: { groupId_operationKey: { groupId, operationKey } },
  })
  if (!existing) return null
  if (existing.requestHash !== requestHash) {
    throw new SettlementCommandError('IDEMPOTENCY_KEY_REUSED', 409)
  }
  return {
    version: existing.resultVersion,
    recordId: existing.resultRecordId ?? '',
    eventType: 'idempotent_replay',
  }
}

export async function recordIdempotency(
  groupId: string,
  operationKey: string,
  requestHash: string,
  result: VersionAdvanceResult,
  tx: Prisma.TransactionClient
): Promise<void> {
  await tx.idempotentOperation.create({
    data: {
      groupId,
      operationKey,
      requestHash,
      resultVersion: result.version,
      resultRecordId: result.recordId,
    },
  })
}

export async function advanceGroupVersion(
  groupId: string,
  eventType: string,
  recordId: string,
  tx: Prisma.TransactionClient
): Promise<number> {
  const group = await tx.group.update({
    where: { id: groupId },
    data: { settlementVersion: { increment: 1 } },
    select: {
      settlementVersion: true,
      hadOpenTransfers: true,
      settlementCompletedAt: true,
    },
  })

  const ledger = await loadGroupLedger(groupId, tx)
  const transfers = buildPlan(ledger)
  const isEmpty = planIsEmpty(transfers)
  const hadOpen = group.hadOpenTransfers
  let settlementCompletedAt = group.settlementCompletedAt

  if (hadOpen && isEmpty) {
    settlementCompletedAt = new Date()
  } else if (!isEmpty) {
    settlementCompletedAt = null
  }

  await tx.group.update({
    where: { id: groupId },
    data: {
      hadOpenTransfers: !isEmpty,
      settlementCompletedAt,
    },
  })

  await tx.settlementVersionJournal.create({
    data: {
      groupId,
      version: group.settlementVersion,
      recordId,
      eventType,
    },
  })

  await tx.settlementOutbox.create({
    data: {
      groupId,
      recordId,
      eventType,
      version: group.settlementVersion,
    },
  })

  return group.settlementVersion
}

export async function assertExpectedVersion(
  groupId: string,
  expectedVersion: number | undefined,
  tx: Prisma.TransactionClient
): Promise<number> {
  const group = await tx.group.findUniqueOrThrow({
    where: { id: groupId },
    select: { settlementVersion: true, isArchived: true },
  })
  assertNotArchived(group)
  if (expectedVersion === undefined) return group.settlementVersion
  if (expectedVersion !== group.settlementVersion) {
    throw new SettlementCommandError('SETTLEMENT_VERSION_CONFLICT', 409, {
      requiresReconfirmation: true,
      currentVersion: group.settlementVersion,
    })
  }
  return group.settlementVersion
}

export async function assertCallerCanWrite(
  groupId: string,
  userId: string,
  transfer: PlanTransfer,
  tx: Prisma.TransactionClient
): Promise<CallerAccess> {
  const access = await resolveCallerAccess(groupId, userId, tx)
  const permissions = derivePermissions(access)
  if (!permissions.canSettleOrReverse) {
    throw new SettlementCommandError('FORBIDDEN', 403)
  }
  if (
    access.participantId !== transfer.payerParticipantId &&
    access.participantId !== transfer.recipientParticipantId
  ) {
    throw new SettlementCommandError('FORBIDDEN', 403)
  }
  return access
}

export { resolveCallerAccess, assertNotArchived }
