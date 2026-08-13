import { randomInt } from 'node:crypto'
import { Prisma, type PrismaClient } from '@prisma/client'
import { prisma } from './prisma'
import { profileDisplayName } from './profile-display-name'

type FriendDb = PrismaClient | Prisma.TransactionClient

export const FRIEND_INVITE_CODE_LENGTH = 5
export const FRIEND_INVITE_TTL_SECONDS = 7 * 24 * 60 * 60
export const FRIEND_INVITE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
export const FRIEND_CLAIM_FAILURE_LIMIT = 10
export const FRIEND_CLAIM_WINDOW_SECONDS = 15 * 60

const friendProfileSelect = {
  id: true,
  username: true,
  name: true,
  preferredName: true,
  image: true,
  deletedAt: true,
} as const

export type FriendProfile = {
  id: string
  username: string | null
  name: string | null
  preferredName: string | null
  image: string | null
}

export type FriendInvitationView = {
  code: string
  createdAt: Date
  expiresAt: Date
  status: 'active'
}

export type FriendClaimResult = {
  friend: FriendProfile
  created: boolean
}

export type FriendServiceErrorCode =
  | 'friend_account_not_found'
  | 'friend_invitation_invalid'
  | 'friend_invitation_not_found'
  | 'friend_invitation_expired'
  | 'friend_invitation_own_code'
  | 'friend_claim_rate_limited'
  | 'friend_not_found'
  | 'friend_invitation_unavailable'

export class FriendServiceError extends Error {
  readonly code: FriendServiceErrorCode
  readonly status: number
  readonly retryAfterSeconds?: number

  constructor(
    code: FriendServiceErrorCode,
    status: number,
    message: string,
    options: { retryAfterSeconds?: number } = {}
  ) {
    super(message)
    this.name = 'FriendServiceError'
    this.code = code
    this.status = status
    this.retryAfterSeconds = options.retryAfterSeconds
  }
}

function rateLimitError(blockedUntil: Date, now: Date): FriendServiceError {
  const retryAfterSeconds = Math.max(
    1,
    Math.ceil((blockedUntil.getTime() - now.getTime()) / 1000)
  )
  return new FriendServiceError(
    'friend_claim_rate_limited',
    429,
    `Too many failed friend code attempts. Try again in ${retryAfterSeconds} seconds.`,
    { retryAfterSeconds }
  )
}

async function assertFriendClaimAllowed(
  accountId: string,
  now: Date,
  db: FriendDb
): Promise<void> {
  const rateLimit = await db.friendClaimRateLimit.findUnique({ where: { accountId } })
  if (rateLimit?.blockedUntil && rateLimit.blockedUntil > now) {
    throw rateLimitError(rateLimit.blockedUntil, now)
  }
}

async function recordFriendClaimFailure(
  accountId: string,
  now: Date,
  db: FriendDb
): Promise<void> {
  const windowCutoff = new Date(now.getTime() - FRIEND_CLAIM_WINDOW_SECONDS * 1000)
  const blockedUntil = new Date(now.getTime() + FRIEND_CLAIM_WINDOW_SECONDS * 1000)
  const nowEpochMilliseconds = now.getTime()
  const windowCutoffEpochMilliseconds = windowCutoff.getTime()
  const blockedUntilEpochMilliseconds = blockedUntil.getTime()
  const rows = await db.$queryRaw<Array<{ failureCount: number; blocked: boolean }>>(
    Prisma.sql`
      INSERT INTO "FriendClaimRateLimit" (
        "accountId", "windowStartedAt", "failureCount", "blockedUntil", "updatedAt"
      ) VALUES (
        ${accountId},
        to_timestamp(${nowEpochMilliseconds}::double precision / 1000.0) AT TIME ZONE 'UTC',
        1,
        NULL,
        to_timestamp(${nowEpochMilliseconds}::double precision / 1000.0) AT TIME ZONE 'UTC'
      )
      ON CONFLICT ("accountId") DO UPDATE SET
        "windowStartedAt" = CASE
          WHEN "FriendClaimRateLimit"."windowStartedAt" <=
            to_timestamp(${windowCutoffEpochMilliseconds}::double precision / 1000.0) AT TIME ZONE 'UTC'
            THEN to_timestamp(${nowEpochMilliseconds}::double precision / 1000.0) AT TIME ZONE 'UTC'
          ELSE "FriendClaimRateLimit"."windowStartedAt"
        END,
        "failureCount" = CASE
          WHEN "FriendClaimRateLimit"."windowStartedAt" <=
            to_timestamp(${windowCutoffEpochMilliseconds}::double precision / 1000.0) AT TIME ZONE 'UTC'
            THEN 1
          ELSE "FriendClaimRateLimit"."failureCount" + 1
        END,
        "blockedUntil" = CASE
          WHEN "FriendClaimRateLimit"."windowStartedAt" <=
            to_timestamp(${windowCutoffEpochMilliseconds}::double precision / 1000.0) AT TIME ZONE 'UTC'
            THEN NULL
          WHEN "FriendClaimRateLimit"."failureCount" + 1 >= ${FRIEND_CLAIM_FAILURE_LIMIT}
            THEN to_timestamp(${blockedUntilEpochMilliseconds}::double precision / 1000.0) AT TIME ZONE 'UTC'
          ELSE "FriendClaimRateLimit"."blockedUntil"
        END,
        "updatedAt" =
          to_timestamp(${nowEpochMilliseconds}::double precision / 1000.0) AT TIME ZONE 'UTC'
      RETURNING
        "failureCount",
        "blockedUntil" IS NOT NULL AND "blockedUntil" >
          to_timestamp(${nowEpochMilliseconds}::double precision / 1000.0) AT TIME ZONE 'UTC'
          AS "blocked"
    `
  )
  const rateLimit = rows[0]
  if (rateLimit?.blocked) {
    // Use the JavaScript value here. Raw timestamp-without-time-zone results
    // otherwise depend on the API process timezone.
    throw rateLimitError(blockedUntil, now)
  }
}

