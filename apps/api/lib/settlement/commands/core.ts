import { createHash } from 'crypto'
import type { Prisma } from '@prisma/client'
import { LedgerMutationError } from '@/lib/ledger/mutation'
import { buildPlan, planIsEmpty } from '../ledger/projections'
import { loadGroupLedger } from '../ledger/load'
import { type CallerAccess } from '../access/matrix'

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

export type NormalizedSettlementError = {
  code: string
  status: number
  details: Record<string, unknown>
  includeState: boolean
}

const staleSettlementConflictCodes = new Set([
  'REVISION_CONFLICT',
  'SETTLEMENT_VERSION_CONFLICT',
  'TRANSFER_MISMATCH',
  'TRANSFER_NOT_FOUND',
])

/** Translate the shared-kernel errors back to the legacy settle-up contract. */
export function normalizeSettlementError(error: unknown): NormalizedSettlementError | null {
  if (error instanceof LedgerMutationError) {
    const staleConflict = staleSettlementConflictCodes.has(error.code)
    return {
      code:
        error.code === 'REVISION_CONFLICT'
          ? 'SETTLEMENT_VERSION_CONFLICT'
          : error.code === 'TRANSFER_NOT_FOUND'
            ? 'TRANSFER_MISMATCH'
            : error.code,
      status: staleConflict ? 409 : error.status,
      details: {
        ...(error.details ?? {}),
        ...(staleConflict ? { requiresReconfirmation: true } : {}),
      },
      includeState: staleConflict,
    }
  }

  if (error instanceof SettlementCommandError) {
    return {
      code: error.code,
      status: error.status,
      details: error.details ?? {},
      includeState: staleSettlementConflictCodes.has(error.code),
    }
  }

  return null
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

export { resolveCallerAccess, assertNotArchived }
