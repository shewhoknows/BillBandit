import assert from 'node:assert/strict'
import test from 'node:test'
import { createLedgerTestDatabase } from './ledger-harness'
import { seedLedgerFixture } from './ledger-fixtures'

let database: Awaited<ReturnType<typeof createLedgerTestDatabase>> | undefined

test.before(async () => {
  database = await createLedgerTestDatabase()
})

test.after(async () => database?.close())

test('account deletion removes personal data and preserves shared ledger integrity', async () => {
  assert.ok(database)
  const { db } = database
  const fixture = await seedLedgerFixture(db, 'account-delete', { expenseMinorUnits: 1000n })
  const email = `${fixture.aliceId}@example.test`
  const transactionId = `${fixture.groupId}-transaction`
  const allocationId = `${fixture.groupId}-allocation`

  await db.account.create({
    data: {
      userId: fixture.aliceId,
      type: 'oauth',
      provider: 'apple',
      providerAccountId: `${fixture.aliceId}-apple`,
    },
  })
  await db.session.create({
    data: {
      userId: fixture.aliceId,
      sessionToken: `${fixture.aliceId}-session`,
      expires: new Date('2030-01-01T00:00:00.000Z'),
    },
  })
  await db.externalIdentity.create({
    data: {
      accountId: fixture.aliceId,
      provider: 'cloudkit',
      subject: `${fixture.aliceId}-cloud`,
    },
  })
  await db.comment.create({
    data: {
      content: 'Alice private note',
      expenseId: fixture.expenseId!,
      userId: fixture.aliceId,
    },
  })
  await db.activityLog.create({
    data: {
      userId: fixture.aliceId,
      type: 'EXPENSE_CREATED',
      description: 'Alice created a dinner expense',
    },
  })
  await db.ledgerOperation.create({
    data: {
      accountId: fixture.aliceId,
      operationKey: `${fixture.aliceId}-operation`,
      requestHash: 'hash',
      state: 'COMMITTED',
    },
  })
  const ledgerImport = await db.ledgerImport.create({
    data: {
      accountId: fixture.aliceId,
      sourceSystem: 'cloudkit',
      sourceKey: `${fixture.aliceId}-import`,
      state: 'COMPLETED',
      updatedAt: new Date(),
    },
  })
  await db.ledgerImportRecord.create({
    data: {
      accountId: fixture.aliceId,
      importId: ledgerImport.id,
      sourceSystem: 'cloudkit',
      sourceRecordKey: `${fixture.aliceId}-record`,
      sourceRecordType: 'BBExpense',
      state: 'IMPORTED',
      updatedAt: new Date(),
    },
  })
  await db.mobileOTPChallenge.create({
    data: {
      identifier: email,
      identifierType: 'email',
      codeHash: 'hash',
      expiresAt: new Date('2030-01-01T00:00:00.000Z'),
    },
  })
  await db.friendship.create({
    data: { fromId: fixture.aliceId, toId: fixture.bobId },
  })
  await db.transaction.create({
    data: {
      id: transactionId,
      senderId: fixture.aliceId,
      receiverId: fixture.bobId,
      amount: 10,
      amountMinorUnits: 1000n,
      currencyExponent: 2,
      currency: 'USD',
      note: 'Alice personal settlement note',
      groupId: fixture.groupId,
      payerParticipantId: fixture.aliceParticipantId,
      recipientParticipantId: fixture.bobParticipantId,
      actorUserId: fixture.aliceId,
      settlementMode: 'DIRECT',
      settlementGroupVersion: 1,
    },
  })
  await db.settlementAllocation.create({
    data: {
      id: allocationId,
      groupId: fixture.groupId,
      transactionId,
      settlementVersion: 1,
      mode: 'DIRECT',
      currencyCode: 'USD',
      currencyExponent: 2,
      amountMinorUnits: 1000n,
      paths: {
        create: {
          id: `${fixture.groupId}-path`,
          sequence: 0,
          flowMinorUnits: 1000n,
          obligationComponentKey: 'alice:bob',
          payerParticipantId: fixture.aliceParticipantId,
          recipientParticipantId: fixture.bobParticipantId,
        },
      },
    },
  })
  await db.settlementReversal.create({
    data: {
      groupId: fixture.groupId,
      transactionId,
      actorUserId: fixture.aliceId,
    },
  })
  await db.settlementSettingAudit.create({
    data: {
      groupId: fixture.groupId,
      actorUserId: fixture.aliceId,
      simplifyDebts: true,
    },
  })

  const { deleteMobileAccount } = await import('../../lib/account-deletion')
  const result = await deleteMobileAccount(fixture.aliceId, db)
  assert.equal(result.status, 'deleted')

  const user = await db.user.findUniqueOrThrow({ where: { id: fixture.aliceId } })
  assert.equal(user.name, 'Deleted user')
  assert.equal(user.username, null)
  assert.equal(user.email, `deleted+${fixture.aliceId}@deleted.billbandit.invalid`)
  assert.ok(user.deletedAt)
  assert.equal(await db.account.count({ where: { userId: fixture.aliceId } }), 0)
  assert.equal(await db.session.count({ where: { userId: fixture.aliceId } }), 0)
  assert.equal(await db.externalIdentity.count({ where: { accountId: fixture.aliceId } }), 0)
  assert.equal(await db.comment.count({ where: { userId: fixture.aliceId } }), 0)
  assert.equal(await db.activityLog.count({ where: { userId: fixture.aliceId } }), 0)
  assert.equal(await db.ledgerOperation.count({ where: { accountId: fixture.aliceId } }), 0)
  assert.equal(await db.ledgerImport.count({ where: { accountId: fixture.aliceId } }), 0)
  assert.equal(await db.mobileOTPChallenge.count({ where: { identifier: email } }), 0)
  assert.equal(await db.friendship.count({ where: { OR: [{ fromId: fixture.aliceId }, { toId: fixture.aliceId }] } }), 0)

  const expense = await db.expense.findUniqueOrThrow({ where: { id: fixture.expenseId! } })
  assert.equal(expense.description, 'Deleted user')
  assert.equal(expense.notes, null)
  assert.equal(await db.expenseSplit.count({ where: { expenseId: fixture.expenseId! } }), 2)
  assert.equal(await db.groupParticipant.findUniqueOrThrow({ where: { id: fixture.aliceParticipantId } }).then((row) => row.displayName), 'Deleted user')
  assert.equal(await db.groupMember.count({ where: { userId: fixture.aliceId } }), 1)
  assert.equal(await db.transaction.count({ where: { id: transactionId } }), 1)
  assert.equal(await db.transaction.findUniqueOrThrow({ where: { id: transactionId } }).then((row) => row.note), null)
  assert.equal(await db.settlementAllocation.count({ where: { id: allocationId } }), 0)
  assert.equal(await db.settlementAllocationPath.count({ where: { allocationId } }), 0)
  assert.equal(await db.settlementReversal.count({ where: { transactionId } }), 0)
  assert.equal(await db.settlementSettingAudit.count({ where: { actorUserId: fixture.aliceId } }), 1)

  const repeated = await deleteMobileAccount(fixture.aliceId, db)
  assert.equal(repeated.status, 'already_deleted')
})
