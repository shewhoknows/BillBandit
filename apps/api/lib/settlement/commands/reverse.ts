import { prisma } from '@/lib/prisma'
import { buildPlan } from '../ledger/projections'
import { loadGroupLedger } from '../ledger/load'
import {
  advanceGroupVersion,
  assertExpectedVersion,
  checkIdempotency,
  hashRequest,
  recordIdempotency,
  resolveCallerAccess,
  SettlementCommandError,
} from './core'
import { derivePermissions } from '../access/matrix'

export type ReverseCommandInput = {
  groupId: string
  userId: string
  settlementId: string
  idempotencyKey: string
  expectedVersion: number
}

export async function executeReversal(input: ReverseCommandInput) {
  const requestHash = hashRequest({ settlementId: input.settlementId })
  const operationKey = `reversal:${input.idempotencyKey}`

  return prisma.$transaction(async (tx) => {
    const replay = await checkIdempotency(input.groupId, operationKey, requestHash, tx)
    if (replay) return replay

    await assertExpectedVersion(input.groupId, input.expectedVersion, tx)

    const transaction = await tx.transaction.findFirst({
      where: { id: input.settlementId, groupId: input.groupId },
      include: { reversal: true },
    })
    if (!transaction) throw new SettlementCommandError('SETTLEMENT_NOT_FOUND', 404)
    if (transaction.reversal) throw new SettlementCommandError('ALREADY_REVERSED', 409)

    const ledger = await loadGroupLedger(input.groupId, tx)
    const transfers = buildPlan(ledger)
    const access = await resolveCallerAccess(input.groupId, input.userId, tx)
    const permissions = derivePermissions(access)
    if (!permissions.canSettleOrReverse) throw new SettlementCommandError('FORBIDDEN', 403)

    const payerId = transaction.payerParticipantId
    const recipientId = transaction.recipientParticipantId
    if (!payerId || !recipientId) throw new SettlementCommandError('INVALID_SETTLEMENT', 400)
    if (access.participantId !== payerId && access.participantId !== recipientId) {
      throw new SettlementCommandError('FORBIDDEN', 403)
    }

    const reversal = await tx.settlementReversal.create({
      data: {
        groupId: input.groupId,
        transactionId: transaction.id,
        actorUserId: input.userId,
      },
    })

    const version = await advanceGroupVersion(input.groupId, 'settlement_reversed', reversal.id, tx)
    const result = { version, recordId: reversal.id, eventType: 'settlement_reversed' }
    await recordIdempotency(input.groupId, operationKey, requestHash, result, tx)
    return { ...result, reversalId: reversal.id, transfers }
  })
}
