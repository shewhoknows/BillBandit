import { NextRequest, NextResponse } from 'next/server'
import { requireMobileSession } from '@/lib/mobile-auth'
import { buildMobileSyncToken } from '@/lib/mobile-sync-token'

export async function GET(req: NextRequest) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  try {
    const token = await buildMobileSyncToken(session.user.id)
    return NextResponse.json(
      { token },
      { headers: { 'Cache-Control': 'no-store' } }
    )
  } catch (error) {
    console.error('[MOBILE GET /sync-token]', error)
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 })
  }
}
