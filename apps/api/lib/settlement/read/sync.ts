import { prisma } from '@/lib/prisma'
import { loadGroupReadModel } from '@/lib/ledger/read-model/loader'
import type { GroupLedgerReadModel, SettlementHistoryItem } from '@/lib/ledger-contract'
import { formatMinorUnits } from '../money/canonical'
import { derivePermissions, type CallerAccess } from '../access/matrix'
import { resolveCallerAccess } from '../commands/core'
import { isRealtimeAvailable } from '../outbox/pusher'

type SettlementCompatibilityPermissions = ReturnType<typeof derivePermissions> & {
  callerParticipantId: string | null
}

export type SettleUpSnapshot = {
  mode: 'snapshot' | 'no_change' | 'incremental'
  version: number
  lifecycle: { isArchived: boolean; isFinalized: boolean }
  simplifyDebts: boolean
  latestSettingAudit: {
    simplifyDebts: boolean
    actorUserId: string
    actorName: string | null
    createdAt: string
  } | null
  settlementCompletedAt: string | null
  permissions: SettlementCompatibilityPermissions
  realtime: { available: boolean }
  plan: Array<{
    planTransferId: string
    payerParticipantId: string
    recipientParticipantId: string
    payerName: string
    recipientName: string
    amount: string
    currencyCode: string
    currencyExponent: number
    mode: string
  }>
  settled: {
    items: Array<Record<string, unknown>>
    nextCursor: string | null
  }
  reason?: string
  fromVersion?: number
  toVersion?: number
  envelopes?: Array<{ version: number; eventType: string; recordId: string | null; createdAt: string }>
}

type CanonicalSettlement = Extract<SettlementHistoryItem, { type: 'settlement' }>
type CanonicalReversal = Extract<SettlementHistoryItem, { type: 'reversal' }>

function encodeHistoryCursor(createdAt: Date, id: string): string {
  return Buffer.from(`${createdAt.toISOString()}|${id}`).toString('base64url')
}

function decodeHistoryCursor(cursor: string): { createdAt: Date; id: string } | null {
  try {
    const decoded = Buffer.from(cursor, 'base64url').toString('utf8')
    const [iso, id] = decoded.split('|')
    const createdAt = iso ? new Date(iso) : null
    if (!createdAt || Number.isNaN(createdAt.getTime()) || !id) return null
    return { createdAt, id }
  } catch {
    return null
  }
}

function legacyAmount(money: {
  minorUnits: string
  currencyCode: string
  currencyExponent: number
}): string {
  return formatMinorUnits({
    currencyCode: money.currencyCode,
    currencyExponent: money.currencyExponent,
    minorUnits: BigInt(money.minorUnits),
  })
}

async function loadCanonicalGroup(groupId: string, userId: string): Promise<GroupLedgerReadModel> {
  const result = await loadGroupReadModel(groupId, userId)
  return result.group
}

function visibleCanonicalPlan(
  model: GroupLedgerReadModel,
  access: CallerAccess
) {
  if (access.participantId === null) return []
  if (derivePermissions(access).readScope === 'full') return model.settlementPlan.transfers
  return model.settlementPlan.transfers.filter(
    (transfer) =>
      transfer.payerMemberId === access.participantId ||
      transfer.recipientMemberId === access.participantId
  )
}

function buildPlanDto(model: GroupLedgerReadModel, access: CallerAccess) {
  const participants = new Map(model.members.map((member) => [member.memberId, member.displayName]))
  return visibleCanonicalPlan(model, access).map((transfer) => ({
    planTransferId: transfer.planTransferId,
    payerParticipantId: transfer.payerMemberId,
    recipientParticipantId: transfer.recipientMemberId,
    payerName: participants.get(transfer.payerMemberId) ?? 'Unknown member',
    recipientName: participants.get(transfer.recipientMemberId) ?? 'Unknown member',
    amount: legacyAmount(transfer.amount),
    currencyCode: transfer.amount.currencyCode,
    currencyExponent: transfer.amount.currencyExponent,
    mode: transfer.mode,
  }))
}

