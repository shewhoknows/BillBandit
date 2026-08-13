import { randomUUID } from 'node:crypto'
import type { GroupCategory, Prisma, PrismaClient } from '@prisma/client'
import { prisma } from '@/lib/prisma'
import { listAcceptedFriends } from '@/lib/friends'
import { hashCanonicalRequest } from '@/lib/ledger/mutation'
import { ensureParticipantsForGroup } from '@/lib/settlement/participants/service'

export const groupCreationInclude = {
  members: {
    include: {
      user: {
        select: {
          id: true,
          username: true,
          name: true,
          preferredName: true,
          image: true,
          email: true,
        },
      },
    },
  },
  _count: { select: { expenses: { where: { isDeleted: false } } } },
} as const

export class GroupCreationError extends Error {
  readonly code = 'group_members_must_be_friends'
  readonly status = 403
  readonly invalidAccountIds: string[]

  constructor(invalidAccountIds: string[]) {
    super('Every added group member must be a current accepted friend.')
    this.name = 'GroupCreationError'
    this.invalidAccountIds = invalidAccountIds
  }
}

export class GroupCreationIdempotencyError extends Error {
  readonly code:
    | 'invalid_idempotency_key'
    | 'idempotency_key_reused'
    | 'group_creation_in_progress'
  readonly status: number

  constructor(
    code: GroupCreationIdempotencyError['code'],
    status: number,
    message: string
  ) {
    super(message)
    this.name = 'GroupCreationIdempotencyError'
    this.code = code
    this.status = status
  }
}

export function groupCreationIdempotencyKey(rawValue: string | null): string | undefined {
  if (rawValue === null) return undefined
  const value = rawValue.trim()
  if (!value || value.length > 200 || /\s/.test(value)) {
    throw new GroupCreationIdempotencyError(
      'invalid_idempotency_key',
      400,
      'Idempotency-Key must contain 1 to 200 characters and no whitespace.'
    )
  }
  return value
}

async function createGroupRows(
  tx: Prisma.TransactionClient,
  input: {
    accountId: string
    actorName: string | null
    name: string
    description?: string
    currency: string
    category: GroupCategory
  },
  memberAccountIds: string[]
) {
  const acceptedFriendIds = new Set(
    (await listAcceptedFriends(input.accountId, tx)).map((friend) => friend.id)
  )
  const invalidAccountIds = memberAccountIds.filter(
    (accountId) => !acceptedFriendIds.has(accountId)
  )
  if (invalidAccountIds.length > 0) {
    throw new GroupCreationError(invalidAccountIds)
  }

  const group = await tx.group.create({
    data: {
      name: input.name,
      description: input.description,
      currency: input.currency,
      category: input.category,
      members: {
        create: [
          { userId: input.accountId, role: 'ADMIN' },
          ...memberAccountIds.map((userId) => ({ userId, role: 'MEMBER' as const })),
        ],
      },
    },
    include: groupCreationInclude,
  })

  await ensureParticipantsForGroup(group.id, tx)
  await tx.activityLog.create({
    data: {
      userId: input.accountId,
      type: 'GROUP_CREATED',
      description: `${input.actorName ?? 'A member'} created the group "${input.name}"`,
      metadata: { groupId: group.id },
    },
  })

  return group
}

export async function createGroupWithFriends(
  input: {
    accountId: string
    actorName: string | null
    name: string
    description?: string
    currency: string
    category: GroupCategory
    memberAccountIds: string[]
    idempotencyKey?: string
  },
  db: PrismaClient = prisma
): Promise<{
  group: Awaited<ReturnType<typeof createGroupRows>>
  replayed: boolean
}> {
  const memberAccountIds = [...new Set(input.memberAccountIds)]
    .filter((accountId) => accountId !== input.accountId)
    .sort()

  return db.$transaction(async (tx) => {
    if (!input.idempotencyKey) {
      return {
        group: await createGroupRows(tx, input, memberAccountIds),
        replayed: false,
      }
    }

    const requestHash = hashCanonicalRequest({
      kind: 'group.create',
      payload: {
        name: input.name,
        description: input.description ?? null,
        currency: input.currency,
        category: input.category,
        memberAccountIds,
      },
    })
    const operationId = randomUUID()
    const operationKey = `group.create:${input.idempotencyKey}`
    const operation = await tx.ledgerOperation.upsert({
      where: {
        accountId_operationKey: {
          accountId: input.accountId,
          operationKey,
        },
      },
      create: {
        id: operationId,
        accountId: input.accountId,
        operationKey,
        requestHash,
        expectedRevision: 0,
        state: 'PENDING',
      },
      update: {},
    })

    if (operation.requestHash !== requestHash) {
      throw new GroupCreationIdempotencyError(
        'idempotency_key_reused',
        409,
        'The Idempotency-Key is already bound to a different group request.'
      )
    }
    if (operation.id !== operationId) {
      if (operation.state !== 'COMMITTED' || !operation.resultRecordId) {
        throw new GroupCreationIdempotencyError(
          'group_creation_in_progress',
          409,
          'The group request is still in progress. Try the same request again.'
        )
      }
      const group = await tx.group.findUniqueOrThrow({
        where: { id: operation.resultRecordId },
        include: groupCreationInclude,
      })
      return { group, replayed: true }
    }

    const group = await createGroupRows(tx, input, memberAccountIds)
    await tx.ledgerOperation.update({
      where: { id: operation.id },
      data: {
        groupId: group.id,
        state: 'COMMITTED',
        resultRevision: 0,
        resultRecordId: group.id,
        completedAt: new Date(),
      },
    })
    return { group, replayed: false }
  })
}
