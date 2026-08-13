import { NextRequest, NextResponse } from 'next/server'
import { requireMobileSession } from '@/lib/mobile-auth'
import { loadMobileRewardEvents } from '@/lib/mobile-rewards'

export async function GET(req: NextRequest) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  try {
    const events = await loadMobileRewardEvents(session.user.id)
    return NextResponse.json({ events }, { headers: { 'Cache-Control': 'no-store' } })
  } catch (error) {
    console.error('[MOBILE GET /rewards]', error)
    return NextResponse.json({ error: 'Could not load rewards' }, { status: 500 })
  }
}
