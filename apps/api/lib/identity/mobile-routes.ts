import { NextRequest, NextResponse } from 'next/server'
import { prisma } from '@/lib/prisma'
import { requireMobileSession } from '@/lib/mobile-auth'
import { mobileMember } from '@/lib/mobile-dto'
import {
  claimGroupInvitation,
  InvitationFlowError,
  type ClaimedGroupInvitation,
} from './invitations'
import { externalIdentity, externalIdentityFromInput, IdentityInputError } from './types'
import { ensureParticipantsForGroup } from '@/lib/settlement/participants/service'
import { onMembershipMutation } from '@/lib/settlement/version/sources'

export function identityErrorResponse(error: unknown) {
  if (error instanceof IdentityInputError) {
    return NextResponse.json(
      { code: error.code, error: error.message },
      { status: 400 }
    )
  }

  if (error instanceof InvitationFlowError) {
    return NextResponse.json(
      {
        code: error.code,
        error: error.message,
        ...(error.details ?? {}),
      },
      { status: error.status }
    )
  }

  console.error('[MOBILE IDENTITY]', error)
  return NextResponse.json({ error: 'Internal server error' }, { status: 500 })
}

export async function parseJson(req: NextRequest): Promise<Record<string, unknown>> {
  let body: unknown
  try {
    body = await req.json()
  } catch {
    throw new IdentityInputError('A JSON request body is required.')
  }
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    throw new IdentityInputError('A JSON object is required.')
  }
  return body as Record<string, unknown>
}

export function requestedExternalIdentity(body: Record<string, unknown>) {
  if ('email' in body || 'name' in body || 'displayName' in body || 'localUUID' in body) {
    throw new IdentityInputError(
      'Display names, email addresses, and local UUIDs cannot identify a shared member.'
    )
  }

  if (body.identity !== undefined) return externalIdentityFromInput(body.identity)
  if (body.externalIdentity !== undefined) return externalIdentityFromInput(body.externalIdentity)

  if (body.appleSubject !== undefined) {
    return externalIdentity('apple', body.appleSubject)
  }
  if (body.cloudKitRecordName !== undefined) {
    return externalIdentity('cloudkit', body.cloudKitRecordName)
  }
  if (body.cloudkitRecordName !== undefined) {
    return externalIdentity('cloudkit', body.cloudkitRecordName)
  }

  return externalIdentityFromInput(body)
}

export async function claimInvitationResponse(
  req: NextRequest,
  token: string
) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  try {
    const result = await claimGroupInvitation({
      token,
      acceptingAccountId: session.user.id,
    })
    await afterMembershipClaim(result, session.user.id)

    return NextResponse.json(
      {
        member: mobileMember(result.member),
        groupId: result.payload.groupId,
        invitation: {
          id: result.payload.jti,
          status: 'claimed',
          idempotent: !result.created,
        },
      },
      { status: result.created ? 201 : 200 }
    )
  } catch (error) {
    return identityErrorResponse(error)
  }
}

async function afterMembershipClaim(result: ClaimedGroupInvitation, accountId: string) {
  if (!result.created) return

  await ensureParticipantsForGroup(result.payload.groupId)
  await onMembershipMutation(result.payload.groupId, result.member.id)
  await prisma.activityLog.create({
    data: {
      userId: accountId,
      type: 'GROUP_JOINED',
      description: `${result.member.user.name ?? result.member.user.email} joined the group`,
      metadata: { groupId: result.payload.groupId, memberId: result.member.id },
    },
  })
}
