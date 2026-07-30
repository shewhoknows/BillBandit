import { prisma } from '@/lib/prisma'
import { formatMinorUnits } from '../money/canonical'
import { buildPlan } from '../ledger/projections'
import { loadGroupLedger } from '../ledger/load'
import { derivePermissions, filterPlanForCaller, type CallerAccess } from '../access/matrix'
import { resolveCallerAccess } from '../commands/core'
import { isRealtimeAvailable } from '../outbox/pusher'

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
  permissions: ReturnType<typeof derivePermissions>
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

function encodeHistoryCursor(createdAt: Date, id: string): string {
  return Buffer.from(`${createdAt.toISOString()}|${id}`).toString('base64url')
}

function decodeHistoryCursor(cursor: string): { createdAt: Date; id: string } | null {
  try {
    const decoded = Buffer.from(cursor, 'base64url').toString('utf8')
    const [iso, id] = decoded.split('|')
    if (!iso || !id) return null
    return { createdAt: new Date(iso), id }
  } catch {
    return null
  }
}

async function buildPlanDto(groupId: string, access: CallerAccess) {
  const ledger = await loadGroupLedger(groupId)
  const transfers = filterPlanForCaller(buildPlan(ledger), access)
  const participants = new Map(ledger.participants.map((p) => [p.id, p.displayName]))

  return transfers.map((t) => ({
    planTransferId: t.planTransferId,
    payerParticipantId: t.payerParticipantId,
    recipientParticipantId: t.recipientParticipantId,
    payerName: participants.get(t.payerParticipantId) ?? 'Unknown member',
    recipientName: participants.get(t.recipientParticipantId) ?? 'Unknown member',
    amount: formatMinorUnits(t.amount),
    currencyCode: t.amount.currencyCode,
    currencyExponent: t.amount.currencyExponent,
    mode: t.mode,
  }))
}

async function loadSettledPage(
  groupId: string,
  access: CallerAccess,
  cursor?: string | null,
  limit = 20
) {
  const permissions = derivePermissions(access)
  if (!permissions.canReadHistory) return { items: [], nextCursor: null }

  const cursorData = cursor ? decodeHistoryCursor(cursor) : null
  const where: Record<string, unknown> = { groupId }

  if (access.participantId && permissions.readScope === 'limited') {
    where.OR = [
      { payerParticipantId: access.participantId },
      { recipientParticipantId: access.participantId },
    ]
  }

  const transactions = await prisma.transaction.findMany({
    where,
    include: {
      reversal: true,
      payerParticipant: true,
      recipientParticipant: true,
      actor: { select: { id: true, name: true } },
    },
    orderBy: [{ createdAt: 'desc' }, { id: 'desc' }],
    take: limit + 1,
    ...(cursorData
      ? {
          cursor: { id: cursorData.id },
          skip: 1,
          where: {
            ...where,
            OR: [
              { createdAt: { lt: cursorData.createdAt } },
              { createdAt: cursorData.createdAt, id: { lt: cursorData.id } },
            ],
          },
        }
      : {}),
  })

  const page = transactions.slice(0, limit)
  const items = page.flatMap((t) => {
    const base = {
      id: t.id,
      type: 'settlement' as const,
      payerParticipantId: t.payerParticipantId,
      recipientParticipantId: t.recipientParticipantId,
      payerName: t.payerParticipant?.displayName ?? 'Unknown member',
      recipientName: t.recipientParticipant?.displayName ?? 'Unknown member',
      amount: t.amountMinorUnits ? formatMinorUnits({
        currencyCode: t.currency.toUpperCase(),
        currencyExponent: t.currencyExponent ?? 2,
        minorUnits: t.amountMinorUnits,
      }) : String(t.amount),
      currencyCode: t.currency.toUpperCase(),
      note: t.note,
      actorName: t.actor?.name ?? 'Unknown member',
      createdAt: t.createdAt.toISOString(),
    }
    if (!t.reversal) return [base]
    return [
      base,
      {
        id: t.reversal.id,
        type: 'reversal' as const,
        settlementId: t.id,
        actorName: t.reversal.actorUserId ? (t.actor?.name ?? 'Unknown member') : 'Unknown member',
        createdAt: t.reversal.createdAt.toISOString(),
      },
    ]
  })

  const nextCursor =
    transactions.length > limit
      ? encodeHistoryCursor(page[page.length - 1].createdAt, page[page.length - 1].id)
      : null

  return { items, nextCursor }
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
  if (!permissions.canReadPlan) {
    throw new Error('FORBIDDEN')
  }

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
    permissions,
    realtime: { available: isRealtimeAvailable() },
  }

  if (afterVersion !== undefined && afterVersion !== null) {
    if (afterVersion > group.settlementVersion) {
      throw Object.assign(new Error('VERSION_AHEAD'), {
        code: 'VERSION_AHEAD',
        snapshot: await buildSnapshot(groupId, access, base),
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

    return {
      mode: 'incremental',
      ...base,
      fromVersion: afterVersion,
      toVersion: group.settlementVersion,
      envelopes: journals.map((j) => ({
        version: j.version,
        eventType: j.eventType,
        recordId: j.recordId,
        createdAt: j.createdAt.toISOString(),
      })),
      plan: await buildPlanDto(groupId, access),
      settled: await loadSettledPage(groupId, access),
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
  return {
    mode: 'snapshot',
    ...base,
    reason,
    plan: await buildPlanDto(groupId, access),
    settled: await loadSettledPage(groupId, access),
  }
}

export { loadSettledPage, decodeHistoryCursor, encodeHistoryCursor }
