import { executeMutation } from '../../ledger/mutation'
import type { PrismaClient } from '@prisma/client'
import type { SettlementCommandResult } from './core'

export type SettingCommandInput = {
  groupId: string
  userId: string
  idempotencyKey: string
  expectedVersion: number
  simplifyDebts: boolean
  db?: PrismaClient
}

export async function executeSettingChange(input: SettingCommandInput): Promise<SettlementCommandResult> {
  const result = await executeMutation({
    groupId: input.groupId,
    operationId: `setting:${input.idempotencyKey}`,
    accountId: input.userId,
    actorUserId: input.userId,
    kind: 'settings.update',
    expectedRevision: input.expectedVersion,
    payload: { simplifyDebts: input.simplifyDebts },
  }, { db: input.db })

  return {
    version: result.revision,
    recordId: result.recordId,
    eventType: result.eventType,
    ...(result.noop ? { noop: true } : { noop: false }),
  }
}
