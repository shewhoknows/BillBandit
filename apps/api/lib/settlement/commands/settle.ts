import { prisma } from '@/lib/prisma'
import { dualWriteFloat } from '../money/canonical'
import { allocateSettlementPaths } from '../ledger/projections'
import { loadGroupLedger } from '../ledger/load'
import { groupHasMoneyIssues } from '../money/issues'
import {
  advanceGroupVersion,
  assertCallerCanWrite,
  assertExpectedVersion,
  checkIdempotency,
  findMatchingTransfer,
  hashRequest,
  recordIdempotency,
  SettlementCommandError,
  type SettlementCommandResult,
} from './core'

export type SettleCommandInput = {
  groupId: string
  userId: string
  idempotencyKey: string
  expectedVersion: number
  planTransferId: string
  payerParticipantId: string
  recipientParticipantId: string
  currencyCode: string
  currencyExponent: number
  minorUnits: bigint
  note?: string
}

export async function executeSettlement(input: SettleCommandInput): Promise<SettlementCommandResult> {
  const requestBody = {
    planTransferId: input.planTransferId,
    payerParticipantId: input.payerParticipantId,
    recipientParticipantId: input.recipientParticipantId,
    currencyCode: input.currencyCode,
    currencyExponent: input.currencyExponent,
    minorUnits: input.minorUnits.toString(),
    note: input.note ?? null,
  }
  const requestHash = hashRequest(requestBody)
  const operationKey = `settlement:${input.idempotencyKey}`

  return prisma.$transaction(async (tx) => {
    if (await groupHasMoneyIssues(input.groupId)) {
      throw new SettlementCommandError('MONEY_REPRESENTATION_UNAVAILABLE', 409)
    }

    const replay = await checkIdempotency(input.groupId, operationKey, requestHash, tx)
    if (replay) return replay

    await assertExpectedVersion(input.groupId, input.expectedVersion, tx)

    const amount = {
      currencyCode: input.currencyCode.toUpperCase(),
      currencyExponent: input.currencyExponent,
      minorUnits: input.minorUnits,
    }

    const transfer = await findMatchingTransfer(
      input.groupId,
      input.planTransferId,
      input.payerParticipantId,
      input.recipientParticipantId,
      amount,
      tx
    )

    await assertCallerCanWrite(input.groupId, input.userId, transfer, tx)

    const payer = await tx.groupParticipant.findUniqueOrThrow({ where: { id: input.payerParticipantId } })
    const recipient = await tx.groupParticipant.findUniqueOrThrow({ where: { id: input.recipientParticipantId } })

    const ledger = await loadGroupLedger(input.groupId, tx)
    const snapshot = allocateSettlementPaths(
      ledger,
      input.payerParticipantId,
      input.recipientParticipantId,
      amount,
      transfer.mode
    )

    const floatAmount = dualWriteFloat(amount)
    const transaction = await tx.transaction.create({
      data: {
        senderId: payer.userId,
        receiverId: recipient.userId,
        amount: floatAmount,
        amountMinorUnits: amount.minorUnits,
        currencyExponent: amount.currencyExponent,
        currency: amount.currencyCode,
        note: input.note,
        groupId: input.groupId,
        payerParticipantId: input.payerParticipantId,
        recipientParticipantId: input.recipientParticipantId,
        actorUserId: input.userId,
        settlementMode: transfer.mode,
      },
    })

    const allocation = await tx.settlementAllocation.create({
      data: {
        groupId: input.groupId,
        transactionId: transaction.id,
        settlementVersion: ledger.settlementVersion,
        mode: transfer.mode,
        currencyCode: amount.currencyCode,
        currencyExponent: amount.currencyExponent,
        amountMinorUnits: amount.minorUnits,
        paths: {
          create: snapshot.paths.map((path, index) => ({
            sequence: index,
            flowMinorUnits: path.flowMinorUnits,
            obligationComponentKey: path.obligationComponentKeys.join(','),
            payerParticipantId: path.payerParticipantId,
            recipientParticipantId: path.recipientParticipantId,
          })),
        },
      },
    })

    const version = await advanceGroupVersion(input.groupId, 'settlement_created', transaction.id, tx)
    await tx.transaction.update({
      where: { id: transaction.id },
      data: { settlementGroupVersion: version },
    })

    const result = { version, recordId: transaction.id, eventType: 'settlement_created' }
    await recordIdempotency(input.groupId, operationKey, requestHash, result, tx)
    return { ...result, transactionId: transaction.id, allocationId: allocation.id }
  })
}
