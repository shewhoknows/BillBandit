import { NextRequest, NextResponse } from 'next/server'
import { requireMobileSession } from '@/lib/mobile-auth'
import { LedgerReadModelError } from '@/lib/ledger/read-model'
import { loadAccountReadModel } from '@/lib/ledger/read-model/loader'
import { pageActivity, parseActivityPageSize } from '@/lib/activity/pagination'
import { loadProfileImages } from '@/lib/profile-images'

const readHeaders = {
  'Cache-Control': 'no-store',
  Pragma: 'no-cache',
  Expires: '0',
}

export async function GET(req: NextRequest) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  try {
    const result = await loadAccountReadModel(session.user.id)
    const { searchParams } = new URL(req.url)
    const activityLimit = parseActivityPageSize(searchParams.get('activityLimit'))
    // Older clients ask without a limit and still receive the full feed.
    const page = activityLimit === null
      ? { items: result.summary.activity, nextCursor: null }
      : pageActivity(result.summary.activity, { limit: activityLimit })
    const profileImages = await loadProfileImages(
      result.summary.groups.flatMap((group) => group.members.map((member) => member.accountId))
    )
    return NextResponse.json(
      { ...result.summary, activity: page.items, activityNextCursor: page.nextCursor, profileImages },
      { headers: readHeaders }
    )
  } catch (error) {
    if (error instanceof LedgerReadModelError) {
      if (error.code === 'MONEY_REPRESENTATION_UNAVAILABLE' || error.code === 'UNSUPPORTED_CURRENCY') {
        return NextResponse.json(
          {
            error: 'MONEY_MIGRATION_REQUIRED',
            readOnly: true,
            details: error.details,
          },
          { status: 409, headers: readHeaders }
        )
      }
      return NextResponse.json(
        { error: 'LEDGER_READ_UNAVAILABLE', details: error.details },
        { status: 409, headers: readHeaders }
      )
    }
    console.error('[GET /api/mobile/ledger]', error)
    return NextResponse.json({ error: 'Internal server error' }, { status: 500, headers: readHeaders })
  }
}
