import { NextRequest, NextResponse } from 'next/server'
import { requireMobileSession } from '@/lib/mobile-auth'
import { listAcceptedFriends } from '@/lib/friends'
import { REVIEW_ACCOUNT_ID, REVIEW_FRIEND_IDS } from '@/lib/review-account'

export async function GET(req: NextRequest) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  try {
    const friends = (await listAcceptedFriends(session.user.id)).map((friend) =>
      session.user.id === REVIEW_ACCOUNT_ID && REVIEW_FRIEND_IDS.some((id) => id === friend.id)
        ? { ...friend, username: null }
        : friend
    )
    return NextResponse.json(
      { friends },
      { headers: { 'Cache-Control': 'no-store' } }
    )
  } catch (error) {
    console.error('[MOBILE GET /friends]', error)
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 })
  }
}
