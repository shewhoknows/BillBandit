import { prisma } from '@/lib/prisma'
import { buildPlan, planIsEmpty } from '../ledger/projections'
import { loadGroupLedger } from '../ledger/load'
import { wakeOutboxDispatcher } from '../outbox/dispatcher'

export async function onSettlementCommandCommitted(groupId?: string, eventType?: string) {
  if (groupId) {
    await prisma.$transaction(async (tx) => {
      const group = await tx.group.findUnique({
        where: { id: groupId },
        select: { hadOpenTransfers: true, settlementCompletedAt: true },
      })
      if (!group) return

      const ledger = await loadGroupLedger(groupId, tx)
      const isEmpty = planIsEmpty(buildPlan(ledger))
      const settledAllTransfers =
        group.hadOpenTransfers || (eventType === 'settlement_created' && isEmpty)
      const settlementCompletedAt = settledAllTransfers && isEmpty
        ? group.settlementCompletedAt ?? new Date()
        : isEmpty
          ? group.settlementCompletedAt
          : null

      await tx.group.update({
        where: { id: groupId },
        data: {
          hadOpenTransfers: !isEmpty,
          settlementCompletedAt,
        },
      })
    })
  }
  wakeOutboxDispatcher()
}
