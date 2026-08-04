import assert from 'node:assert/strict'
import test from 'node:test'
import { PrismaClient } from '@prisma/client'
import {
  CloudKitImportValidationError,
  importCloudKitLedger,
} from '../../lib/migrations/cloudkit'

const databaseUrl = process.env.CLOUDKIT_TEST_DATABASE_URL

test('imports a CloudKit ledger exactly once and freezes the completed source', { skip: !databaseUrl }, async () => {
  const db = new PrismaClient({ datasources: { db: { url: databaseUrl! } } })
  const ownerId = `cloudkit-owner-${Date.now()}`
  const memberId = `${ownerId}-member`
  const ownerSubject = `${ownerId}-subject`
  const memberSubject = `${memberId}-subject`
  const now = new Date('2026-08-04T00:00:00.000Z')
  let serverGroupId: string | null = null
  const exportEnvelope = {
    source: 'cloudkit',
    migrationId: `${ownerId}-migration`,
    checksum: `${ownerId}-checksum-1`,
    owner: { cloudKitRecordName: ownerSubject },
    database: 'private',
    zone: 'BillBandit.Group.runtime',
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
        recordName: 'group-runtime',
        checksum: `${ownerId}-group`,
        fields: { id: 'group-runtime', name: 'Runtime group', currency: 'USD', memberIDs: ['person-owner', 'person-member'] },
      },
      {
        recordType: 'BBExpense',
        recordName: 'expense-runtime',
        checksum: `${ownerId}-expense`,
        fields: {
          id: 'expense-runtime',
          groupID: 'group-runtime',
          title: 'Dinner',
          amount: { minorUnits: '1000', currencyCode: 'USD', currencyExponent: 2 },
          paidByID: 'person-owner',
          date: '2026-08-01T00:00:00.000Z',
          splits: [
            { id: 'split-owner', personID: 'person-owner', modeRaw: 'equal', valueString: '5.00', computedAmountString: '5.00' },
            { id: 'split-member', personID: 'person-member', mode: 'equal', amount: { minorUnits: '500', currencyCode: 'USD', currencyExponent: 2 } },
          ],
        },
      },
      {
        recordType: 'BBSettlement',
        recordName: 'settlement-runtime',
        checksum: `${ownerId}-settlement`,
        fields: {
          id: 'settlement-runtime',
          groupID: 'group-runtime',
          fromID: 'person-owner',
          toID: 'person-member',
          amount: { minorUnits: '100', currencyCode: 'USD', currencyExponent: 2 },
          date: '2026-08-02T00:00:00.000Z',
        },
      },
      {
        recordType: 'BBActivity',
        recordName: 'activity-runtime',
        checksum: `${ownerId}-activity`,
        fields: {
          id: 'activity-runtime',
          groupID: 'group-runtime',
          actorID: 'person-owner',
          kind: 'expenseAdded',
          summary: 'Owner added dinner',
          timestamp: '2026-08-02T00:00:00.000Z',
        },
      },
    ],
  }

  try {
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

    const first = await importCloudKitLedger({ accountId: ownerId, export: exportEnvelope, db, now })
    const second = await importCloudKitLedger({ accountId: ownerId, export: exportEnvelope, db, now })

    assert.equal(first.status, 'completed')
    assert.deepEqual(second, first)
    assert.equal(first.counts.people, 2)
    assert.equal(first.counts.groups, 1)
    assert.equal(first.counts.expenses, 1)
    assert.equal(first.counts.splits, 2)
    assert.equal(first.counts.settlements, 1)
    assert.equal(first.counts.activity, 1)
    assert.equal(first.serverGroupIds.length, 1)
    serverGroupId = first.serverGroupIds[0] ?? null
    assert.equal(first.migrationMarkers[0]?.dualWriteEnabled, false)
    assert.equal(await db.group.count({ where: { id: first.serverGroupIds[0] } }), 1)
    assert.equal(await db.expense.count({ where: { groupId: first.serverGroupIds[0] } }), 1)
    assert.equal(await db.expenseSplit.count({ where: { expense: { groupId: first.serverGroupIds[0] } } }), 2)
    assert.equal(await db.transaction.count({ where: { groupId: first.serverGroupIds[0] } }), 1)
    assert.equal(await db.activityLog.count({ where: { metadata: { path: ['migrationId'], equals: first.importId } } }), 1)

    await assert.rejects(
      () => importCloudKitLedger({
        accountId: ownerId,
        export: { ...exportEnvelope, checksum: `${ownerId}-checksum-2` },
        db,
        now,
      }),
      (error: unknown) => error instanceof CloudKitImportValidationError && error.code === 'completed_import_frozen'
    )
  } finally {
    await db.ledgerImport.deleteMany({ where: { accountId: { in: [ownerId, memberId] } } })
    await db.transaction.deleteMany({ where: { senderId: { in: [ownerId, memberId] } } })
    await db.activityLog.deleteMany({ where: { userId: { in: [ownerId, memberId] } } })
    await db.expenseSplit.deleteMany({ where: { userId: { in: [ownerId, memberId] } } })
    await db.expense.deleteMany({ where: { paidById: { in: [ownerId, memberId] } } })
    await db.groupParticipant.deleteMany({ where: { userId: { in: [ownerId, memberId] } } })
    await db.groupMember.deleteMany({ where: { userId: { in: [ownerId, memberId] } } })
    if (serverGroupId) await db.group.deleteMany({ where: { id: serverGroupId } })
    await db.externalIdentity.deleteMany({ where: { accountId: { in: [ownerId, memberId] } } })
    await db.user.deleteMany({ where: { id: { in: [ownerId, memberId] } } })
    await db.$disconnect()
  }
})
