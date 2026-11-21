import type { PrismaClient } from '@prisma/client'
import { prisma } from '@/lib/prisma'
import { assertAccountTransition, deriveAccountState } from '@/lib/identity-friends-state'

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
    // Lock the account row first. A friend claim or invitation that touches
    // this account takes FOR SHARE on it, so it either finishes before this
    // deletion (and its rows are removed below) or waits and then sees
    // deletedAt. Two deletions at once also serialize here.
    const locked = await tx.$queryRaw<Array<{ id: string; email: string; phone: string | null; deletedAt: Date | null }>>`
      SELECT "id", "email", "phone", "deletedAt" FROM "User" WHERE "id" = ${accountId} FOR UPDATE
    `
    const user = locked[0]

    if (!user) return { status: 'not_found' as const }
    const from = deriveAccountState(user)
    if (from === 'deleted') {
      return { status: 'already_deleted' as const, deletedAt: user.deletedAt! }
    }
    assertAccountTransition(from, 'deleted')

    const deletedAt = new Date()
    const participantRows = await tx.groupParticipant.findMany({
      where: { userId: accountId },
      select: { id: true },
    })
    const participantIds = participantRows.map(({ id }) => id)

    // Payments that involve this account keep their amounts, allocations and
    // reversals: those rows decide every other member's balance. Deleting a
    // SettlementReversal made a reversed payment count again, and deleting an
    // allocation re-routed a simplified payment between two other people.
    // Only the free-form note is personal data.
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
    await tx.transaction.updateMany({
      where: { OR: transactionConditions },
      data: { note: null },
    })

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
    await tx.friendInvitation.deleteMany({ where: { inviterId: accountId } })
    await tx.friendClaimRateLimit.deleteMany({ where: { accountId } })
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
