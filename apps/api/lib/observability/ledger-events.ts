import { createHash } from 'crypto'

export const LEDGER_EVENT_TYPES = {
  READ: 'ledger_read',
  MUTATION: 'ledger_mutation',
  REPLAY: 'ledger_replay',
  CONFLICT: 'ledger_conflict',
  QUEUE_DEPTH: 'ledger_queue_depth',
  IMPORT: 'ledger_import',
  PARITY_MISMATCH: 'ledger_parity_mismatch',
  GATE_DECISION: 'ledger_gate_decision',
} as const

export type LedgerEventType = (typeof LEDGER_EVENT_TYPES)[keyof typeof LEDGER_EVENT_TYPES]

type LedgerEventTypeInput =
  | LedgerEventType
  | 'read'
  | 'mutation'
  | 'replay'
  | 'conflict'
  | 'queue_depth'
  | 'import'
  | 'parity_mismatch'
  | 'gate_decision'

export type LedgerEventPayload = Record<string, unknown>

export type LedgerTelemetryEvent = {
  schemaVersion: 1
  eventType: LedgerEventType
  occurredAt: string
  payload: LedgerEventPayload
}

export type LedgerEventOptions = {
  occurredAt?: Date | string
  hashSalt?: string
}

export type LedgerEventSink = (event: LedgerTelemetryEvent) => void

const EVENT_TYPE_ALIASES: Readonly<Record<string, LedgerEventType>> = {
  read: LEDGER_EVENT_TYPES.READ,
  ledger_read: LEDGER_EVENT_TYPES.READ,
  'ledger.read': LEDGER_EVENT_TYPES.READ,
  mutation: LEDGER_EVENT_TYPES.MUTATION,
  ledger_mutation: LEDGER_EVENT_TYPES.MUTATION,
  'ledger.mutation': LEDGER_EVENT_TYPES.MUTATION,
  replay: LEDGER_EVENT_TYPES.REPLAY,
  ledger_replay: LEDGER_EVENT_TYPES.REPLAY,
  'ledger.replay': LEDGER_EVENT_TYPES.REPLAY,
  conflict: LEDGER_EVENT_TYPES.CONFLICT,
  ledger_conflict: LEDGER_EVENT_TYPES.CONFLICT,
  'ledger.conflict': LEDGER_EVENT_TYPES.CONFLICT,
  queue_depth: LEDGER_EVENT_TYPES.QUEUE_DEPTH,
  ledger_queue_depth: LEDGER_EVENT_TYPES.QUEUE_DEPTH,
  'ledger.queue_depth': LEDGER_EVENT_TYPES.QUEUE_DEPTH,
  import: LEDGER_EVENT_TYPES.IMPORT,
  ledger_import: LEDGER_EVENT_TYPES.IMPORT,
  'ledger.import': LEDGER_EVENT_TYPES.IMPORT,
  parity_mismatch: LEDGER_EVENT_TYPES.PARITY_MISMATCH,
  ledger_parity_mismatch: LEDGER_EVENT_TYPES.PARITY_MISMATCH,
  'ledger.parity_mismatch': LEDGER_EVENT_TYPES.PARITY_MISMATCH,
  gate_decision: LEDGER_EVENT_TYPES.GATE_DECISION,
  ledger_gate_decision: LEDGER_EVENT_TYPES.GATE_DECISION,
  'ledger.gate_decision': LEDGER_EVENT_TYPES.GATE_DECISION,
}

const IDENTIFIER_KEY_PATTERN =
  /^(?:id|account[_-]?id|group[_-]?id|user[_-]?id|member[_-]?id|participant[_-]?id|operation[_-]?(?:id|key)|record[_-]?id|transaction[_-]?id|expense[_-]?id|settlement[_-]?id|request[_-]?(?:id|key)|client[_-]?id|source[_-]?id|import[_-]?id|idempotency[_-]?(?:id|key))$/i

const REDACTED_KEY_PATTERN =
  /^(?:email|apple[_-]?(?:subject|id|token)|identity[_-]?token|access[_-]?token|refresh[_-]?token|authorization|bearer|token|secret|password|nonce|cookie|credential|jwt|private[_-]?key|raw[_-]?payload|claims?)$/i

