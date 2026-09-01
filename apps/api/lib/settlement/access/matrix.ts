import type { PlanTransfer } from '../ledger/types'

export type CallerAccess = {
  userId: string
  isActiveMember: boolean
  isAdmin: boolean
  participantId: string | null
  participantStatus: 'ACTIVE' | 'DEPARTED' | null
  hasUnsettledPosition: boolean
}

export type CallerPermissions = {
  canReadPlan: boolean
  canReadHistory: boolean
  canSettleOrReverse: boolean
  canChangeSetting: boolean
  canAuthorizeRealtime: boolean
  readScope: 'full' | 'limited' | 'none'
}

export function derivePermissions(access: CallerAccess): CallerPermissions {
  if (!access.participantId) {
    return {
      canReadPlan: false,
      canReadHistory: false,
      canSettleOrReverse: false,
      canChangeSetting: false,
      canAuthorizeRealtime: false,
      readScope: 'none',
    }
  }

  if (access.participantStatus === 'DEPARTED' && !access.hasUnsettledPosition) {
    return {
      canReadPlan: false,
      canReadHistory: false,
      canSettleOrReverse: false,
      canChangeSetting: false,
      canAuthorizeRealtime: false,
      readScope: 'none',
    }
  }

  const isDepartedLimited = access.participantStatus === 'DEPARTED' && access.hasUnsettledPosition

  return {
    canReadPlan: access.isActiveMember || isDepartedLimited,
    canReadHistory: access.isActiveMember || isDepartedLimited,
    canSettleOrReverse: access.isActiveMember || isDepartedLimited,
    canChangeSetting: access.isActiveMember && access.isAdmin,
    canAuthorizeRealtime: access.isActiveMember || isDepartedLimited,
    readScope: access.isActiveMember ? 'full' : 'limited',
  }
}

export function canSettleTransfer(
  access: CallerAccess,
  transfer: PlanTransfer
): boolean {
  if (!access.participantId) return false
  if (access.participantStatus === 'DEPARTED' && !access.hasUnsettledPosition) return false
  return (
    access.participantId === transfer.payerParticipantId ||
    access.participantId === transfer.recipientParticipantId
  )
}

export function filterPlanForCaller(
  transfers: PlanTransfer[],
  access: CallerAccess
): PlanTransfer[] {
  const permissions = derivePermissions(access)
  if (permissions.readScope === 'none') return []
  if (permissions.readScope === 'full') return transfers
  return transfers.filter(
    (t) =>
      t.payerParticipantId === access.participantId ||
      t.recipientParticipantId === access.participantId
  )
}

export function isTransferParticipant(
  participantId: string | null,
  payerParticipantId: string,
  recipientParticipantId: string
): boolean {
  if (!participantId) return false
  return participantId === payerParticipantId || participantId === recipientParticipantId
}
