import { NextRequest, NextResponse } from 'next/server'
import { requireMobileSession } from '@/lib/mobile-auth'
import { identityErrorResponse, parseJson, claimInvitationResponse } from '@/lib/identity/mobile-routes'

export async function POST(req: NextRequest) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  try {
    const body = await parseJson(req)
    const token = body.token ?? body.invitationToken
    if (typeof token !== 'string' || !token) {
      return NextResponse.json(
        { code: 'invalid_invitation_request', error: 'Invitation token is required.' },
        { status: 400 }
      )
    }

    return claimInvitationResponse(req, token)
  } catch (error) {
    return identityErrorResponse(error)
  }
}
