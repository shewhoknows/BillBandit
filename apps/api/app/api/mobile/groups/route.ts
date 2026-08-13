import { NextRequest, NextResponse } from 'next/server'
import { createGroupSchema } from '@/lib/validations-mobile-ledger'
import { requireMobileSession } from '@/lib/mobile-auth'
import { mobileGroup } from '@/lib/mobile-dto'
import { profileDisplayName } from '@/lib/profile-display-name'
import { loadAccountReadModel } from '@/lib/ledger/read-model/loader'
import { mobileGroupFromLedger, readModelErrorResponse } from '@/lib/mobile-groups'
import {
  createGroupWithFriends,
  GroupCreationError,
  GroupCreationIdempotencyError,
  groupCreationIdempotencyKey,
} from '@/lib/mobile-group-creation'

export async function GET(req: NextRequest) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  try {
    const result = await loadAccountReadModel(session.user.id)
    return NextResponse.json(
      {
        groups: result.groups.map((projection) => mobileGroupFromLedger(projection.model)),
        readRevision: result.summary.readRevision,
        readOnly: result.summary.readOnly,
        migration: result.summary.migration,
        authority: result.summary.authority,
      },
      { headers: { 'Cache-Control': 'no-store' } }
    )
  } catch (error) {
    const response = readModelErrorResponse(error)
    if (response) return response
    console.error('[MOBILE GET /groups]', error)
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 })
  }
}

export async function POST(req: NextRequest) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  try {
    const body = await req.json()
    const parsed = createGroupSchema.safeParse(body)
    if (!parsed.success) {
      return NextResponse.json({ error: parsed.error.errors[0].message }, { status: 400 })
    }

    const { name, description, currency, category, memberAccountIds } = parsed.data
    const result = await createGroupWithFriends({
      accountId: session.user.id,
      actorName: profileDisplayName(session.user),
      name,
      description,
      currency,
      category,
      memberAccountIds,
      idempotencyKey: groupCreationIdempotencyKey(req.headers.get('Idempotency-Key')),
    })

    return NextResponse.json(
      { group: mobileGroup(result.group) },
      {
        status: result.replayed ? 200 : 201,
        headers: { 'Idempotency-Replayed': result.replayed ? 'true' : 'false' },
      }
    )
  } catch (error) {
    if (error instanceof GroupCreationError) {
      return NextResponse.json(
        {
          code: error.code,
          error: error.message,
          invalidAccountIds: error.invalidAccountIds,
        },
        { status: error.status }
      )
    }
    if (error instanceof GroupCreationIdempotencyError) {
      return NextResponse.json(
        { code: error.code, error: error.message },
        { status: error.status }
      )
    }
    console.error('[MOBILE POST /groups]', error)
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 })
  }
}