const MONEY_KEY_PATTERN =
  /^(?:amount|amount[_-]?(?:minor|major)[_-]?units?|minor[_-]?units|major[_-]?units|money|currency|currency[_-]?code|balance|total|subtotal|price|cost|payment|split(?:s|[_-]?amounts?)?|allocation[_-]?amount)$/i

const UNSAFE_CONTAINER_KEY_PATTERN =
  /^(?:body|headers?|request|response|ledger|entries|line[_-]?items?|raw|metadata|details|input|output)$/i

const SAFE_STRING_KEY_PATTERN =
  /^(?:authority[_-]?mode|client[_-]?version|contract[_-]?version|current[_-]?revision|decision|duration[_-]?ms|environment|error[_-]?code|event[_-]?type|from[_-]?revision|http[_-]?status|import[_-]?state|migration[_-]?state|mode|mutation[_-]?type|operation[_-]?type|outcome|parity[_-]?type|platform|reason(?:[_-]?code)?|read[_-]?type|result|rollout[_-]?cohort|source|status|to[_-]?revision|version|version[_-]?range)$/i

const SAFE_NUMBER_KEY_PATTERN =
  /^(?:attempt(?:s)?|client[_-]?build|contract[_-]?version|count|current[_-]?revision|duration[_-]?ms|expected[_-]?revision|from[_-]?revision|http[_-]?status|minimum[_-]?client[_-]?build|queue[_-]?depth|retry(?:[_-]?count)?|to[_-]?revision|version)$/i

const SAFE_BOOLEAN_KEY_PATTERN =
  /^(?:allowed|complete|enforced|enforcement[_-]?enabled|migration[_-]?required|read[_-]?only|replayed|success|supported)$/i

function hashMaterial(value: string, salt?: string): string {
  const configuredSalt = salt ?? process.env.LEDGER_TELEMETRY_HASH_SALT ?? ''
  const material = configuredSalt ? `${configuredSalt}:${value}` : value
  return `sha256:${createHash('sha256').update(material).digest('hex')}`
}

export function hashLedgerIdentifier(value: string, salt?: string): string {
  return hashMaterial(value, salt)
}

function isSensitiveString(value: string): boolean {
  return (
    /[^\s@]+@[^\s@]+\.[^\s@]+/.test(value) ||
    /^Bearer\s+\S+$/i.test(value) ||
    /^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(value) ||
    /^(?:token|secret|password|nonce)[:=]/i.test(value)
  )
}

function normalizeKey(key: string): string {
  return key.replace(/([a-z])([A-Z])/g, '$1_$2').replace(/-/g, '_').toLowerCase()
}

function sanitizeValue(key: string, value: unknown, options: LedgerEventOptions): unknown {
  const normalizedKey = normalizeKey(key)

  if (IDENTIFIER_KEY_PATTERN.test(normalizedKey)) {
    return typeof value === 'string' || typeof value === 'number'
      ? hashLedgerIdentifier(String(value), options.hashSalt)
      : undefined
  }

  if (REDACTED_KEY_PATTERN.test(normalizedKey) || MONEY_KEY_PATTERN.test(normalizedKey)) {
    return undefined
  }

  if (UNSAFE_CONTAINER_KEY_PATTERN.test(normalizedKey)) {
    return undefined
  }

  if (value === null || value === undefined) return undefined

  if (typeof value === 'string') {
    if (isSensitiveString(value)) return undefined
    return SAFE_STRING_KEY_PATTERN.test(normalizedKey) ? value : undefined
  }

  if (typeof value === 'number') {
    if (!Number.isFinite(value)) return undefined
    return SAFE_NUMBER_KEY_PATTERN.test(normalizedKey) ? value : undefined
  }

  if (typeof value === 'boolean') {
    return SAFE_BOOLEAN_KEY_PATTERN.test(normalizedKey) ? value : undefined
  }

  if (Array.isArray(value)) {
    if (!SAFE_STRING_KEY_PATTERN.test(normalizedKey)) return undefined
    const sanitized = value
      .map((item) => sanitizeValue('value', item, options))
      .filter((item): item is string | number | boolean | LedgerEventPayload => item !== undefined)
    return sanitized.length > 0 ? sanitized : undefined
  }

  if (typeof value === 'object') {
    const sanitized = sanitizeObject(value as Record<string, unknown>, options)
    return Object.keys(sanitized).length > 0 ? sanitized : undefined
  }

  return undefined
}

