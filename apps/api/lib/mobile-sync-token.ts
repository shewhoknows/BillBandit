import { createHash } from 'node:crypto'
import type { PrismaClient } from '@prisma/client'
import { prisma } from '@/lib/prisma'

const profileSelect = {
  id: true,
  username: true,
  name: true,
  preferredName: true,
  image: true,
  deletedAt: true,
} as const

const groupStateSelect = {
  id: true,
  name: true,
  description: true,
  image: true,
  currency: true,
  category: true,
  isArchived: true,
  finalizedAt: true,
  simplifyDebts: true,
  settlementVersion: true,
  hadOpenTransfers: true,
  settlementCompletedAt: true,
  members: {
    select: {
      userId: true,
      role: true,
    },
  },
} as const

function profileState(profile: {
  id: string
  username: string | null
  name: string | null
  preferredName: string | null
  image: string | null
  deletedAt: Date | null
}) {
  return {
    id: profile.id,
    username: profile.username,
    name: profile.name,
    preferredName: profile.preferredName,
    image: profile.image,
    deletedAt: profile.deletedAt?.toISOString() ?? null,
  }
}

/**
 * Build a compact change token for state that affects mobile discovery and
 * shared-ledger reads. IDs are hash inputs only and never leave this service.
 */
export async function buildMobileSyncToken(
  accountId: string,
  db: PrismaClient = prisma
): Promise<string> {
  // These predicates use the Friendship.fromId, Friendship.toId, and
  // GroupMember.userId indexes. Nested relation reads use groupId keys.
  const [initiated, received, memberships] = await Promise.all([
    db.friendship.findMany({
      where: { fromId: accountId, status: 'ACCEPTED' },
      select: {
        id: true,
        createdAt: true,
        to: { select: profileSelect },
      },
    }),
    db.friendship.findMany({
      where: { toId: accountId, status: 'ACCEPTED' },
      select: {
        id: true,
        createdAt: true,
        from: { select: profileSelect },
      },
    }),
    db.groupMember.findMany({
      where: { userId: accountId },
      select: {
        role: true,
        group: { select: groupStateSelect },
      },
    }),
  ])

  const friends = [
    ...initiated.map((friendship) => ({
      relationshipId: friendship.id,
      acceptedAt: friendship.createdAt.toISOString(),
      profile: profileState(friendship.to),
    })),
    ...received.map((friendship) => ({
      relationshipId: friendship.id,
      acceptedAt: friendship.createdAt.toISOString(),
      profile: profileState(friendship.from),
    })),
  ].sort(
    (left, right) =>
      left.profile.id.localeCompare(right.profile.id) ||
      left.relationshipId.localeCompare(right.relationshipId)
  )

  const groups = memberships
    .map((membership) => {
      const group = membership.group
      return {
        id: group.id,
        callerRole: membership.role,
        name: group.name,
        description: group.description,
        image: group.image,
        currency: group.currency,
        category: group.category,
        isArchived: group.isArchived,
        finalizedAt: group.finalizedAt?.toISOString() ?? null,
        simplifyDebts: group.simplifyDebts,
        settlementVersion: group.settlementVersion,
        hadOpenTransfers: group.hadOpenTransfers,
        settlementCompletedAt: group.settlementCompletedAt?.toISOString() ?? null,
        members: group.members
          .map((member) => ({
            userId: member.userId,
            role: member.role,
          }))
          .sort((left, right) => left.userId.localeCompare(right.userId)),
      }
    })
    .sort((left, right) => left.id.localeCompare(right.id))

  return createHash('sha256')
    .update(JSON.stringify({ version: 1, accountId, friends, groups }))
    .digest('hex')
}
