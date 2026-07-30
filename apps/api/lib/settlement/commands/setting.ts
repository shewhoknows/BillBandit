import { prisma } from '@/lib/prisma'
import {
  advanceGroupVersion,
  assertExpectedVersion,
  checkIdempotency,
  hashRequest,
  recordIdempotency,
  resolveCallerAccess,
  SettlementCommandError,
  type SettlementCommandResult,
} from './core'

export type SettingCommandInput = {
  groupId: string
  userId: string
  idempotencyKey: string
  expectedVersion: number
  simplifyDebts: boolean
}

export async function executeSettingChange(input: SettingCommandInput): Promise<SettlementCommandResult> {
  const requestHash = hashRequest({ simplifyDebts: input.simplifyDebts })
  const operationKey = `setting:${input.idempotencyKey}`

  return prisma.$transaction(async (tx) => {
    const replay = await checkIdempotency(input.groupId, operationKey, requestHash, tx)
    if (replay) return replay

    const access = await resolveCallerAccess(input.groupId, input.userId, tx)
    if (!access.isActiveMember || !access.isAdmin) {
      throw new SettlementCommandError('FORBIDDEN', 403)
    }

    const group = await tx.group.findUniqueOrThrow({
      where: { id: input.groupId },
      select: { simplifyDebts: true, isArchived: true, settlementVersion: true },
    })
    if (group.isArchived) throw new SettlementCommandError('GROUP_ARCHIVED', 403)

    if (group.simplifyDebts === input.simplifyDebts) {
      return {
        version: group.settlementVersion,
        recordId: '',
        eventType: 'setting_noop',
        noop: true,
      }
    }

    await assertExpectedVersion(input.groupId, input.expectedVersion, tx)

    const audit = await tx.settlementSettingAudit.create({
      data: {
        groupId: input.groupId,
        actorUserId: input.userId,
        simplifyDebts: input.simplifyDebts,
      },
    })

    await tx.group.update({
      where: { id: input.groupId },
      data: { simplifyDebts: input.simplifyDebts },
    })

    const version = await advanceGroupVersion(input.groupId, 'setting_changed', audit.id, tx)
    const result = { version, recordId: audit.id, eventType: 'setting_changed' }
    await recordIdempotency(input.groupId, operationKey, requestHash, result, tx)
    return { ...result, noop: false }
  })
}
