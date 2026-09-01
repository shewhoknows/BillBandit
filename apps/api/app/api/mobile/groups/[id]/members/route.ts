import { NextRequest, NextResponse } from 'next/server'
import { prisma } from '@/lib/prisma'
import { requireMobileSession } from '@/lib/mobile-auth'
import { mobileMember } from '@/lib/mobile-dto'
import {
  accountIdForMember,
  canonicalGroupIsReadOnly,
  memberForAccount,
  readModelErrorResponse,
} from '@/lib/mobile-groups'
import {
  legacySharedLedgerWriteResponse,
  migrationReadOnlyResponse,
  mutationErrorResponse,
  readMutationMetadata,
} from '@/lib/mobile-expenses'
import { loadGroupReadModel } from '@/lib/ledger/read-model/loader'
import { executeMutation } from '@/lib/ledger/mutation'
import { mobileMembershipV2Schema } from '@/lib/validations-mobile-ledger'

type Method = 'membership.add' | 'membership.update' | 'membership.remove'

async function loadMutableGroup(groupId: string, accountId: string) {
  const result = await loadGroupReadModel(groupId, accountId)
  if (canonicalGroupIsReadOnly(result.group)) return { result, response: migrationReadOnlyResponse(result.group) }
  return { result, response: null }
}

function targetAccountId(
  model: Awaited<ReturnType<typeof loadGroupReadModel>>['group'],
  body: Record<string, unknown>
) {
  const direct = [body.userId, body.accountId].find((value): value is string => typeof value === 'string' && value.length > 0)
  if (direct) return { userId: accountIdForMember(model, direct) ?? direct }
  if (typeof body.memberId === 'string' && body.memberId.length > 0) {
    const accountId = accountIdForMember(model, body.memberId)
    return accountId ? { userId: accountId } : { memberId: body.memberId }
  }
  return {}
}

async function mutateMembership(
  req: NextRequest,
  groupId: string,
  method: Method,
  body: unknown
) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    return NextResponse.json({ error: 'A JSON object is required' }, { status: 400 })
  }
  const record = body as Record<string, unknown>
  if ('email' in record || (!record.userId && !record.accountId && !record.memberId)) {
    return legacySharedLedgerWriteResponse(req, 'Shared membership writes require a canonical user or member ID')
  }

  const parsed = mobileMembershipV2Schema.safeParse(record)
  if (!parsed.success) {
    return NextResponse.json({ error: parsed.error.errors[0].message }, { status: 400 })
  }
  const metadataResult = readMutationMetadata(req, record)
  if ('response' in metadataResult) return metadataResult.response

  let loaded: Awaited<ReturnType<typeof loadGroupReadModel>>
  try {
    const mutable = await loadMutableGroup(groupId, session.user.id)
    if (mutable.response) return mutable.response
    loaded = mutable.result
  } catch (error) {
    const readResponse = readModelErrorResponse(error, groupId)
    if (readResponse) return readResponse
    return mutationErrorResponse(error, '[MOBILE MEMBERS READ]')
  }

  const target = targetAccountId(loaded.group, record)
  if (method === 'membership.add' && !target.userId) {
    return NextResponse.json({ error: 'userId or accountId is required to add a member' }, { status: 400 })
  }
  if (method !== 'membership.add' && !target.userId && !target.memberId) {
    return NextResponse.json({ error: 'memberId or accountId is required' }, { status: 400 })
  }

  const payload = {
    ...target,
    ...(parsed.data.role !== undefined ? { role: parsed.data.role } : {}),
    ...(parsed.data.displayName !== undefined && parsed.data.displayName !== null
      ? { displayName: parsed.data.displayName }
      : {}),
  }

  try {
    const result = await executeMutation({
      groupId,
      operationId: metadataResult.metadata.operationId,
      expectedRevision: metadataResult.metadata.expectedRevision,
      kind: method,
      accountId: session.user.id,
      actorUserId: session.user.id,
      payload,
    })

    const after = await loadGroupReadModel(groupId, session.user.id)
    const targetUserId = target.userId ?? null
    const member = targetUserId ? memberForAccount(after.group, targetUserId) : null
    if (result.outcome === 'applied' && method === 'membership.add') {
      await prisma.activityLog.create({
        data: {
          userId: session.user.id,
          type: 'GROUP_JOINED',
          description: `${member?.displayName ?? member?.email ?? targetUserId} joined the group`,
          metadata: { groupId, memberId: result.recordId, operationId: result.operationId },
        },
      })
    }
    return NextResponse.json(
      {
        member: member ? mobileMember(member) : null,
        mutation: result,
        revision: result.revision,
        readModel: after.envelope,
      },
      { status: result.replayed ? 200 : method === 'membership.add' ? 201 : 200 }
    )
  } catch (error) {
    return mutationErrorResponse(error, `[MOBILE ${method}]`)
  }
}

export async function POST(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  let body: unknown
  try {
    body = await req.json()
  } catch {
    return legacySharedLedgerWriteResponse(req, 'A canonical v2 membership body is required')
  }
  return mutateMembership(req, params.id, 'membership.add', body)
}

export async function PATCH(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  let body: unknown
  try {
    body = await req.json()
  } catch {
    return NextResponse.json({ error: 'A JSON object is required' }, { status: 400 })
  }
  return mutateMembership(req, params.id, 'membership.update', body)
}

export async function DELETE(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  let body: unknown = {}
  try {
    body = await req.json()
  } catch {
    // A missing body is handled as a legacy request and stays read-only.
  }
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    return legacySharedLedgerWriteResponse(req, 'A canonical v2 membership body is required')
  }
  return mutateMembership(req, params.id, 'membership.remove', body)
}
