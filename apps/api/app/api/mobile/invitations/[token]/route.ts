import { NextRequest, NextResponse } from 'next/server'
import { prisma } from '@/lib/prisma'
import { invitationTokenHash, verifyInvitationToken } from '@/lib/identity/invitation-token'
import { claimInvitationResponse, identityErrorResponse } from '@/lib/identity/mobile-routes'
import { InvitationFlowError } from '@/lib/identity/invitations'

export async function GET(
  req: NextRequest,
  { params }: { params: { token: string } }
) {
  try {
    const verification = verifyInvitationToken(params.token)
    if (!verification.valid) {
      if (verification.code === 'expired') {
        throw new InvitationFlowError('invitation_expired', 410, 'This invitation has expired.')
      }
      throw new InvitationFlowError('invitation_invalid', 400, 'This invitation link is invalid.')
    }

    const operation = await prisma.ledgerOperation.findUnique({
      where: { id: verification.payload.jti },
      select: { requestHash: true, state: true },
    })
    if (!operation || operation.requestHash !== invitationTokenHash(params.token)) {
      throw new InvitationFlowError('invitation_not_found', 404, 'This invitation is no longer available.')
    }
    if (operation.state !== 'PENDING') {
      throw new InvitationFlowError('invitation_already_used', 409, 'This invitation has already been used.')
    }

    const group = await prisma.group.findUnique({
      where: { id: verification.payload.groupId },
      select: { id: true, name: true, description: true, finalizedAt: true },
    })
    if (!group) throw new InvitationFlowError('group_not_found', 404, 'Group not found.')
    if (group.finalizedAt) {
      throw new InvitationFlowError('group_finalized', 409, 'Group is finalized.')
    }

    return NextResponse.json({
      invitation: {
        id: verification.payload.jti,
        group: { id: group.id, name: group.name, description: group.description },
        provider: verification.payload.provider,
        expiresAt: new Date(verification.payload.exp * 1000).toISOString(),
        status: 'pending',
        requiresExplicitClaim: true,
      },
    })
  } catch (error) {
    return identityErrorResponse(error)
  }
}

export async function POST(
  req: NextRequest,
  { params }: { params: { token: string } }
) {
  return claimInvitationResponse(req, params.token)
}
