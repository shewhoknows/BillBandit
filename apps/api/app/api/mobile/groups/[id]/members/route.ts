import { NextRequest, NextResponse } from 'next/server'
import { prisma } from '@/lib/prisma'
import { addMemberSchema } from '@/lib/validations-mobile-ledger'
import { requireMobileSession } from '@/lib/mobile-auth'
import { mobileMember } from '@/lib/mobile-dto'
import { onMembershipMutation } from '@/lib/settlement/version/sources'
import { ensureParticipantsForGroup } from '@/lib/settlement/participants/service'

export async function POST(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  const myMembership = await prisma.groupMember.findUnique({
    where: { groupId_userId: { groupId: params.id, userId: session.user.id } },
    include: { group: { select: { finalizedAt: true } } },
  })
  if (!myMembership) return NextResponse.json({ error: 'Forbidden' }, { status: 403 })
  if (myMembership.group.finalizedAt) {
    return NextResponse.json({ error: 'Group is finalized' }, { status: 409 })
  }

  const body = await req.json()
  const parsed = addMemberSchema.safeParse(body)
  if (!parsed.success) {
    return NextResponse.json({ error: parsed.error.errors[0].message }, { status: 400 })
  }

  const userToAdd = await prisma.user.findUnique({
    where: { email: parsed.data.email },
    select: { id: true, name: true, email: true, image: true },
  })
  if (!userToAdd) {
    return NextResponse.json({ error: 'No user found with that email address' }, { status: 404 })
  }

  const existing = await prisma.groupMember.findUnique({
    where: { groupId_userId: { groupId: params.id, userId: userToAdd.id } },
  })
  if (existing) {
    return NextResponse.json({ error: 'User is already a member of this group' }, { status: 409 })
  }

  const member = await prisma.groupMember.create({
    data: { groupId: params.id, userId: userToAdd.id, role: 'MEMBER' },
    include: { user: { select: { id: true, name: true, image: true, email: true } } },
  })

  await ensureParticipantsForGroup(params.id)
  await onMembershipMutation(params.id, member.id)

  await prisma.activityLog.create({
    data: {
      userId: session.user.id,
      type: 'GROUP_JOINED',
      description: `${userToAdd.name ?? userToAdd.email} joined the group`,
      metadata: { groupId: params.id },
    },
  })

  return NextResponse.json({ member: mobileMember(member) }, { status: 201 })
}
