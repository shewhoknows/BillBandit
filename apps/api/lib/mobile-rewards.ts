import type { PrismaClient } from '@prisma/client'
import { prisma } from './prisma'

export type MobileRewardEvent = {
  action: 'expenseAdded' | 'settlementRecorded'
  eventId: string
  createdAt: string
}

type RewardReadDb = Pick<PrismaClient, 'expense' | 'transaction'>

export async function loadMobileRewardEvents(
  accountId: string,
  db: RewardReadDb = prisma
): Promise<MobileRewardEvent[]> {
  const [expenses, settlements] = await Promise.all([
    db.expense.findMany({
      where: { createdById: accountId },
      select: { id: true, createdAt: true },
      orderBy: [{ createdAt: 'asc' }, { id: 'asc' }],
    }),
    db.transaction.findMany({
      where: {
        OR: [
          { actorUserId: accountId },
          { actorUserId: null, senderId: accountId },
        ],
      },
      select: { id: true, createdAt: true },
      orderBy: [{ createdAt: 'asc' }, { id: 'asc' }],
    }),
  ])

  return [
    ...expenses.map((expense) => ({
      action: 'expenseAdded' as const,
      eventId: expense.id,
      createdAt: expense.createdAt.toISOString(),
    })),
    ...settlements.map((settlement) => ({
      action: 'settlementRecorded' as const,
      eventId: settlement.id,
      createdAt: settlement.createdAt.toISOString(),
    })),
  ].sort((left, right) =>
    left.createdAt.localeCompare(right.createdAt) || left.eventId.localeCompare(right.eventId)
  )
}
