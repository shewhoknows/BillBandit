import { NextRequest, NextResponse } from 'next/server'
import { requireMobileSession } from '@/lib/mobile-auth'
import {
  claimFriendInvitation,
  FriendServiceError,
  friendErrorResponseBody,
} from '@/lib/friends'

export async function POST(
  req: NextRequest,
  { params }: { params: { code: string } }
) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  try {
    const result = await claimFriendInvitation(session.user.id, params.code)
    return NextResponse.json(
      { friend: result.friend },
      { status: result.created ? 201 : 200 }
    )
  } catch (error) {
    if (error instanceof FriendServiceError) {
      return NextResponse.json(friendErrorResponseBody(error), {
        status: error.status,
        headers:
          error.retryAfterSeconds === undefined
            ? undefined
            : { 'Retry-After': String(error.retryAfterSeconds) },
      })
    }
    console.error('[MOBILE POST /friends/invitations/:code/claim]', error)
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 })
  }
}