function publicProfile(user: {
  id: string
  username: string | null
  name: string | null
  preferredName: string | null
  image: string | null
}): FriendProfile {
  return {
    id: user.id,
    username: user.username,
    name: user.name,
    preferredName: user.preferredName,
    image: user.image,
  }
}

function isUniqueConstraint(error: unknown) {
  return error instanceof Prisma.PrismaClientKnownRequestError && error.code === 'P2002'
}

export function normalizeFriendInviteCode(value: unknown): string {
  if (typeof value !== 'string') return ''
  const allowed = new Set(FRIEND_INVITE_ALPHABET)
  return [...value.toUpperCase()].filter((character) => allowed.has(character)).join('')
}

export function isValidFriendInviteCode(value: unknown): boolean {
  return normalizeFriendInviteCode(value).length === FRIEND_INVITE_CODE_LENGTH
}

export function generateFriendInviteCode(): string {
  return Array.from(
    { length: FRIEND_INVITE_CODE_LENGTH },
    () => FRIEND_INVITE_ALPHABET[randomInt(FRIEND_INVITE_ALPHABET.length)]
  ).join('')
}

/**
 * Store every friendship in one direction. The unique (fromId, toId) key then
 * prevents a concurrent reverse-direction write from making a second row.
 */
export function normalizedFriendPair(leftAccountId: string, rightAccountId: string) {
  const [fromId, toId] = [leftAccountId, rightAccountId].sort()
  return { fromId, toId }
}

function invitationView(invitation: {
  code: string
  createdAt: Date
  expiresAt: Date
}): FriendInvitationView {
  return {
    code: invitation.code,
    createdAt: invitation.createdAt,
    expiresAt: invitation.expiresAt,
    status: 'active',
  }
}

/**
 * Return the caller's current reusable code, or rotate it after expiry. One
 * account has at most one current code. A code collision is retried without
 * changing any other account's invitation.
 */
export async function createFriendInvitation(
  inviterId: string,
  options: {
    now?: Date
    expiresInSeconds?: number
    codeGenerator?: () => string
    db?: FriendDb
  } = {}
): Promise<FriendInvitationView> {
  const db = options.db ?? prisma
  const now = options.now ?? new Date()
  const expiresInSeconds = options.expiresInSeconds ?? FRIEND_INVITE_TTL_SECONDS
  const codeGenerator = options.codeGenerator ?? generateFriendInviteCode
  if (!Number.isSafeInteger(expiresInSeconds) || expiresInSeconds < 1) {
    throw new FriendServiceError(
      'friend_invitation_invalid',
      400,
      'Invitation expiry must be a positive whole number of seconds.'
    )
  }

  const inviter = await db.user.findUnique({
    where: { id: inviterId },
    select: { id: true, deletedAt: true },
  })
  if (!inviter || inviter.deletedAt) {
    throw new FriendServiceError('friend_account_not_found', 404, 'Account not found.')
  }

  for (let attempt = 0; attempt < 12; attempt += 1) {
    const current = await db.friendInvitation.findUnique({ where: { inviterId } })
    if (current && current.expiresAt > now) return invitationView(current)

    const code = normalizeFriendInviteCode(codeGenerator())
    if (!isValidFriendInviteCode(code)) {
      throw new FriendServiceError(
        'friend_invitation_invalid',
        500,
        'The invitation code generator returned an invalid code.'
      )
    }
    const expiresAt = new Date(now.getTime() + expiresInSeconds * 1000)

    try {
      if (current) {
        const rotated = await db.friendInvitation.updateMany({
          where: { inviterId, expiresAt: { lte: now } },
          data: { code, createdAt: now, expiresAt },
        })
        if (rotated.count === 1) {
          const saved = await db.friendInvitation.findUniqueOrThrow({ where: { inviterId } })
          return invitationView(saved)
        }
        const winner = await db.friendInvitation.findUnique({ where: { inviterId } })
        if (winner && winner.expiresAt > now) return invitationView(winner)
        continue
      }

      const saved = await db.friendInvitation.create({
        data: { inviterId, code, createdAt: now, expiresAt },
      })
      return invitationView(saved)
    } catch (error) {
      if (!isUniqueConstraint(error)) throw error
      // Either another invitation owns the random code, or a concurrent request
      // created this account's row. Re-read the row and retry safely.
    }
  }

  throw new FriendServiceError(
    'friend_invitation_unavailable',
    503,
    'Could not allocate a friend invitation code. Try again.'
  )
}

