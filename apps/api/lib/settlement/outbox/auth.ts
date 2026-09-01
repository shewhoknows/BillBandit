import { derivePermissions, type CallerAccess } from '../access/matrix'
import { privateChannelName } from './pusher'

export type RealtimeAuthFailure = {
  ok: false
  status: number
  error: string
}

export type RealtimeAuthSuccess = {
  ok: true
}

export function validateRealtimeChannelAccess(
  groupId: string,
  channelName: string,
  access: CallerAccess
): RealtimeAuthSuccess | RealtimeAuthFailure {
  const expected = privateChannelName(groupId)
  if (channelName !== expected) {
    return { ok: false, status: 403, error: 'Invalid channel' }
  }

  const permissions = derivePermissions(access)
  if (!permissions.canAuthorizeRealtime) {
    return { ok: false, status: 403, error: 'Forbidden' }
  }

  return { ok: true }
}
