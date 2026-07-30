import type { Prisma } from '@prisma/client'
import { prisma } from '@/lib/prisma'
import { floatToMinorUnits } from '../money/canonical'
import { advanceGroupVersion } from '../commands/core'
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

export async function onSettlementCommandCommitted() {
  wakeOutboxDispatcher()
}
