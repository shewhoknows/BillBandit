import { createHash } from 'node:crypto'

function sortJson(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortJson)
  if (value !== null && typeof value === 'object') {
    const object = value as Record<string, unknown>
    return Object.fromEntries(
      Object.keys(object)
        .sort()
        .map((key) => [key, sortJson(object[key])])
    )
  }
  return value
}

/** Stable JSON is used for request hashes and deterministic fixture snapshots. */
export function stableStringify(value: unknown, space?: number): string {
  const serialized = JSON.stringify(sortJson(value), null, space)
  if (serialized === undefined) throw new TypeError('Value is not JSON serializable')
  return serialized
}

export function roundTripJson<T>(value: T): T {
  return JSON.parse(stableStringify(value)) as T
}

export function hashLedgerRequest(value: unknown): string {
  return createHash('sha256').update(stableStringify(value)).digest('hex')
}
