import type { Prisma, PrismaClient } from '@prisma/client'
import { prisma } from '@/lib/prisma'
import type { GroupLedgerInput, SettlementRecord } from './types'

type Db = PrismaClient | Prisma.TransactionClient

export async function loadGroupLedger(groupId: string, db: Db = prisma): Promise<GroupLedgerInput> {
  const group = await db.group.findUniqueOrThrow({
    where: { id: groupId },
    select: {
      id: true,
      settlementVersion: true,
      simplifyDebts: true,
    },
  })

  const participants = await db.groupParticipant.findMany({
    where: { groupId },
    select: {
      id: true,
      userId: true,
      displayName: true,
      status: true,
    },
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
    .filter((t) => t.amountMinorUnits !== null && t.currencyExponent !== null)
    .map((t) => ({
      id: t.id,
      payerParticipantId: t.payerParticipantId ?? '',
      recipientParticipantId: t.recipientParticipantId ?? '',
      amount: {
        currencyCode: t.currency.toUpperCase(),
        currencyExponent: t.currencyExponent!,
        minorUnits: t.amountMinorUnits!,
      },
      mode: t.settlementMode ?? 'SIMPLIFIED',
      createdAt: t.createdAt,
      reversed: Boolean(t.reversal),
      snapshot: t.allocation
        ? {
            settlementVersion: t.allocation.settlementVersion,
            mode: t.allocation.mode,
            algorithmVersion: t.allocation.algorithmVersion,
            amount: {
              currencyCode: t.allocation.currencyCode,
              currencyExponent: t.allocation.currencyExponent,
              minorUnits: t.allocation.amountMinorUnits,
            },
            paths: t.allocation.paths.map((p) => ({
              payerParticipantId: p.payerParticipantId,
              recipientParticipantId: p.recipientParticipantId,
              flowMinorUnits: p.flowMinorUnits,
              obligationComponentKeys: [p.obligationComponentKey],
            })),
          }
        : null,
    }))

  return {
    groupId: group.id,
    settlementVersion: group.settlementVersion,
    simplifyDebts: group.simplifyDebts,
    participants: participants.map((p) => ({
      id: p.id,
      userId: p.userId,
      displayName: p.displayName,
      status: p.status,
    })),
    expenses: expenses
      .filter((e) => e.amountMinorUnits !== null && e.currencyExponent !== null)
      .map((e) => ({
        id: e.id,
        paidByUserId: e.paidById,
        currency: e.currency,
        amountMinorUnits: e.amountMinorUnits!,
        currencyExponent: e.currencyExponent!,
        splits: e.splits
          .filter((s) => s.amountMinorUnits !== null && s.currencyExponent !== null)
          .map((s) => ({
            id: s.id,
            userId: s.userId,
            amountMinorUnits: s.amountMinorUnits!,
            currencyExponent: s.currencyExponent!,
          })),
      })),
    settlements,
  }
}
