import assert from 'node:assert/strict'
import test from 'node:test'
import type { Prisma, PrismaClient } from '@prisma/client'
import { createLedgerTestDatabase } from '../integration/ledger-harness'
import { seedLedgerFixture } from '../integration/ledger-fixtures'

let database: Awaited<ReturnType<typeof createLedgerTestDatabase>> | undefined
let db!: PrismaClient
let executeMutation!: (typeof import('../../lib/ledger/mutation'))['executeMutation']
let LedgerMutationError!: (typeof import('../../lib/ledger/mutation'))['LedgerMutationError']
let executeSettlement!: (typeof import('../../lib/settlement/commands/settle'))['executeSettlement']
let importCloudKitLedger!: (typeof import('../../lib/migrations/cloudkit'))['importCloudKitLedger']
let resumeCloudKitImport!: (typeof import('../../lib/migrations/cloudkit'))['resumeCloudKitImport']

test.before(async () => {
  database = await createLedgerTestDatabase()
  db = database.db
  const mutation = await import('../../lib/ledger/mutation')
  const settlement = await import('../../lib/settlement/commands/settle')
  const cloudkit = await import('../../lib/migrations/cloudkit')
  executeMutation = mutation.executeMutation
  LedgerMutationError = mutation.LedgerMutationError
  executeSettlement = settlement.executeSettlement
  importCloudKitLedger = cloudkit.importCloudKitLedger
  resumeCloudKitImport = cloudkit.resumeCloudKitImport
})

test.after(async () => database?.close())

class TransientTransactionFault {
  private armed = true
  private calls = 0

  constructor(
    private readonly database: PrismaClient,
    private readonly point: 'before' | 'after',
    private readonly failOnCall = 1
  ) {}

  get ledgerImport() {
    return this.database.ledgerImport
  }

  get ledgerImportRecord() {
    return this.database.ledgerImportRecord
  }

  async $transaction<T>(callback: (tx: Prisma.TransactionClient) => Promise<T>): Promise<T> {
    this.calls += 1
    if (this.point === 'before' && this.armed && this.calls === this.failOnCall) {
      this.armed = false
      throw Object.assign(new Error('simulated transient timeout before commit'), { code: 'P2034' })
    }
    const result = await this.database.$transaction(callback)
    if (this.point === 'after' && this.armed && this.calls === this.failOnCall) {
      this.armed = false
      throw Object.assign(new Error('simulated timeout after commit'), { code: 'P2034' })
    }
    return result
  }
}

function request(groupId: string, accountId: string, operationId: string, expenseId: string) {
  return {
    groupId,
    operationId,
    expectedRevision: 0,
    accountId,
    actorUserId: accountId,
    kind: 'expense.create' as const,
    payload: {
      expenseId,
      description: 'Fault-injected lunch',
      amount: { minorUnits: '125', currencyCode: 'USD', currencyExponent: 2 },
      paidById: accountId,
      splitType: 'EXACT' as const,
      splits: [{ userId: accountId, amount: { minorUnits: '125', currencyCode: 'USD', currencyExponent: 2 } }],
    },
  }
}

test('a transient failure before commit is retried and applies exactly once', async () => {
  const fixture = await seedLedgerFixture(db, 'fault-before', { expenseMinorUnits: null })
  const result = await executeMutation(
    request(fixture.groupId, fixture.aliceId, 'fault-before-operation', `${fixture.groupId}-expense`),
    { db: new TransientTransactionFault(db, 'before') as unknown as PrismaClient, maxRetries: 1 }
  )

  assert.equal(result.outcome, 'applied')
  assert.equal(result.revision, 1)
  assert.equal(await db.expense.count({ where: { groupId: fixture.groupId } }), 1)
  assert.equal(await db.settlementVersionJournal.count({ where: { groupId: fixture.groupId } }), 1)
})

