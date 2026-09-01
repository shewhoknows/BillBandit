import { NextRequest, NextResponse } from 'next/server'
import { requireMobileSession } from '@/lib/mobile-auth'
import {
  createGroupInvitation,
  InvitationFlowError,
} from '@/lib/identity/invitations'
import {
  identityErrorResponse,
  parseJson,
  requestedExternalIdentity,
} from '@/lib/identity/mobile-routes'

export async function POST(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  try {
    const body = await parseJson(req)
    const identity = requestedExternalIdentity(body)
    const rawExpiresInSeconds = body.expiresInSeconds
    if (
      rawExpiresInSeconds !== undefined &&
      (typeof rawExpiresInSeconds !== 'number' ||
        !Number.isSafeInteger(rawExpiresInSeconds) ||
        rawExpiresInSeconds < 1)
    ) {
      throw new InvitationFlowError(
        'invalid_invitation_request',
        400,
        'Invitation expiry must be a positive whole number of seconds.'
      )
    }
    const expiresInSeconds =
      rawExpiresInSeconds === undefined ? undefined : (rawExpiresInSeconds as number)

    const result = await createGroupInvitation({
      groupId: params.id,
      issuerAccountId: session.user.id,
      identity,
      expiresInSeconds,
    })

    return NextResponse.json(
      {
        token: result.token,
        invitation: {
          ...result.invitation,
          identity: {
            provider: result.invitation.provider,
            subject: result.invitation.subject,
          },
        },
      },
      { status: 201 }
    )
  } catch (error) {
    return identityErrorResponse(error)
  }
}
