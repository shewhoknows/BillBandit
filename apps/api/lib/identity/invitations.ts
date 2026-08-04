import { Prisma } from '@prisma/client'
import type { PrismaClient } from '@prisma/client'
import { prisma } from '../prisma'
import {
  resolveExternalIdentity,
  resolveOrBackfillAppleIdentity,
  type ResolvedExternalIdentity,
} from './external-identities'
import {
  createInvitationToken,
  invitationBelongsToAccount,
  invitationTokenHash,
  verifyInvitationToken,
  type InvitationTokenPayload,
} from './invitation-token'
import {
  externalIdentity,
  type ExternalIdentityProvider,
  type ExternalIdentityRef,
} from './types'

type IdentityAndInvitationDb = PrismaClient | Prisma.TransactionClient

export type InvitationFlowErrorCode =
  | 'invalid_invitation_request'
  | 'group_forbidden'
  | 'group_finalized'
  | 'group_not_found'
  | 'identity_not_registered'
  | 'identity_repair_required'
  | 'invitation_invalid'
  | 'invitation_expired'
  | 'invitation_not_found'
  | 'invitation_wrong_account'
  | 'invitation_already_used'

export class InvitationFlowError extends Error {
  readonly code: InvitationFlowErrorCode
  readonly status: number
  readonly details?: Record<string, unknown>

  constructor(
    code: InvitationFlowErrorCode,
    status: number,
    message: string,
    details?: Record<string, unknown>
  ) {
    super(message)
    this.name = 'InvitationFlowError'
    this.code = code
    this.status = status
    this.details = details
  }
}

export type CreateGroupInvitationInput = {
  groupId: string
  issuerAccountId: string
  identity: ExternalIdentityRef
  expiresInSeconds?: number
  now?: number
  db?: IdentityAndInvitationDb
}

export type CreatedGroupInvitation = {
  token: string
  invitation: {
    id: string
    groupId: string
    issuerAccountId: string
    targetAccountId: string
    provider: ExternalIdentityProvider
    subject: string
    expiresAt: Date
    status: 'pending'
  }
}

export type ClaimedGroupMember = {
  id: string
  groupId: string
  userId: string
  role: string
  joinedAt: Date
  user: {
    id: string
    name: string | null
    email: string
    image: string | null
  }
}

export type ClaimedGroupInvitation = {
  payload: InvitationTokenPayload
  member: ClaimedGroupMember
  created: boolean
}

function isUniqueConstraint(error: unknown) {
  return error instanceof Prisma.PrismaClientKnownRequestError && error.code === 'P2002'
}

async function resolveInvitationTarget(
  identity: ExternalIdentityRef,
  db: IdentityAndInvitationDb
): Promise<ResolvedExternalIdentity> {
  const resolved =
    identity.provider === 'apple'
      ? await resolveOrBackfillAppleIdentity(identity.subject, db)
      : await resolveExternalIdentity(identity.provider, identity.subject, db)

  if (!resolved) {
    throw new InvitationFlowError(
      'identity_not_registered',
      404,
      'The accepting account must be linked to this external identity before it can be invited.'
    )
  }
  return resolved
}

async function withTransaction<T>(
  db: IdentityAndInvitationDb,
  callback: (tx: Prisma.TransactionClient) => Promise<T>
): Promise<T> {
  if (!('$transaction' in db)) {
    return callback(db as Prisma.TransactionClient)
  }

  const client = db as PrismaClient
  return client.$transaction(callback)
}

/**
 * Issue a signed invitation for an already mapped account. The invitation is
 * persisted as a pending LedgerOperation; its hash is stored, never the raw
 * bearer token. This lets claim atomically consume it without introducing a
 * second invitation table or a second identity key.
 */
export async function createGroupInvitation({
  groupId,
  issuerAccountId,
  identity,
  expiresInSeconds,
  now,
  db = prisma,
}: CreateGroupInvitationInput): Promise<CreatedGroupInvitation> {
  const normalizedIdentity = externalIdentity(identity.provider, identity.subject)
  const membership = await db.groupMember.findUnique({
    where: {
      groupId_userId: {
        groupId,
        userId: issuerAccountId,
      },
    },
    select: {
      group: { select: { id: true, finalizedAt: true } },
    },
  })
  if (!membership) {
    throw new InvitationFlowError(
      'group_forbidden',
      403,
      'You must be a member of this group to create an invitation.'
    )
  }
  if (membership.group.finalizedAt) {
    throw new InvitationFlowError('group_finalized', 409, 'Group is finalized.')
  }

  const target = await resolveInvitationTarget(normalizedIdentity, db)
  const token = createInvitationToken({
    groupId,
    issuerAccountId,
    targetAccountId: target.accountId,
    identity: target.identity,
    now,
    expiresInSeconds,
  })
  const payload = verifyInvitationToken(token, now ?? Math.floor(Date.now() / 1000))
  if (!payload.valid) {
    throw new InvitationFlowError(
      'invitation_invalid',
      500,
      'Could not create a valid invitation token.'
    )
  }

  await db.ledgerOperation.create({
    data: {
      id: payload.payload.jti,
      accountId: issuerAccountId,
      groupId,
      operationKey: `group-invitation:${payload.payload.jti}`,
      requestHash: invitationTokenHash(token),
      state: 'PENDING',
    },
  })

  return {
    token,
    invitation: {
      id: payload.payload.jti,
      groupId,
      issuerAccountId,
      targetAccountId: target.accountId,
      provider: target.identity.provider,
      subject: target.identity.subject,
      expiresAt: new Date(payload.payload.exp * 1000),
      status: 'pending',
    },
  }
}

