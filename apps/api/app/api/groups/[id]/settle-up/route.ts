import { NextRequest, NextResponse } from 'next/server'
import { requireSettlementUserId } from '@/lib/settlement/route-auth'
import { getSettleUpState } from '@/lib/settlement/read/sync'
import { SettlementCommandError } from '@/lib/settlement/commands/core'
import { LedgerReadModelError } from '@/lib/ledger/read-model'

export async function GET(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const { userId, response } = await requireSettlementUserId(req)
  if (response) return response

  const afterVersionRaw = req.nextUrl.searchParams.get('afterVersion')
  const afterVersion = afterVersionRaw ? Number(afterVersionRaw) : null
  if (afterVersionRaw && Number.isNaN(afterVersion)) {
    return NextResponse.json({ error: 'Invalid version' }, { status: 400 })
  }

  try {
    const state = await getSettleUpState(params.id, userId!, afterVersion)
    return NextResponse.json(state)
  } catch (error) {
    if (error instanceof Error && error.message === 'FORBIDDEN') {
      return NextResponse.json({ error: 'Forbidden' }, { status: 403 })
    }
    if (error instanceof Error && (error as { code?: string }).code === 'VERSION_AHEAD') {
      const snapshot = (error as { snapshot?: unknown }).snapshot
      return NextResponse.json({ error: 'VERSION_AHEAD', snapshot }, { status: 409 })
    }
    if (error instanceof SettlementCommandError) {
      return NextResponse.json({ error: error.code, ...error.details }, { status: error.status })
    }
    if (error instanceof LedgerReadModelError) {
      const migrationBlocked =
        error.code === 'MONEY_REPRESENTATION_UNAVAILABLE' || error.code === 'UNSUPPORTED_CURRENCY'
      return NextResponse.json(
        {
          error: migrationBlocked ? 'MONEY_MIGRATION_REQUIRED' : 'LEDGER_READ_UNAVAILABLE',
          readOnly: true,
          details: error.details,
        },
        { status: 409 }
      )
    }
    console.error('[GET settle-up]', error)
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 })
  }
}
