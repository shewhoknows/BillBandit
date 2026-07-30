import { NextRequest, NextResponse } from 'next/server'
import { prisma } from '@/lib/prisma'
import { requireMobileSession } from '@/lib/mobile-auth'
import { buildGroupDetailResponse, getGroupWithLedger } from '@/lib/mobile-groups'
import { onGroupLifecycleMutation } from '@/lib/settlement/version/sources'

export async function POST(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  const membership = await prisma.groupMember.findUnique({
    where: { groupId_userId: { groupId: params.id, userId: session.user.id } },
    select: { role: true },
  })
  if (!membership || membership.role !== 'ADMIN') {
    return NextResponse.json({ error: 'Forbidden' }, { status: 403 })
  }

  await prisma.group.updateMany({
    where: { id: params.id, finalizedAt: null },
    data: {
      finalizedAt: new Date(),
      finalizedById: session.user.id,
    },
  })

  await onGroupLifecycleMutation(params.id, params.id, 'group_finalized')

  const group = await getGroupWithLedger(params.id)
  if (!group) return NextResponse.json({ error: 'Group not found' }, { status: 404 })

  return NextResponse.json(buildGroupDetailResponse(group))
}
