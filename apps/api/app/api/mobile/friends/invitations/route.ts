import { NextRequest, NextResponse } from 'next/server'
import { requireMobileSession } from '@/lib/mobile-auth'
import {
  createFriendInvitation,
  FriendServiceError,
  friendErrorResponseBody,
} from '@/lib/friends'

export async function POST(req: NextRequest) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  try {
    const invitation = await createFriendInvitation(session.user.id)
    return NextResponse.json({
      invitation: {
        ...invitation,
        createdAt: invitation.createdAt.toISOString(),
        expiresAt: invitation.expiresAt.toISOString(),
      },
    })
  } catch (error) {
    if (error instanceof FriendServiceError) {
      return NextResponse.json(friendErrorResponseBody(error), { status: error.status })
    }
    console.error('[MOBILE POST /friends/invitations]', error)
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 })
  }
}
