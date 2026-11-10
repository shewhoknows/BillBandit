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