function invalidTokenError(code: 'malformed' | 'bad_signature' | 'invalid_payload') {
  return new InvitationFlowError(
    'invitation_invalid',
    400,
    'This invitation link is invalid.',
    { verification: code }
  )
}

export type ClaimGroupInvitationInput = {
  token: string
  acceptingAccountId: string
  now?: number
  db?: IdentityAndInvitationDb
}

/**
 * Consume an invitation and create the GroupMember row using only the
 * accepting API User.id. The operation reservation happens before the member
 * write in the same transaction, so concurrent requests cannot both consume
 * the token. A pre-existing membership is returned idempotently, while a
 * second use of the same consumed token is rejected as replay.
 */
export async function claimGroupInvitation({
  token,
  acceptingAccountId,
  now,
  db = prisma,
}: ClaimGroupInvitationInput): Promise<ClaimedGroupInvitation> {
  const verification = verifyInvitationToken(token, now ?? Math.floor(Date.now() / 1000))
  if (!verification.valid) {
    if (verification.code === 'expired') {
      throw new InvitationFlowError('invitation_expired', 410, 'This invitation has expired.')
    }
    if (verification.code === 'malformed' || verification.code === 'bad_signature') {
      throw invalidTokenError(verification.code)
    }
    throw invalidTokenError('invalid_payload')
  }

  const payload = verification.payload
  if (!invitationBelongsToAccount(payload, acceptingAccountId)) {
    throw new InvitationFlowError(
      'invitation_wrong_account',
      403,
      'This invitation belongs to a different account.'
    )
  }

  const mappedIdentity =
    payload.provider === 'apple'
      ? await resolveOrBackfillAppleIdentity(payload.subject, db)
      : await resolveExternalIdentity(payload.provider, payload.subject, db)
  if (!mappedIdentity) {
    throw new InvitationFlowError(
      'identity_repair_required',
      409,
      'This identity needs repair before the membership can be claimed.',
      { state: 'repair_required', provider: payload.provider }
    )
  }
  if (mappedIdentity.accountId !== acceptingAccountId) {
    throw new InvitationFlowError(
      'identity_repair_required',
      409,
      'This external identity is linked to a different account and needs repair.',
      {
        state: 'repair_required',
        provider: payload.provider,
        existingAccountId: mappedIdentity.accountId,
      }
    )
  }

  const result = await withTransaction(db, async (tx) => {
    const operation = await tx.ledgerOperation.findUnique({
      where: { id: payload.jti },
      select: {
        id: true,
        accountId: true,
        groupId: true,
        requestHash: true,
        state: true,
        resultRecordId: true,
      },
    })
    if (
      !operation ||
      operation.accountId !== payload.issuerAccountId ||
      operation.groupId !== payload.groupId ||
      operation.requestHash !== invitationTokenHash(token)
    ) {
      throw new InvitationFlowError(
        'invitation_not_found',
        404,
        'This invitation is no longer available.'
      )
    }
    if (operation.state !== 'PENDING') {
      throw new InvitationFlowError(
        'invitation_already_used',
        409,
        'This invitation has already been used.'
      )
    }

    const reserved = await tx.ledgerOperation.updateMany({
      where: {
        id: payload.jti,
        state: 'PENDING',
        requestHash: invitationTokenHash(token),
      },
      data: {
        state: 'COMMITTED',
        resultRecordId: `claim:${acceptingAccountId}`,
      },
    })
    if (reserved.count !== 1) {
      throw new InvitationFlowError(
        'invitation_already_used',
        409,
        'This invitation has already been used.'
      )
    }

    const group = await tx.group.findUnique({
      where: { id: payload.groupId },
      select: { id: true, finalizedAt: true },
    })
    if (!group) {
      throw new InvitationFlowError('group_not_found', 404, 'Group not found.')
    }
    if (group.finalizedAt) {
      throw new InvitationFlowError('group_finalized', 409, 'Group is finalized.')
    }

    let member = await tx.groupMember.findUnique({
      where: {
        groupId_userId: {
          groupId: payload.groupId,
          userId: acceptingAccountId,
        },
      },
      include: {
        user: { select: { id: true, name: true, email: true, image: true } },
      },
    })
    let created = false

    if (!member) {
      try {
        member = await tx.groupMember.create({
          data: {
            groupId: payload.groupId,
            userId: acceptingAccountId,
            role: 'MEMBER',
          },
          include: {
            user: { select: { id: true, name: true, email: true, image: true } },
          },
        })
        created = true
      } catch (error) {
        if (!isUniqueConstraint(error)) throw error
        member = await tx.groupMember.findUniqueOrThrow({
          where: {
            groupId_userId: {
              groupId: payload.groupId,
              userId: acceptingAccountId,
            },
          },
          include: {
            user: { select: { id: true, name: true, email: true, image: true } },
          },
        })
      }
    }

    await tx.ledgerOperation.update({
      where: { id: payload.jti },
      data: {
        resultRecordId: member.id,
        completedAt: new Date((now ?? Math.floor(Date.now() / 1000)) * 1000),
      },
    })

    return { member, created }
  })

  return {
    payload,
    member: result.member,
    created: result.created,
  }
}

export const createGroupInvite = createGroupInvitation
export const claimGroupInvite = claimGroupInvitation
