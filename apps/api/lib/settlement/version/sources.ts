import { prisma } from '@/lib/prisma'
import { buildPlan, planIsEmpty } from '../ledger/projections'
import { loadGroupLedger } from '../ledger/load'
import { wakeOutboxDispatcher } from '../outbox/dispatcher'
import { deriveCompletionFlags, SETTLE_EVENT_TYPES } from '../state'

/**
 * Recompute Group.hadOpenTransfers / settlementCompletedAt after a settle or
 * reverse request committed. See the completion machine in ../state.ts.
 */
export async function onSettlementCommandCommitted(groupId?: string, _eventType?: string) {
  if (groupId) {
    await prisma.$transaction(async (tx) => {
      // Kernel commits take this row lock too (settlementVersion CAS), so the
      // ledger read below and the write cannot interleave with a newer
      // commit or with another request's recompute.
      const locked = await tx.$queryRaw<Array<{ id: string }>>`
        SELECT "id" FROM "Group" WHERE "id" = ${groupId} FOR UPDATE`
      if (locked.length === 0) return
      const group = await tx.group.findUnique({
        where: { id: groupId },
        select: { hadOpenTransfers: true, settlementCompletedAt: true },
      })
      if (!group) return

      const ledger = await loadGroupLedger(groupId, tx)
      const latestSettleEvent = await tx.settlementVersionJournal.findFirst({
        where: { groupId, eventType: { in: [...SETTLE_EVENT_TYPES] } },
        orderBy: { version: 'desc' },
        select: { createdAt: true },
      })
      const next = deriveCompletionFlags({
        planIsEmpty: planIsEmpty(buildPlan(ledger)),
        latestSettleEventAt: latestSettleEvent?.createdAt ?? null,
        current: group,
        now: new Date(),
      })

      await tx.group.update({ where: { id: groupId }, data: next })
    })
  }
  wakeOutboxDispatcher()
}
