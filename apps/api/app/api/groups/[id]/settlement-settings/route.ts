import { NextRequest, NextResponse } from 'next/server'
import { requireSettlementUserId } from '@/lib/settlement/route-auth'
import { executeSettingsUpdate } from '@/lib/settlement/commands/settings'
import { normalizeSettlementError } from '@/lib/settlement/commands/core'
import { onSettlementCommandCommitted } from '@/lib/settlement/version/sources'
import { getSettleUpState, getSettleUpStateAfterCommit } from '@/lib/settlement/read/sync'

/**
 * PATCH /api/groups/{id}/settlement-settings
 * Body: { expectedVersion: number, simplifyDebts: boolean, operationId?: string }
 * Header: Idempotency-Key (or body.operationId) — the same key replays.
 *
 * 200 { result, state }: result.noop is true when the group already had
 * that value. Errors: 400 INVALID_MUTATION, 403 FORBIDDEN (not an
 * administrator) / GROUP_ARCHIVED, 409 SETTLEMENT_VERSION_CONFLICT with the
 * current state, 409 IDEMPOTENCY_KEY_REUSED.
 */
export async function PATCH(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const { userId, response } = await requireSettlementUserId(req)
  if (response) return response

  let body: { expectedVersion?: unknown; simplifyDebts?: unknown; operationId?: unknown }
  try {
    body = await req.json()
  } catch {
    return NextResponse.json({ error: 'INVALID_MUTATION', message: 'Body must be JSON' }, { status: 400 })
  }
  const idempotencyKey = req.headers.get('Idempotency-Key')?.trim()
    || (typeof body.operationId === 'string' ? body.operationId.trim() : '')
  if (!idempotencyKey) {
    return NextResponse.json({ error: 'Idempotency-Key required' }, { status: 400 })
  }
  if (typeof body.simplifyDebts !== 'boolean') {
    return NextResponse.json({ error: 'INVALID_MUTATION', message: 'simplifyDebts must be true or false' }, { status: 400 })
  }
  if (typeof body.expectedVersion !== 'number' || !Number.isInteger(body.expectedVersion) || body.expectedVersion < 0) {
    return NextResponse.json({ error: 'INVALID_MUTATION', message: 'expectedVersion must be a whole number' }, { status: 400 })
  }

  try {
    const result = await executeSettingsUpdate({
      groupId: params.id,
      userId: userId!,
      idempotencyKey,
      expectedVersion: body.expectedVersion,
      simplifyDebts: body.simplifyDebts,
    })
    if (!result.noop) await onSettlementCommandCommitted(params.id, result.eventType)
    const state = await getSettleUpStateAfterCommit(params.id, userId!)
    return NextResponse.json({ result, state }, { status: 200 })
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
        { error: normalized.code, ...normalized.details, ...(state ? { state } : {}) },
        { status: normalized.status }
      )
    }
    console.error('[PATCH settlement-settings]', error)
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 })
  }
}
