import { randomUUID } from 'crypto'
import { NextRequest, NextResponse } from 'next/server'
import { requireMobileSession } from '@/lib/mobile-auth'
import { loadGroupReadModel } from '@/lib/ledger/read-model/loader'
import { executeMutation } from '@/lib/ledger/mutation'
import { canonicalGroupIsReadOnly, readModelErrorResponse } from '@/lib/mobile-groups'
import { migrationReadOnlyResponse, mutationErrorResponse } from '@/lib/mobile-expenses'

/**
 * Leave a shared group. Only someone whose own balance is zero may leave, so no
 * debt is left behind with a person who can no longer see it. The owner deletes
 * the group instead, once everyone is settled.
 */
export async function POST(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  try {
    const read = await loadGroupReadModel(params.id, session.user.id)
    const group = read.group
    if (canonicalGroupIsReadOnly(group)) return migrationReadOnlyResponse(group)

    const me = group.members.find((member) => member.accountId === session.user.id && member.status === 'active')
    if (!me) {
      return NextResponse.json(
        { code: 'NOT_A_MEMBER', message: 'You are no longer in this group.' },
        { status: 404 }
      )
    }
    if (me.role === 'owner') {
      return NextResponse.json(
        {
          code: 'OWNER_CANNOT_LEAVE',
          message: 'You created this group, so you cannot leave it. Settle every balance, then delete it.',
        },
        { status: 409 }
      )
    }

    const myBalance = group.balances.byMember.find((entry) => entry.memberId === me.memberId)?.byCurrency ?? []
    const outstanding = myBalance.filter((money) => money.minorUnits !== '0')
    if (outstanding.length > 0) {
      return NextResponse.json(
        {
          code: 'MEMBER_UNSETTLED',
          balance: outstanding,
          message: 'Settle your own balance in this group before you leave it.',
        },
        { status: 409 }
      )
    }

    const idempotencyKey = req.headers.get('Idempotency-Key') ?? randomUUID()
    const result = await executeMutation({
      groupId: params.id,
      operationId: `leave:${idempotencyKey}`,
      expectedRevision: group.revision,
      kind: 'membership.remove',
      accountId: session.user.id,
      actorUserId: session.user.id,
      payload: { userId: session.user.id },
    })
    return NextResponse.json({
      code: 'GROUP_LEFT',
      left: true,
      revision: result.revision,
      message: 'You left the group. Its history stays in Activity.',
    })
  } catch (error) {
    const readResponse = readModelErrorResponse(error, params.id)
    if (readResponse) return readResponse
    return mutationErrorResponse(error, '[MOBILE POST /groups/:id/leave]')
  }
}