function sanitizeObject(input: Record<string, unknown>, options: LedgerEventOptions): LedgerEventPayload {
  const output: LedgerEventPayload = {}
  for (const [key, value] of Object.entries(input)) {
    const sanitized = sanitizeValue(key, value, options)
    if (sanitized !== undefined) output[key] = sanitized
  }
  return output
}

export function sanitizeLedgerEventPayload(
  payload: Record<string, unknown>,
  options: LedgerEventOptions = {}
): LedgerEventPayload {
  return sanitizeObject(payload, options)
}

function normalizeEventType(eventType: LedgerEventTypeInput): LedgerEventType {
  const normalized = EVENT_TYPE_ALIASES[String(eventType).toLowerCase()]
  if (!normalized) throw new Error(`Unknown ledger event type: ${String(eventType)}`)
  return normalized
}

function eventTimestamp(value?: Date | string): string {
  if (value instanceof Date) return value.toISOString()
  if (typeof value === 'string') {
    const parsed = new Date(value)
    if (!Number.isNaN(parsed.getTime())) return parsed.toISOString()
  }
  return new Date().toISOString()
}

export function createLedgerEvent(
  eventType: LedgerEventTypeInput,
  payload: Record<string, unknown> = {},
  options: LedgerEventOptions = {}
): LedgerTelemetryEvent {
  return {
    schemaVersion: 1,
    eventType: normalizeEventType(eventType),
    occurredAt: eventTimestamp(options.occurredAt),
    payload: sanitizeLedgerEventPayload(payload, options),
  }
}

export const buildLedgerEvent = createLedgerEvent

export function emitLedgerEvent(
  eventType: LedgerEventTypeInput,
  payload: Record<string, unknown> = {},
  sink: LedgerEventSink = (event) => console.info(JSON.stringify(event)),
  options: LedgerEventOptions = {}
): LedgerTelemetryEvent {
  const event = createLedgerEvent(eventType, payload, options)
  sink(event)
  return event
}

function createTypedEvent(
  eventType: LedgerEventType,
  payload: Record<string, unknown>,
  options?: LedgerEventOptions
): LedgerTelemetryEvent {
  return createLedgerEvent(eventType, payload, options)
}

export const createLedgerReadEvent = (payload: LedgerEventPayload, options?: LedgerEventOptions) =>
  createTypedEvent(LEDGER_EVENT_TYPES.READ, payload, options)

export const createLedgerMutationEvent = (payload: LedgerEventPayload, options?: LedgerEventOptions) =>
  createTypedEvent(LEDGER_EVENT_TYPES.MUTATION, payload, options)

export const createLedgerReplayEvent = (payload: LedgerEventPayload, options?: LedgerEventOptions) =>
  createTypedEvent(LEDGER_EVENT_TYPES.REPLAY, payload, options)

export const createLedgerConflictEvent = (payload: LedgerEventPayload, options?: LedgerEventOptions) =>
  createTypedEvent(LEDGER_EVENT_TYPES.CONFLICT, payload, options)

export const createLedgerQueueDepthEvent = (payload: LedgerEventPayload, options?: LedgerEventOptions) =>
  createTypedEvent(LEDGER_EVENT_TYPES.QUEUE_DEPTH, payload, options)

export const createLedgerImportEvent = (payload: LedgerEventPayload, options?: LedgerEventOptions) =>
  createTypedEvent(LEDGER_EVENT_TYPES.IMPORT, payload, options)

export const createLedgerParityMismatchEvent = (
  payload: LedgerEventPayload,
  options?: LedgerEventOptions
) => createTypedEvent(LEDGER_EVENT_TYPES.PARITY_MISMATCH, payload, options)

export const createLedgerGateDecisionEvent = (
  payload: LedgerEventPayload,
  options?: LedgerEventOptions
) => createTypedEvent(LEDGER_EVENT_TYPES.GATE_DECISION, payload, options)
