import type { Prisma, PrismaClient } from '@prisma/client'
import { prisma } from '@/lib/prisma'
import { profileDisplayName } from '@/lib/profile-display-name'

type Db = PrismaClient | Prisma.TransactionClient

export async function ensureParticipantsForGroup(
  groupId: string,
  db: Db = prisma
): Promise<void> {
  const members = await db.groupMember.findMany({
    where: { groupId },
    include: {
      user: {
        select: { id: true, username: true, preferredName: true, name: true },
      },
    },
  })

  for (const member of members) {
    const displayName = profileDisplayName(member.user)
    await db.groupParticipant.upsert({
      where: { groupId_userId: { groupId, userId: member.userId } },
      create: {
        groupId,
        userId: member.userId,
        displayName,
        status: 'ACTIVE',
        joinedAt: member.joinedAt,
      },
      update: {
        displayName,
        status: 'ACTIVE',
        departedAt: null,
      },
    })
  }
}

export async function markParticipantDeparted(
  groupId: string,
  userId: string,
  db: Db = prisma
): Promise<void> {
  const participant = await db.groupParticipant.findUnique({
    where: { groupId_userId: { groupId, userId } },
  })
  if (!participant) return

  await db.groupParticipant.update({
    where: { id: participant.id },
    data: { status: 'DEPARTED', departedAt: new Date() },
  })
}

export async function linkTransactionParticipants(
  transactionId: string,
  groupId: string,
  senderId: string,
  receiverId: string,
  db: Db = prisma
): Promise<{ payerParticipantId: string; recipientParticipantId: string }> {
  await ensureParticipantsForGroup(groupId, db)

  const payer = await db.groupParticipant.findUniqueOrThrow({
    where: { groupId_userId: { groupId, userId: senderId } },
  })
  const recipient = await db.groupParticipant.findUniqueOrThrow({
    where: { groupId_userId: { groupId, userId: receiverId } },
  })

  await db.transaction.update({
    where: { id: transactionId },
    data: {
      payerParticipantId: payer.id,
      recipientParticipantId: recipient.id,
    },
  })

  return { payerParticipantId: payer.id, recipientParticipantId: recipient.id }
}
