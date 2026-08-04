import { NextRequest, NextResponse } from 'next/server'
import { requireSettlementUserId } from '@/lib/settlement/route-auth'
import { executeSettlement } from '@/lib/settlement/commands/settle'
import {
  normalizeSettlementError,
} from '@/lib/settlement/commands/core'
import { onSettlementCommandCommitted } from '@/lib/settlement/version/sources'
import { getSettleUpState } from '@/lib/settlement/read/sync'

export async function POST(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const { userId, response } = await requireSettlementUserId(req)
  if (response) return response

  const idempotencyKey = req.headers.get('Idempotency-Key')
  if (!idempotencyKey) {
    return NextResponse.json({ error: 'Idempotency-Key required' }, { status: 400 })
  }

  try {
    const body = await req.json()
    const result = await executeSettlement({
      groupId: params.id,
      userId: userId!,
      idempotencyKey,
      expectedVersion: body.expectedVersion,
      planTransferId: body.planTransferId,
      payerParticipantId: body.payerParticipantId,
      recipientParticipantId: body.recipientParticipantId,
      currencyCode: body.currencyCode,
      currencyExponent: body.currencyExponent,
      minorUnits: body.minorUnits,
      note: body.note,
    })
    await onSettlementCommandCommitted(params.id, result.eventType)
    const state = await getSettleUpState(params.id, userId!)
    return NextResponse.json({ result, state }, { status: 201 })
  } catch (error) {
    const normalized = normalizeSettlementError(error)
    if (normalized) {
      let state: Awaited<ReturnType<typeof getSettleUpState>> | undefined
      if (normalized.includeState) {
        try {
          state = await getSettleUpState(params.id, userId!)
        } catch {
          // Keep the deterministic error code even if a state read is unavailable.
        }
      }
      return NextResponse.json(
        {
          error: normalized.code,
          ...normalized.details,
          ...(state ? { state } : {}),
        },
        { status: normalized.status }
      )
    }
    console.error('[POST settlements]', error)
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 })
  }
}
