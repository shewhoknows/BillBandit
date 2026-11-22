import { executeMutation } from '../../ledger/mutation'
import type { PrismaClient } from '@prisma/client'
import { withOperationKeyReplay, type SettlementCommandResult } from './core'

export type SettingsCommandInput = {
  groupId: string
  userId: string
  idempotencyKey: string
  expectedVersion: number
  simplifyDebts: boolean
  db?: PrismaClient
}

/**
 * Turn "simplify debts" on or off for one group.
 *
 * The kernel (`settings.update`) owns the rules: only a group administrator,
 * not in an archived group, against the current revision. A change writes a
 * SettlementSettingAudit row and bumps the revision; sending the value the
 * group already has changes nothing (noop, same revision). The settle-up plan
 * is derived from Group.simplifyDebts on every read, so the new plan shows on
 * the next read. Payments already recorded are not changed.
 */
export async function executeSettingsUpdate(input: SettingsCommandInput): Promise<SettlementCommandResult> {
  const result = await withOperationKeyReplay(() => executeMutation({
    groupId: input.groupId,
    operationId: `settings:${input.idempotencyKey}`,
    accountId: input.userId,
    actorUserId: input.userId,
    kind: 'settings.update',
    expectedRevision: input.expectedVersion,
    payload: { simplifyDebts: input.simplifyDebts },
  }, { db: input.db }))

  return {
    version: result.revision,
    recordId: result.recordId,
    eventType: result.eventType,
    ...(result.noop ? { noop: true } : {}),
  }
}
