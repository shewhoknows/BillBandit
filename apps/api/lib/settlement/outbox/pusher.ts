import Pusher from 'pusher'

export type PusherPublishPayload = {
  eventType: string
  groupId: string
  recordId: string
  version: number
}

export type PusherAdapter = {
  publish(channel: string, payload: PusherPublishPayload): Promise<void>
}

export const SETTLEMENT_INVALIDATION_EVENT = 'settlement-invalidation'

const globalForPusher = globalThis as unknown as {
  __billbanditPusherAdapter?: PusherAdapter | null
  __billbanditPusherClient?: Pusher | null
}

export function setPusherAdapter(next: PusherAdapter | null) {
  globalForPusher.__billbanditPusherAdapter = next
}

export function getPusherAdapter(): PusherAdapter | null {
  return globalForPusher.__billbanditPusherAdapter ?? null
}

export function hasPusherCredentials(): boolean {
  return Boolean(
    process.env.PUSHER_APP_ID &&
      process.env.PUSHER_KEY &&
      process.env.PUSHER_SECRET &&
      process.env.PUSHER_CLUSTER
  )
}

/** Server can sign private-channel auth (credentials present). */
export function isRealtimeAvailable(): boolean {
  return hasPusherCredentials()
}

export function isRealtimeConfigured(): boolean {
  return hasPusherCredentials() && getPusherAdapter() !== null
}

export function privateChannelName(groupId: string): string {
  return `private-group-${groupId}-settle-up`
}

export function sanitizePusherPayload(payload: PusherPublishPayload): PusherPublishPayload {
  return {
    eventType: payload.eventType,
    groupId: payload.groupId,
    recordId: payload.recordId,
    version: payload.version,
  }
}

function getPusherClient(): Pusher {
  if (!hasPusherCredentials()) {
    throw new Error('Pusher credentials missing')
  }
  if (!globalForPusher.__billbanditPusherClient) {
    globalForPusher.__billbanditPusherClient = new Pusher({
      appId: process.env.PUSHER_APP_ID!,
      key: process.env.PUSHER_KEY!,
      secret: process.env.PUSHER_SECRET!,
      cluster: process.env.PUSHER_CLUSTER!,
      useTLS: true,
    })
  }
  return globalForPusher.__billbanditPusherClient
}

export function createDefaultPusherAdapter(): PusherAdapter {
  const client = getPusherClient()
  return {
    async publish(channel, payload) {
      const sanitized = sanitizePusherPayload(payload)
      await client.trigger(channel, SETTLEMENT_INVALIDATION_EVENT, sanitized)
    },
  }
}

export function authorizePrivateChannel(
  socketId: string,
  channelName: string
): { auth: string; channel_data?: string } {
  return getPusherClient().authorizeChannel(socketId, channelName)
}

export async function publishOutboxEvent(
  groupId: string,
  payload: PusherPublishPayload
): Promise<void> {
  const active = getPusherAdapter()
  if (!active || !isRealtimeConfigured()) {
    throw new Error('REALTIME_NOT_CONFIGURED')
  }
  await active.publish(privateChannelName(groupId), sanitizePusherPayload(payload))
}

export function resetPusherClientForTests(): void {
  globalForPusher.__billbanditPusherClient = null
  globalForPusher.__billbanditPusherAdapter = null
}
