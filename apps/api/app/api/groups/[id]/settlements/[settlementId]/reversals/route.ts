import { NextRequest, NextResponse } from 'next/server'
import { requireSettlementUserId } from '@/lib/settlement/route-auth'
import { executeReversal } from '@/lib/settlement/commands/reverse'
import { SettlementCommandError } from '@/lib/settlement/commands/core'
import { onSettlementCommandCommitted } from '@/lib/settlement/version/sources'
import { getSettleUpState } from '@/lib/settlement/read/sync'

export async function POST(
  req: NextRequest,
  { params }: { params: { id: string; settlementId: string } }
) {
  const { userId, response } = await requireSettlementUserId(req)
  if (response) return response

  const idempotencyKey = req.headers.get('Idempotency-Key')
  if (!idempotencyKey) {
    return NextResponse.json({ error: 'Idempotency-Key required' }, { status: 400 })
  }

  try {
    const body = await req.json()
    const result = await executeReversal({
      groupId: params.id,
      userId: userId!,
      settlementId: params.settlementId,
      idempotencyKey,
      expectedVersion: body.expectedVersion,
    })
    await onSettlementCommandCommitted()
    const state = await getSettleUpState(params.id, userId!)
    return NextResponse.json({ result, state }, { status: 201 })
  } catch (error) {
    if (error instanceof SettlementCommandError) {
      return NextResponse.json({ error: error.code, ...error.details }, { status: error.status })
    }
    console.error('[POST reversals]', error)
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 })
  }
}
