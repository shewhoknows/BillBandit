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
