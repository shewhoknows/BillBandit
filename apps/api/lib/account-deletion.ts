import type { PrismaClient } from '@prisma/client'
import { prisma } from '@/lib/prisma'

const DELETED_USER_NAME = 'Deleted user'

export type AccountDeletionResult =
  | { status: 'deleted'; deletedAt: Date }
  | { status: 'not_found' }
  | { status: 'already_deleted'; deletedAt: Date }

/**
 * Remove account-owned data and anonymize the identity that is still needed
 * by shared ledger foreign keys. Amounts, splits, and settlement history stay
 * intact for the other members of a group, but personal profile data and
 * user-authored text are removed.
 */
export async function deleteMobileAccount(
  accountId: string,
  db: PrismaClient = prisma,
): Promise<AccountDeletionResult> {
  return db.$transaction(async (tx) => {
    const user = await tx.user.findUnique({
      where: { id: accountId },
      select: {
        id: true,
        email: true,
        phone: true,
        deletedAt: true,
      },
    })

    if (!user) return { status: 'not_found' as const }
    if (user.deletedAt) {
      return { status: 'already_deleted' as const, deletedAt: user.deletedAt }
    }

    const deletedAt = new Date()
    const participantRows = await tx.groupParticipant.findMany({
      where: { userId: accountId },
      select: { id: true },
    })
    const participantIds = participantRows.map(({ id }) => id)

    const transactionConditions = [
      { senderId: accountId },
      { receiverId: accountId },
      { actorUserId: accountId },
      ...(participantIds.length > 0
        ? [
            { payerParticipantId: { in: participantIds } },
            { recipientParticipantId: { in: participantIds } },
          ]
        : []),
    ]
    const transactionRows = await tx.transaction.findMany({
      where: { OR: transactionConditions },
      select: { id: true },
    })
    const transactionIds = new Set(transactionRows.map(({ id }) => id))

    const participantPathRows = participantIds.length > 0
      ? await tx.settlementAllocationPath.findMany({
          where: {
            OR: [
              { payerParticipantId: { in: participantIds } },
              { recipientParticipantId: { in: participantIds } },
            ],
          },
          select: { allocationId: true },
        })
      : []
    const allocationIds = new Set(participantPathRows.map(({ allocationId }) => allocationId))

    const allocationConditions = []
    if (transactionIds.size > 0) {
      allocationConditions.push({ transactionId: { in: [...transactionIds] } })
    }
    if (allocationIds.size > 0) {
      allocationConditions.push({ id: { in: [...allocationIds] } })
    }
    const allocationRows = allocationConditions.length > 0
      ? await tx.settlementAllocation.findMany({
          where: { OR: allocationConditions },
          select: { id: true, transactionId: true },
        })
      : []
    for (const allocation of allocationRows) {
      allocationIds.add(allocation.id)
      transactionIds.add(allocation.transactionId)
    }

    if (allocationIds.size > 0) {
      await tx.settlementAllocationPath.deleteMany({
        where: { allocationId: { in: [...allocationIds] } },
      })
    }
    if (transactionIds.size > 0) {
      await tx.settlementReversal.deleteMany({
        where: { transactionId: { in: [...transactionIds] } },
      })
      await tx.settlementAllocation.deleteMany({
        where: { transactionId: { in: [...transactionIds] } },
      })
      await tx.transaction.updateMany({
        where: { id: { in: [...transactionIds] } },
        data: { note: null },
      })
    }

    // Preserve the financial shape of a shared expense while removing the
    // deleted user's free-form text and receipt attachment.
    await tx.expense.updateMany({
      where: { paidById: accountId },
      data: {
        description: DELETED_USER_NAME,
        category: 'general',
        receiptUrl: null,
        notes: null,
      },
    })

    if (participantIds.length > 0) {
      await tx.groupParticipant.updateMany({
        where: { id: { in: participantIds } },
        data: { displayName: DELETED_USER_NAME },
      })
    }

    await tx.comment.deleteMany({ where: { userId: accountId } })
    await tx.activityLog.deleteMany({ where: { userId: accountId } })
    await tx.ledgerImportRecord.deleteMany({ where: { accountId } })
    await tx.ledgerImport.deleteMany({ where: { accountId } })
    await tx.ledgerOperation.deleteMany({ where: { accountId } })
    await tx.externalIdentity.deleteMany({ where: { accountId } })
    await tx.account.deleteMany({ where: { userId: accountId } })
    await tx.session.deleteMany({ where: { userId: accountId } })
    await tx.friendship.deleteMany({
      where: { OR: [{ fromId: accountId }, { toId: accountId }] },
    })

    const identifiers = [user.email, user.phone].filter(
      (value): value is string => Boolean(value),
    )
    if (identifiers.length > 0) {
      await tx.mobileOTPChallenge.deleteMany({
        where: { identifier: { in: identifiers } },
      })
    }

    await tx.user.update({
      where: { id: accountId },
      data: {
        username: null,
        name: DELETED_USER_NAME,
        email: `deleted+${accountId}@deleted.billbandit.invalid`,
        emailVerified: null,
        image: null,
        password: null,
        phone: null,
        preferredName: null,
        upiID: null,
        deletedAt,
      },
    })

    return { status: 'deleted' as const, deletedAt }
  })
}
