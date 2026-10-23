import { NextRequest, NextResponse } from 'next/server'
import { requireMobileSession } from '@/lib/mobile-auth'
import {
  buildGroupDetailResponseFromLedger,
  readModelErrorResponse,
} from '@/lib/mobile-groups'
import { loadGroupReadModel } from '@/lib/ledger/read-model/loader'
import { prisma } from '@/lib/prisma'
import { Prisma } from '@prisma/client'

export async function GET(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  try {
    const result = await loadGroupReadModel(params.id, session.user.id)
    const ids = result.group.members.map((member) => member.accountId)
    const profiles = ids.length ? await prisma.user.findMany({
      where: { id: { in: ids }, deletedAt: null }, select: { id: true, image: true },
    }) : []
    const images = new Map(profiles.map(({ id, image }) => [id, image]))
    return NextResponse.json(buildGroupDetailResponseFromLedger(result.group, images), {
      headers: { 'Cache-Control': 'no-store' },
    })
  } catch (error) {
    const errorResponse = readModelErrorResponse(error, params.id)
    if (errorResponse) return errorResponse
    console.error('[MOBILE GET /groups/:id]', error)
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 })
  }
}

/** Remove a settled shared group from every member's active catalog.
 * History is retained for ledger audit and cannot be changed after archive.
 */
export async function DELETE(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response
  try {
    const result = await prisma.$transaction(async (tx) => {
      // Serialize archive with invitation issuance and claim on the group row.
      await tx.$queryRaw`SELECT id FROM "Group" WHERE id = ${params.id} FOR UPDATE`
      const read = await loadGroupReadModel(params.id, session.user.id, {}, tx)
      const group = read.group
      const actor = group.members.find((member) => member.accountId === session.user.id)
      if (!actor || actor.role !== 'owner') {
        const owner = group.members.find((member) => member.role === 'owner')
        return { status: 403, code: 'NOT_GROUP_OWNER', ownerName: owner?.displayName ?? null }
      }
      if (group.migration.status !== 'complete' && group.migration.status !== 'not_required') {
        return { status: 409, code: 'GROUP_READ_ONLY' }
      }
      const pending = await tx.ledgerOperation.findMany({
        where: { groupId: params.id, state: 'PENDING' },
        select: { id: true, operationKey: true },
      })
      // Invitations are invitations to join, not financial writes. An archive
      // revokes them atomically; a pending ledger mutation must be retried first.
      if (group.stale.isStale || pending.some((op) => !op.operationKey.startsWith('group-invitation:'))) {
        return { status: 409, code: 'GROUP_STATE_STALE' }
      }
      if (group.settlementPlan.transfers.length > 0 ||
          group.balances.byMember.some((balance) => balance.byCurrency.some((amount) => amount.minorUnits !== '0'))) {
        return { status: 409, code: 'GROUP_UNSETTLED', openTransfers: group.settlementPlan.transfers.length }
      }
      if (pending.length > 0) {
        await tx.ledgerOperation.updateMany({
          where: { id: { in: pending.map((op) => op.id) }, state: 'PENDING' },
          data: { state: 'FAILED', failureCode: 'GROUP_ARCHIVED', completedAt: new Date() },
        })
      }
      const updated = await tx.group.updateMany({
        where: { id: params.id, isArchived: false, settlementVersion: group.revision },
        data: { isArchived: true },
      })
      return updated.count === 1
        ? { status: 200, code: 'GROUP_ARCHIVED' }
        : { status: 409, code: 'GROUP_STATE_STALE' }
    }, { isolationLevel: Prisma.TransactionIsolationLevel.Serializable })
    return NextResponse.json(
      { ...result, status: undefined, archived: result.status === 200, message: groupDeleteMessage(result) },
      { status: result.status, headers: { 'Cache-Control': 'no-store' } }
    )
  } catch (error) {
    const errorResponse = readModelErrorResponse(error, params.id)
    if (errorResponse) return errorResponse
    if (error instanceof Prisma.PrismaClientKnownRequestError && error.code === 'P2034') {
      return NextResponse.json(
        { code: 'GROUP_STATE_STALE', archived: false, message: groupDeleteMessage({ code: 'GROUP_STATE_STALE' }) },
        { status: 409 }
      )
    }
    console.error('[MOBILE DELETE /groups/:id]', error)
    return NextResponse.json(
      { code: 'GROUP_DELETE_FAILED', archived: false, message: groupDeleteMessage({ code: 'GROUP_DELETE_FAILED' }) },
      { status: 500 }
    )
  }
}

/** Plain words for each delete outcome, so every client can explain a refusal the same way. */
function groupDeleteMessage(result: { code: string; ownerName?: string | null; openTransfers?: number }): string {
  switch (result.code) {
    case 'GROUP_ARCHIVED':
      return 'Group deleted. Its history stays in Activity.'
    case 'NOT_GROUP_OWNER':
      return result.ownerName
        ? `Only ${result.ownerName} can delete this group, because they created it. You can leave it instead.`
        : 'Only the person who created this group can delete it. You can leave it instead.'
    case 'GROUP_UNSETTLED':
      return result.openTransfers === 1
        ? 'This group still has 1 payment to settle. Settle up first, then delete it.'
        : `This group still has ${result.openTransfers ?? 'some'} payments to settle. Settle up first, then delete it.`
    case 'GROUP_READ_ONLY':
      return 'This group is being moved to the new ledger. Try again in a few minutes.'
    case 'GROUP_STATE_STALE':
      return 'Someone changed this group just now. Pull to refresh, then try again.'
    default:
      return 'The group could not be deleted. Try again.'
  }
}
