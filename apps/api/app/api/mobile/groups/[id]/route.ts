import { NextRequest, NextResponse } from 'next/server'
import { prisma } from '@/lib/prisma'
import { requireMobileSession } from '@/lib/mobile-auth'
import { buildGroupDetailResponse, getGroupWithLedger } from '@/lib/mobile-groups'

export async function GET(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  const membership = await prisma.groupMember.findUnique({
    where: { groupId_userId: { groupId: params.id, userId: session.user.id } },
  })
  if (!membership) return NextResponse.json({ error: 'Forbidden' }, { status: 403 })

  const group = await getGroupWithLedger(params.id)
  if (!group) return NextResponse.json({ error: 'Group not found' }, { status: 404 })

  return NextResponse.json(buildGroupDetailResponse(group))
}
