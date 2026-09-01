import { createHash } from 'node:crypto'

function canonicalValue(value: unknown, inArray = false): unknown {
  if (typeof value === 'bigint') return value.toString()
  if (value instanceof Date) return value.toISOString()
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new TypeError('Mutation request contains a non-finite number')
    return value
  }
  if (value === undefined) return inArray ? null : undefined
  if (Array.isArray(value)) return value.map((entry) => canonicalValue(entry, true))
  if (value !== null && typeof value === 'object') {
    const object = value as Record<string, unknown>
    return Object.fromEntries(
      Object.keys(object)
        .sort()
        .flatMap((key) => {
          const entry = canonicalValue(object[key])
          return entry === undefined ? [] : [[key, entry]]
        })
    )
  }
  if (typeof value === 'function' || typeof value === 'symbol') {
    throw new TypeError('Mutation request contains a non-JSON value')
  }
  return value
}

/** Stable JSON with sorted object keys and explicit BigInt/Date handling. */
export function canonicalStringify(value: unknown): string {
  const serialized = JSON.stringify(canonicalValue(value))
  if (serialized === undefined) throw new TypeError('Mutation request is not JSON serializable')
  return serialized
}

/** SHA-256 of the canonical request representation, without a hash prefix. */
export function hashCanonicalRequest(value: unknown): string {
  return createHash('sha256').update(canonicalStringify(value)).digest('hex')
}

export const canonicalRequestHash = hashCanonicalRequest
export const stableStringify = canonicalStringify
export const hashRequest = hashCanonicalRequest

export function mutationRequestHash(input: {
  groupId: string
  kind: string
  payload: unknown
}): string {
  return hashCanonicalRequest({
    groupId: input.groupId,
    kind: input.kind,
    payload: input.payload,
  })
}

export const hashMutationRequest = mutationRequestHash

export function canonicalizeRequest(value: unknown): unknown {
  return canonicalValue(value)
}
