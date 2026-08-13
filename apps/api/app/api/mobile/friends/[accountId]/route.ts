import { NextRequest, NextResponse } from 'next/server'
import { requireMobileSession } from '@/lib/mobile-auth'
import {
  FriendServiceError,
  friendErrorResponseBody,
  removeFriend,
} from '@/lib/friends'

export async function DELETE(
  req: NextRequest,
  { params }: { params: { accountId: string } }
) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  try {
    await removeFriend(session.user.id, params.accountId)
    return NextResponse.json({ removed: true })
  } catch (error) {
    if (error instanceof FriendServiceError) {
      return NextResponse.json(friendErrorResponseBody(error), { status: error.status })
    }
    console.error('[MOBILE DELETE /friends/:accountId]', error)
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 })
  }
}