function visibleCanonicalSettlements(
  model: GroupLedgerReadModel,
  access: CallerAccess
): CanonicalSettlement[] {
  const readScope = derivePermissions(access).readScope
  return model.settlementHistory
    .filter((item): item is CanonicalSettlement => item.type === 'settlement')
    .filter(
      (settlement) =>
        readScope === 'full' ||
        (access.participantId !== null &&
          (settlement.payerMemberId === access.participantId ||
            settlement.recipientMemberId === access.participantId))
    )
    .sort(
      (left, right) =>
        right.createdAt.localeCompare(left.createdAt) ||
        right.settlementId.localeCompare(left.settlementId)
    )
}

function isAfterHistoryCursor(
  settlement: CanonicalSettlement,
  cursor: { createdAt: Date; id: string } | null
): boolean {
  if (!cursor) return true
  return (
    settlement.createdAt < cursor.createdAt.toISOString() ||
    (settlement.createdAt === cursor.createdAt.toISOString() &&
      settlement.settlementId < cursor.id)
  )
}

async function loadSettlementNotes(
  groupId: string,
  settlementIds: string[]
): Promise<Map<string, string | null>> {
  if (settlementIds.length === 0) return new Map()
  const transactions = await prisma.transaction.findMany({
    where: { groupId, id: { in: settlementIds } },
    select: { id: true, note: true },
  })
  return new Map(transactions.map((transaction) => [transaction.id, transaction.note]))
}

async function loadSettledPageFromModel(
  groupId: string,
  model: GroupLedgerReadModel,
  access: CallerAccess,
  cursor?: string | null,
  limit = 20
) {
  const permissions = derivePermissions(access)
  if (!permissions.canReadHistory) return { items: [], nextCursor: null }

  const cursorData = cursor ? decodeHistoryCursor(cursor) : null
  const settlements = visibleCanonicalSettlements(model, access)
  const page = settlements.filter((settlement) => isAfterHistoryCursor(settlement, cursorData)).slice(0, limit)
  const notes = await loadSettlementNotes(
    groupId,
    page.map((settlement) => settlement.settlementId)
  )
  const participants = new Map(model.members.map((member) => [member.memberId, member.displayName]))
  const reversals = new Map<string, CanonicalReversal>()
  for (const item of model.settlementHistory) {
    if (item.type === 'reversal') reversals.set(item.settlementId, item)
  }

  const items = page.flatMap((settlement) => {
    const base = {
      id: settlement.settlementId,
      type: 'settlement' as const,
      payerParticipantId: settlement.payerMemberId,
      recipientParticipantId: settlement.recipientMemberId,
      payerName: participants.get(settlement.payerMemberId) ?? 'Unknown member',
      recipientName: participants.get(settlement.recipientMemberId) ?? 'Unknown member',
      amount: legacyAmount(settlement.amount),
      currencyCode: settlement.amount.currencyCode,
      note: notes.get(settlement.settlementId) ?? null,
      actorName: participants.get(settlement.actorMemberId) ?? 'Unknown member',
      createdAt: settlement.createdAt,
    }
    const reversal = reversals.get(settlement.settlementId)
    if (!reversal) return [base]
    return [
      base,
      {
        id: reversal.reversalId,
        type: 'reversal' as const,
        settlementId: settlement.settlementId,
        actorName: participants.get(reversal.actorMemberId) ?? 'Unknown member',
        createdAt: reversal.createdAt,
      },
    ]
  })

  const pageEnd = page.length > 0 ? settlements.indexOf(page[page.length - 1]) : -1
  const nextCursor = pageEnd >= 0 && pageEnd < settlements.length - 1
    ? encodeHistoryCursor(
        new Date(page[page.length - 1].createdAt),
        page[page.length - 1].settlementId
      )
    : null

  return { items, nextCursor }
}

