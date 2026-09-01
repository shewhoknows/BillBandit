import { NextRequest, NextResponse } from 'next/server'
import { requireMobileSession } from '@/lib/mobile-auth'
import { LedgerReadModelError } from '@/lib/ledger/read-model'
import { loadGroupReadModel } from '@/lib/ledger/read-model/loader'

const readHeaders = {
  'Cache-Control': 'no-store',
  Pragma: 'no-cache',
  Expires: '0',
}

export async function GET(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  try {
    const result = await loadGroupReadModel(params.id, session.user.id)
    return NextResponse.json(result.envelope, { headers: readHeaders })
  } catch (error) {
    if (error instanceof LedgerReadModelError) {
      if (error.code === 'GROUP_NOT_FOUND') {
        const forbidden = error.details.forbidden === true
        return NextResponse.json({ error: forbidden ? 'Forbidden' : 'Group not found' }, {
          status: forbidden ? 403 : 404,
          headers: readHeaders,
        })
      }
      if (error.code === 'MONEY_REPRESENTATION_UNAVAILABLE' || error.code === 'UNSUPPORTED_CURRENCY') {
        return NextResponse.json(
          {
            error: 'MONEY_MIGRATION_REQUIRED',
            groupId: params.id,
            readOnly: true,
            migration: {
              status: 'blocked',
              source: 'cloudkit',
              migrationId: `money-migration:${params.id}`,
              importedAt: null,
              dualWriteEnabled: false,
              recoveryReadOnly: true,
            },
            details: error.details,
          },
          { status: 409, headers: readHeaders }
        )
      }
      return NextResponse.json(
        { error: 'LEDGER_READ_UNAVAILABLE', groupId: params.id, readOnly: true, details: error.details },
        { status: 409, headers: readHeaders }
      )
    }
    console.error('[GET /api/mobile/ledger/groups/:id]', error)
    return NextResponse.json({ error: 'Internal server error' }, { status: 500, headers: readHeaders })
  }
}
