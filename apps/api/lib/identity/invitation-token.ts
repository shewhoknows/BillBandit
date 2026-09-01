import crypto from 'crypto'
import {
  externalIdentity,
  type ExternalIdentityProvider,
  type ExternalIdentityRef,
} from './types'

const TOKEN_VERSION = 1
const DEFAULT_TTL_SECONDS = 7 * 24 * 60 * 60
const MAX_TTL_SECONDS = 30 * 24 * 60 * 60

export type InvitationTokenPayload = {
  v: typeof TOKEN_VERSION
  jti: string
  groupId: string
  issuerAccountId: string
  targetAccountId: string
  provider: ExternalIdentityProvider
  subject: string
  iat: number
  exp: number
}

export type InvitationTokenInput = {
  jti?: string
  groupId: string
  issuerAccountId: string
  targetAccountId: string
  identity: ExternalIdentityRef
  now?: number
  expiresInSeconds?: number
}

export type InvitationTokenVerification =
  | { valid: true; payload: InvitationTokenPayload }
  | {
      valid: false
      code: 'malformed' | 'bad_signature' | 'expired' | 'invalid_payload'
    }

function base64Url(input: Buffer | string) {
  return Buffer.from(input)
    .toString('base64')
    .replace(/=/g, '')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
}

function decodeBase64Url(input: string) {
  const normalized = input.replace(/-/g, '+').replace(/_/g, '/')
  const padding = normalized.length % 4 === 0 ? '' : '='.repeat(4 - (normalized.length % 4))
  return Buffer.from(`${normalized}${padding}`, 'base64').toString('utf8')
}

function invitationSecret() {
  const secret =
    process.env.MOBILE_INVITATION_SECRET ??
    process.env.IDENTITY_INVITATION_SECRET ??
    process.env.MOBILE_INVITE_SECRET ??
    process.env.INVITATION_SECRET ??
    process.env.INVITATION_TOKEN_SECRET ??
    process.env.MOBILE_JWT_SECRET ??
    process.env.NEXTAUTH_SECRET
  if (!secret) {
    throw new Error(
      'An invitation secret (MOBILE_INVITATION_SECRET or INVITATION_TOKEN_SECRET) must be set'
    )
  }
  return secret
}

function sign(unsignedToken: string) {
  return base64Url(crypto.createHmac('sha256', invitationSecret()).update(unsignedToken).digest())
}

function timingSafeEqual(leftValue: string, rightValue: string) {
  const left = Buffer.from(leftValue)
  const right = Buffer.from(rightValue)
  return left.length === right.length && crypto.timingSafeEqual(left, right)
}

function positiveInteger(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value > 0
}

function validPayload(value: unknown): value is InvitationTokenPayload {
  if (!value || typeof value !== 'object') return false
  const payload = value as Record<string, unknown>
  if (payload.v !== TOKEN_VERSION) return false
  if (typeof payload.jti !== 'string' || !payload.jti) return false
  if (typeof payload.groupId !== 'string' || !payload.groupId) return false
  if (typeof payload.issuerAccountId !== 'string' || !payload.issuerAccountId) return false
  if (typeof payload.targetAccountId !== 'string' || !payload.targetAccountId) return false
  if (typeof payload.subject !== 'string' || !payload.subject) return false
  if (!positiveInteger(payload.iat) || !positiveInteger(payload.exp)) return false
  if (payload.exp <= payload.iat) return false

  try {
    externalIdentity(payload.provider, payload.subject)
    return true
  } catch {
    return false
  }
}

export function invitationTokenHash(token: string) {
  return crypto.createHash('sha256').update(token).digest('hex')
}

export function createInvitationToken(input: InvitationTokenInput) {
  const now = input.now ?? Math.floor(Date.now() / 1000)
  const requestedTtl = input.expiresInSeconds ?? DEFAULT_TTL_SECONDS
  if (!positiveInteger(now)) throw new Error('Invitation token time must be a positive integer.')
  if (!positiveInteger(requestedTtl) || requestedTtl > MAX_TTL_SECONDS) {
    throw new Error(`Invitation expiry must be between 1 and ${MAX_TTL_SECONDS} seconds.`)
  }

  const identity = externalIdentity(input.identity.provider, input.identity.subject)
  const payload: InvitationTokenPayload = {
    v: TOKEN_VERSION,
    jti: input.jti ?? crypto.randomUUID(),
    groupId: input.groupId,
    issuerAccountId: input.issuerAccountId,
    targetAccountId: input.targetAccountId,
    provider: identity.provider,
    subject: identity.subject,
    iat: now,
    exp: now + requestedTtl,
  }
  if (!validPayload(payload)) throw new Error('Invalid invitation token payload.')

  const header = base64Url(JSON.stringify({ alg: 'HS256', typ: 'BBI', v: TOKEN_VERSION }))
  const encodedPayload = base64Url(JSON.stringify(payload))
  const unsignedToken = `${header}.${encodedPayload}`
  return `${unsignedToken}.${sign(unsignedToken)}`
}

export function verifyInvitationToken(
  token: string,
  now = Math.floor(Date.now() / 1000)
): InvitationTokenVerification {
  if (typeof token !== 'string') return { valid: false, code: 'malformed' }
  const parts = token.split('.')
  if (parts.length !== 3) return { valid: false, code: 'malformed' }

  const [encodedHeader, encodedPayload, signature] = parts
  let header: unknown
  let payload: unknown
  try {
    header = JSON.parse(decodeBase64Url(encodedHeader))
    payload = JSON.parse(decodeBase64Url(encodedPayload))
  } catch {
    return { valid: false, code: 'malformed' }
  }

  if (
    !header ||
    typeof header !== 'object' ||
    (header as Record<string, unknown>).alg !== 'HS256' ||
    (header as Record<string, unknown>).typ !== 'BBI' ||
    (header as Record<string, unknown>).v !== TOKEN_VERSION
  ) {
    return { valid: false, code: 'malformed' }
  }

  let expected: string
  try {
    expected = sign(`${encodedHeader}.${encodedPayload}`)
  } catch {
    return { valid: false, code: 'bad_signature' }
  }
  if (!timingSafeEqual(signature, expected)) return { valid: false, code: 'bad_signature' }
  if (!validPayload(payload)) return { valid: false, code: 'invalid_payload' }

  const typedPayload = payload as InvitationTokenPayload
  if (!positiveInteger(now) || typedPayload.exp <= now) {
    return { valid: false, code: 'expired' }
  }
  return { valid: true, payload: typedPayload }
}

export function invitationBelongsToAccount(
  payload: InvitationTokenPayload,
  accountId: string
) {
  return payload.targetAccountId === accountId
}

export function invitationIdentity(payload: InvitationTokenPayload): ExternalIdentityRef {
  return externalIdentity(payload.provider, payload.subject)
}

export const issueGroupInvitationToken = createInvitationToken
export const verifyGroupInvitationToken = verifyInvitationToken

export { DEFAULT_TTL_SECONDS as DEFAULT_INVITATION_TTL_SECONDS }
