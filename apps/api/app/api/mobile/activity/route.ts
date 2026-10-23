import { NextRequest, NextResponse } from 'next/server'
import { requireMobileSession } from '@/lib/mobile-auth'
import { loadAccountReadModel } from '@/lib/ledger/read-model/loader'
import { DEFAULT_ACTIVITY_PAGE_SIZE, pageActivity, parseActivityPageSize } from '@/lib/activity/pagination'
import { readModelErrorResponse } from '@/lib/mobile-groups'

/** Older activity across every group, one page at a time. */
export async function GET(req: NextRequest) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  const { searchParams } = new URL(req.url)
  const limit = parseActivityPageSize(searchParams.get('limit')) ?? DEFAULT_ACTIVITY_PAGE_SIZE
  const before = searchParams.get('before')

  try {
    const result = await loadAccountReadModel(session.user.id)
    const page = pageActivity(result.summary.activity, { limit, before })
    return NextResponse.json(
      { activity: page.items, nextCursor: page.nextCursor, readRevision: result.summary.readRevision },
      { headers: { 'Cache-Control': 'no-store' } }
    )
  } catch (error) {
    const errorResponse = readModelErrorResponse(error)
    if (errorResponse) return errorResponse
    console.error('[MOBILE GET /activity]', error)
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 })
  }
}
