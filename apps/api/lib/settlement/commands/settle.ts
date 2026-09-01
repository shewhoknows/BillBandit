import { prisma } from '../../prisma'
import { executeMutation } from '../../ledger/mutation'
import type { PrismaClient } from '@prisma/client'
import type { SettlementCommandResult } from './core'

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
  minorUnits: string | bigint
  note?: string
  db?: PrismaClient
}

export async function executeSettlement(input: SettleCommandInput): Promise<SettlementCommandResult> {
  const result = await executeMutation({
    groupId: input.groupId,
    operationId: `settlement:${input.idempotencyKey}`,
    accountId: input.userId,
    actorUserId: input.userId,
    kind: 'settlement.create',
    expectedRevision: input.expectedVersion,
    payload: {
      planTransferId: input.planTransferId,
      payerParticipantId: input.payerParticipantId,
      recipientParticipantId: input.recipientParticipantId,
      amount: {
        minorUnits: input.minorUnits.toString(),
        currencyCode: input.currencyCode.trim().toUpperCase(),
        currencyExponent: input.currencyExponent,
      },
      note: input.note ?? null,
    },
  }, { db: input.db })

  const allocation = result.recordId
    ? await (input.db ?? prisma).settlementAllocation.findUnique({
        where: { transactionId: result.recordId },
        select: { id: true },
      })
    : null

  return {
    version: result.revision,
    recordId: result.recordId,
    eventType: result.eventType,
    transactionId: result.recordId || undefined,
    allocationId: allocation?.id,
    ...(result.noop ? { noop: true } : {}),
  }
}