export async function claimFriendInvitation(
  acceptingAccountId: string,
  rawCode: string,
  options: { now?: Date; db?: FriendDb } = {}
): Promise<FriendClaimResult> {
  const db = options.db ?? prisma
  const now = options.now ?? new Date()
  const acceptingAccount = await db.user.findUnique({
    where: { id: acceptingAccountId },
    select: { id: true, deletedAt: true },
  })
  if (!acceptingAccount || acceptingAccount.deletedAt) {
    throw new FriendServiceError('friend_account_not_found', 404, 'Account not found.')
  }
  await assertFriendClaimAllowed(acceptingAccountId, now, db)

  const code = normalizeFriendInviteCode(rawCode)
  if (!isValidFriendInviteCode(code)) {
    const error = new FriendServiceError(
      'friend_invitation_invalid',
      400,
      'Enter a complete 5-character invitation code.'
    )
    await recordFriendClaimFailure(acceptingAccountId, now, db)
    throw error
  }

  const invitation = await db.friendInvitation.findUnique({
    where: { code },
    include: { inviter: { select: friendProfileSelect } },
  })
  if (!invitation || invitation.inviter.deletedAt) {
    const error = new FriendServiceError(
      'friend_invitation_not_found',
      404,
      'That invitation was not found.'
    )
    await recordFriendClaimFailure(acceptingAccountId, now, db)
    throw error
  }
  if (invitation.expiresAt <= now) {
    const error = new FriendServiceError(
      'friend_invitation_expired',
      410,
      'That invitation has expired. Ask your friend for a new code.'
    )
    await recordFriendClaimFailure(acceptingAccountId, now, db)
    throw error
  }
  if (invitation.inviterId === acceptingAccountId) {
    const error = new FriendServiceError(
      'friend_invitation_own_code',
      409,
      'You cannot use your own friend invitation.'
    )
    await recordFriendClaimFailure(acceptingAccountId, now, db)
    throw error
  }

  const pair = normalizedFriendPair(acceptingAccountId, invitation.inviterId)
  const existing = await db.friendship.findUnique({ where: { fromId_toId: pair } })
  await db.friendship.upsert({
    where: { fromId_toId: pair },
    create: { ...pair, status: 'ACCEPTED' },
    update: { ...pair, status: 'ACCEPTED' },
  })
  await db.friendClaimRateLimit.deleteMany({ where: { accountId: acceptingAccountId } })

  return {
    friend: publicProfile(invitation.inviter),
    created: existing?.status !== 'ACCEPTED',
  }
}

export async function listAcceptedFriends(
  accountId: string,
  db: FriendDb = prisma
): Promise<FriendProfile[]> {
  const friendships = await db.friendship.findMany({
    where: {
      status: 'ACCEPTED',
      OR: [{ fromId: accountId }, { toId: accountId }],
    },
    include: {
      from: { select: friendProfileSelect },
      to: { select: friendProfileSelect },
    },
  })

  return friendships
    .map((friendship) =>
      friendship.fromId === accountId ? friendship.to : friendship.from
    )
    .filter((friend) => !friend.deletedAt)
    .map(publicProfile)
    .sort((left, right) => {
      const leftName = profileDisplayName(left, left.id)
      const rightName = profileDisplayName(right, right.id)
      return leftName.localeCompare(rightName) || left.id.localeCompare(right.id)
    })
}

/** Delete only the social edge. Group members, participants, and history stay. */
export async function removeFriend(
  accountId: string,
  friendAccountId: string,
  db: FriendDb = prisma
): Promise<boolean> {
  if (!friendAccountId || accountId === friendAccountId) return true
  const pair = normalizedFriendPair(accountId, friendAccountId)
  await db.friendship.deleteMany({ where: pair })
  return true
}

export function friendErrorResponseBody(error: FriendServiceError) {
  return {
    code: error.code,
    error: error.message,
    ...(error.retryAfterSeconds === undefined
      ? {}
      : { retryAfterSeconds: error.retryAfterSeconds }),
  }
}
