import { startOutboxDispatcher } from './dispatcher'
import { createDefaultPusherAdapter, hasPusherCredentials, setPusherAdapter } from './pusher'

const globalForOutbox = globalThis as unknown as {
  __fairshareOutboxBootstrapped?: boolean
}

export function bootstrapSettlementOutbox(): void {
  if (globalForOutbox.__fairshareOutboxBootstrapped) return
  globalForOutbox.__fairshareOutboxBootstrapped = true

  if (!hasPusherCredentials()) {
    return
  }

  setPusherAdapter(createDefaultPusherAdapter())
  startOutboxDispatcher()
}

export function resetOutboxBootstrapForTests(): void {
  globalForOutbox.__fairshareOutboxBootstrapped = false
}
