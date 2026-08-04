import { NextRequest, NextResponse } from 'next/server'
import { requireMobileSession } from '@/lib/mobile-auth'
import {
  buildGroupDetailResponseFromLedger,
  readModelErrorResponse,
} from '@/lib/mobile-groups'
import { loadGroupReadModel } from '@/lib/ledger/read-model/loader'

export async function GET(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  try {
    const result = await loadGroupReadModel(params.id, session.user.id)
    return NextResponse.json(buildGroupDetailResponseFromLedger(result.group), {
      headers: { 'Cache-Control': 'no-store' },
    })
  } catch (error) {
    const errorResponse = readModelErrorResponse(error, params.id)
    if (errorResponse) return errorResponse
    console.error('[MOBILE GET /groups/:id]', error)
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 })
  }
}