test('a timeout after commit replays the committed operation without a duplicate', async () => {
  const fixture = await seedLedgerFixture(db, 'fault-after', { expenseMinorUnits: null })
  const result = await executeMutation(
    request(fixture.groupId, fixture.aliceId, 'fault-after-operation', `${fixture.groupId}-expense`),
    { db: new TransientTransactionFault(db, 'after') as unknown as PrismaClient, maxRetries: 1 }
  )

  assert.equal(result.outcome, 'replayed')
  assert.equal(result.replayed, true)
  assert.equal(result.revision, 1)
  assert.equal(await db.expense.count({ where: { groupId: fixture.groupId } }), 1)
  assert.equal(await db.expenseSplit.count({ where: { expense: { groupId: fixture.groupId } } }), 1)
  assert.equal(await db.ledgerOperation.count({ where: { accountId: fixture.aliceId } }), 1)
  assert.equal(await db.settlementVersionJournal.count({ where: { groupId: fixture.groupId } }), 1)
})

test('an unresolved money migration issue prevents a settlement financial write', async () => {
  const fixture = await seedLedgerFixture(db, 'migration-block', { expenseMinorUnits: null })
  const expenseId = `${fixture.groupId}-unresolved-expense`
  await db.expense.create({
    data: {
      id: expenseId,
      description: 'Legacy unresolved expense',
      amount: 10,
      currency: 'USD',
      groupId: fixture.groupId,
      paidById: fixture.aliceId,
      splitType: 'EXACT',
      splits: {
        create: [{ userId: fixture.bobId, amount: 10 }],
      },
    },
  })
  await db.moneyMigrationIssue.create({
    data: {
      tableName: 'Expense',
      recordId: expenseId,
      groupId: fixture.groupId,
      currencyCode: 'USD',
      reason: 'AMBIGUOUS_LEGACY_VALUE',
      floatValue: '10',
    },
  })

  await assert.rejects(
    () => executeSettlement({
      groupId: fixture.groupId,
      userId: fixture.bobId,
      idempotencyKey: 'blocked-settlement',
      expectedVersion: 0,
      planTransferId: 'unavailable-because-money-is-unresolved',
      payerParticipantId: fixture.bobParticipantId,
      recipientParticipantId: fixture.aliceParticipantId,
      currencyCode: 'USD',
      currencyExponent: 2,
      minorUnits: '1000',
      db,
    }),
    (error: unknown) => error instanceof LedgerMutationError && error.code === 'TRANSFER_NOT_FOUND'
  )

  assert.equal(await db.transaction.count({ where: { groupId: fixture.groupId } }), 0)
  assert.equal(await db.settlementAllocation.count({ where: { groupId: fixture.groupId } }), 0)
  assert.equal((await db.group.findUniqueOrThrow({ where: { id: fixture.groupId } })).settlementVersion, 0)
})

