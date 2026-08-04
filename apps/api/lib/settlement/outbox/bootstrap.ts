import { startOutboxDispatcher } from './dispatcher'
import { createDefaultPusherAdapter, hasPusherCredentials, setPusherAdapter } from './pusher'

const globalForOutbox = globalThis as unknown as {
  __billbanditOutboxBootstrapped?: boolean
}

export function bootstrapSettlementOutbox(): void {
  if (globalForOutbox.__billbanditOutboxBootstrapped) return
  globalForOutbox.__billbanditOutboxBootstrapped = true

  if (!hasPusherCredentials()) {
    return
  }

  setPusherAdapter(createDefaultPusherAdapter())
  startOutboxDispatcher()
}

export function resetOutboxBootstrapForTests(): void {
  globalForOutbox.__billbanditOutboxBootstrapped = false
}
