import type { Prisma } from '@prisma/client'
import { prisma } from '@/lib/prisma'
import { floatToMinorUnits } from '../money/canonical'
import { advanceGroupVersion } from '../commands/core'
import { buildPlan, planIsEmpty } from '../ledger/projections'
import { loadGroupLedger } from '../ledger/load'
import { ensureParticipantsForGroup } from '../participants/service'
import { wakeOutboxDispatcher } from '../outbox/dispatcher'

type Db = Prisma.TransactionClient

export async function dualWriteExpenseAmount(
  amount: number,
  currency: string
): Promise<{ amountMinorUnits: bigint; currencyExponent: number } | null> {
  const converted = floatToMinorUnits(amount, currency)
  if ('code' in converted) return null
  return {
    amountMinorUnits: converted.minorUnits,
    currencyExponent: converted.currencyExponent,
  }
}

export async function onGroupExpenseMutation(groupId: string, recordId: string, eventType: string) {
  await prisma.$transaction(async (tx) => {
    await ensureParticipantsForGroup(groupId, tx)
    await advanceGroupVersion(groupId, eventType, recordId, tx)
  })
  wakeOutboxDispatcher()
}

export async function onMembershipMutation(groupId: string, recordId: string) {
  await prisma.$transaction(async (tx) => {
    await ensureParticipantsForGroup(groupId, tx)
    await advanceGroupVersion(groupId, 'membership_changed', recordId, tx)
  })
  wakeOutboxDispatcher()
}

export async function onGroupLifecycleMutation(
  groupId: string,
  recordId: string,
  eventType: 'group_archived' | 'group_restored' | 'group_finalized'
) {
  await prisma.$transaction(async (tx) => {
    await advanceGroupVersion(groupId, eventType, recordId, tx)
  })
  wakeOutboxDispatcher()
}

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