export async function loadSettledPage(
  groupId: string,
  access: CallerAccess,
  cursor?: string | null,
  limit = 20
) {
  if (!derivePermissions(access).canReadHistory) return { items: [], nextCursor: null }
  const model = await loadCanonicalGroup(groupId, access.userId)
  return loadSettledPageFromModel(groupId, model, access, cursor, limit)
}

export async function getSettleUpState(
  groupId: string,
  userId: string,
  afterVersion?: number | null
): Promise<SettleUpSnapshot> {
  const group = await prisma.group.findUniqueOrThrow({
    where: { id: groupId },
    select: {
      settlementVersion: true,
      simplifyDebts: true,
      settlementCompletedAt: true,
      isArchived: true,
      finalizedAt: true,
    },
  })

  const access = await resolveCallerAccess(groupId, userId, prisma)
  const permissions = derivePermissions(access)
  if (!permissions.canReadPlan) throw new Error('FORBIDDEN')

  const latestAudit = await prisma.settlementSettingAudit.findFirst({
    where: { groupId },
    orderBy: { createdAt: 'desc' },
    include: { actor: { select: { id: true, name: true } } },
  })

  const base = {
    version: group.settlementVersion,
    lifecycle: { isArchived: group.isArchived, isFinalized: Boolean(group.finalizedAt) },
    simplifyDebts: group.simplifyDebts,
    latestSettingAudit: latestAudit
      ? {
          simplifyDebts: latestAudit.simplifyDebts,
          actorUserId: latestAudit.actorUserId,
          actorName: latestAudit.actor.name,
          createdAt: latestAudit.createdAt.toISOString(),
        }
      : null,
    settlementCompletedAt: group.settlementCompletedAt?.toISOString() ?? null,
    permissions: { ...permissions, callerParticipantId: access.participantId },
    realtime: { available: isRealtimeAvailable() },
  }

  if (afterVersion !== undefined && afterVersion !== null) {
    if (afterVersion > group.settlementVersion) {
      const snapshot = await buildSnapshot(groupId, access, base, 'VERSION_AHEAD')
      throw Object.assign(new Error('VERSION_AHEAD'), {
        code: 'VERSION_AHEAD',
        snapshot,
      })
    }
    if (afterVersion === group.settlementVersion) {
      return {
        mode: 'no_change',
        ...base,
        plan: [],
        settled: { items: [], nextCursor: null },
      }
    }

    const journals = await prisma.settlementVersionJournal.findMany({
      where: {
        groupId,
        version: { gt: afterVersion, lte: group.settlementVersion },
      },
      orderBy: { version: 'asc' },
    })

    const expectedCount = group.settlementVersion - afterVersion
    if (journals.length !== expectedCount) {
      return buildSnapshot(groupId, access, base, 'VERSION_GAP')
    }

    const model = await loadCanonicalGroup(groupId, userId)
    return {
      mode: 'incremental',
      ...base,
      fromVersion: afterVersion,
      toVersion: group.settlementVersion,
      envelopes: journals.map((journal) => ({
        version: journal.version,
        eventType: journal.eventType,
        recordId: journal.recordId,
        createdAt: journal.createdAt.toISOString(),
      })),
      plan: buildPlanDto(model, access),
      settled: await loadSettledPageFromModel(groupId, model, access),
    }
  }

  return buildSnapshot(groupId, access, base)
}

async function buildSnapshot(
  groupId: string,
  access: CallerAccess,
  base: Omit<SettleUpSnapshot, 'mode' | 'plan' | 'settled'>,
  reason?: string
): Promise<SettleUpSnapshot> {
  const model = await loadCanonicalGroup(groupId, access.userId)
  return {
    mode: 'snapshot',
    ...base,
    reason,
    plan: buildPlanDto(model, access),
    settled: await loadSettledPageFromModel(groupId, model, access),
  }
}

export { decodeHistoryCursor, encodeHistoryCursor }
