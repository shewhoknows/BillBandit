import { executeMutation } from '../../ledger/mutation'
import type { PrismaClient } from '@prisma/client'
import type { SettlementCommandResult } from './core'

export type ReverseCommandInput = {
  groupId: string
  userId: string
  settlementId: string
  idempotencyKey: string
  expectedVersion: number
  db?: PrismaClient
}

export async function executeReversal(input: ReverseCommandInput): Promise<SettlementCommandResult> {
  const result = await executeMutation({
    groupId: input.groupId,
    operationId: `reversal:${input.idempotencyKey}`,
    accountId: input.userId,
    actorUserId: input.userId,
    kind: 'settlement.reverse',
    expectedRevision: input.expectedVersion,
    payload: { settlementId: input.settlementId },
  }, { db: input.db })

  return {
    version: result.revision,
    recordId: result.recordId,
    eventType: result.eventType,
    reversalId: result.recordId || undefined,
  }
}
