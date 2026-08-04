import type { PrismaClient } from '@prisma/client'

export type LedgerFixture = {
  groupId: string
  aliceId: string
  bobId: string
  aliceParticipantId: string
  bobParticipantId: string
  expenseId: string | null
}

export async function seedLedgerFixture(
  db: PrismaClient,
  label: string,
  options: { expenseMinorUnits?: bigint | null } = {}
): Promise<LedgerFixture> {
  const prefix = `ledger-${label}-${Date.now()}-${Math.random().toString(16).slice(2)}`
  const aliceId = `${prefix}-alice`
  const bobId = `${prefix}-bob`
  const groupId = `${prefix}-group`
  // The current database read adapter uses Expense.paidById/ExpenseSplit.userId
  // as canonical member keys, so the disposable fixture keeps participant IDs
  // aligned with their account IDs while preserving distinct GroupMember IDs.
  const aliceParticipantId = aliceId
  const bobParticipantId = bobId
  const expenseId = options.expenseMinorUnits === null ? null : `${prefix}-expense`

  await db.user.createMany({
    data: [
      { id: aliceId, email: `${aliceId}@example.test`, name: 'Alice' },
      { id: bobId, email: `${bobId}@example.test`, name: 'Bob' },
    ],
  })
  await db.group.create({
    data: {
      id: groupId,
      name: `Ledger fixture ${label}`,
      currency: 'USD',
      settlementVersion: 0,
      simplifyDebts: true,
    },
  })
  await db.groupMember.createMany({
    data: [
      { id: `${prefix}-member-alice`, groupId, userId: aliceId, role: 'ADMIN' },
      { id: `${prefix}-member-bob`, groupId, userId: bobId, role: 'MEMBER' },
    ],
  })
  await db.groupParticipant.createMany({
    data: [
      { id: aliceParticipantId, groupId, userId: aliceId, displayName: 'Alice', status: 'ACTIVE' },
      { id: bobParticipantId, groupId, userId: bobId, displayName: 'Bob', status: 'ACTIVE' },
    ],
  })

  if (expenseId) {
    const amountMinorUnits = options.expenseMinorUnits ?? 1000n
    await db.expense.create({
      data: {
        id: expenseId,
        description: 'Fixture dinner',
        amount: Number(amountMinorUnits) / 100,
        amountMinorUnits,
        currencyExponent: 2,
        currency: 'USD',
        groupId,
        paidById: aliceId,
        splitType: 'EXACT',
        date: new Date('2026-08-04T00:00:00.000Z'),
        splits: {
          create: [
            {
              id: `${prefix}-split-alice`,
              userId: aliceId,
              amount: 0,
              amountMinorUnits: 0n,
              currencyExponent: 2,
            },
            {
              id: `${prefix}-split-bob`,
              userId: bobId,
              amount: Number(amountMinorUnits) / 100,
              amountMinorUnits,
              currencyExponent: 2,
            },
          ],
        },
      },
    })
  }

  return { groupId, aliceId, bobId, aliceParticipantId, bobParticipantId, expenseId }
}