function importEnvelope(ownerId: string, memberId: string) {
  const ownerSubject = `${ownerId}-cloudkit`
  const memberSubject = `${memberId}-cloudkit`
  return {
    source: 'cloudkit',
    migrationId: `${ownerId}-migration`,
    checksum: `${ownerId}-checksum`,
    owner: { cloudKitRecordName: ownerSubject },
    database: 'private',
    zone: 'BillBandit.Ledger',
    defaultCurrency: { currencyCode: 'USD', currencyExponent: 2 },
    claims: [
      { personRecordName: 'person-owner', cloudKitRecordName: ownerSubject, accountId: ownerId },
      { personRecordName: 'person-member', cloudKitRecordName: memberSubject, accountId: memberId },
    ],
    records: [
      {
        recordType: 'BBPerson',
        recordName: 'person-owner',
        checksum: `${ownerId}-person-owner`,
        fields: { id: 'person-owner', name: 'Owner', cloudUser: ownerSubject },
      },
      {
        recordType: 'BBPerson',
        recordName: 'person-member',
        checksum: `${ownerId}-person-member`,
        fields: { id: 'person-member', name: 'Member', cloudUser: memberSubject },
      },
      {
        recordType: 'BBGroup',
        recordName: 'group-resume',
        checksum: `${ownerId}-group`,
        fields: { id: 'group-resume', name: 'Resume group', currency: 'USD', memberIDs: ['person-owner', 'person-member'] },
      },
      {
        recordType: 'BBExpense',
        recordName: 'expense-resume',
        checksum: `${ownerId}-expense`,
        fields: {
          id: 'expense-resume',
          groupID: 'group-resume',
          title: 'Resume dinner',
          amount: { minorUnits: '1000', currencyCode: 'USD', currencyExponent: 2 },
          paidByID: 'person-owner',
          date: '2026-08-04T00:00:00.000Z',
          splits: [
            { id: 'split-owner', personID: 'person-owner', amount: { minorUnits: '500', currencyCode: 'USD', currencyExponent: 2 } },
            { id: 'split-member', personID: 'person-member', amount: { minorUnits: '500', currencyCode: 'USD', currencyExponent: 2 } },
          ],
        },
      },
    ],
  }
}

test('a timed-out import resumes from imported records without duplicate financial rows', async () => {
  const ownerId = `resume-owner-${Date.now()}`
  const memberId = `${ownerId}-member`
  const ownerSubject = `${ownerId}-cloudkit`
  const memberSubject = `${memberId}-cloudkit`
  await db.user.createMany({
    data: [
      { id: ownerId, email: `${ownerId}@example.test`, name: 'Owner' },
      { id: memberId, email: `${memberId}@example.test`, name: 'Member' },
    ],
  })
  await db.externalIdentity.createMany({
    data: [
      { accountId: ownerId, provider: 'cloudkit', subject: ownerSubject },
      { accountId: memberId, provider: 'cloudkit', subject: memberSubject },
    ],
  })
  const envelope = importEnvelope(ownerId, memberId)
  // prepareImport and the second validation transaction complete before the
  // first source record is committed.
  const failingDb = new TransientTransactionFault(db, 'after', 3)

  await assert.rejects(
    () => importCloudKitLedger({ accountId: ownerId, export: envelope, db: failingDb as unknown as PrismaClient, now: new Date('2026-08-04T00:00:00.000Z') }),
    /simulated timeout after commit/
  )

  const partial = await db.ledgerImport.findUniqueOrThrow({ where: { accountId_sourceSystem_sourceKey: { accountId: ownerId, sourceSystem: 'cloudkit', sourceKey: `${ownerId}-migration` } } })
  assert.equal(partial.state, 'RUNNING')
  assert.ok(await db.ledgerImportRecord.count({ where: { importId: partial.id, state: 'IMPORTED' } }) >= 1)

  const resumed = await resumeCloudKitImport({
    accountId: ownerId,
    importId: partial.id,
    db,
    now: new Date('2026-08-04T00:01:00.000Z'),
  })
  const replayed = await resumeCloudKitImport({ accountId: ownerId, importId: partial.id, db })

  assert.equal(resumed.status, 'completed')
  assert.deepEqual(replayed, resumed)
  assert.equal(resumed.counts.people, 2)
  assert.equal(resumed.counts.groups, 1)
  assert.equal(resumed.counts.expenses, 1)
  assert.equal(resumed.counts.splits, 2)
  assert.equal(resumed.counts.duplicateRecords, 0)
  assert.ok(resumed.serverGroupId)
  assert.equal(await db.group.count({ where: { id: resumed.serverGroupId } }), 1)
  assert.equal(await db.expense.count({ where: { groupId: resumed.serverGroupId } }), 1)
  assert.equal(await db.expenseSplit.count({ where: { expense: { groupId: resumed.serverGroupId } } }), 2)
  assert.equal(await db.transaction.count({ where: { groupId: resumed.serverGroupId } }), 0)
})
