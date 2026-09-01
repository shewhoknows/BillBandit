import assert from 'node:assert/strict'
import test from 'node:test'
import {
  CloudKitImportValidationError,
  normalizeCloudKitExport,
  parseExactMoney,
  sourceRecordKey,
} from '../../lib/migrations/cloudkit'

function record(overrides: Record<string, unknown> = {}) {
  return {
    database: 'private',
    zone: 'BillBandit.Group.zone-1',
    recordType: 'BBGroup',
    recordName: 'group-1',
    checksum: 'checksum-group-1',
    fields: {
      id: 'group-1',
      name: 'Trip',
      currency: 'INR',
      memberIDs: ['person-1'],
    },
    ...overrides,
  }
}

const owner = {
  cloudKitRecordName: 'owner-cloudkit',
}

test('normalizes the minimal envelope and deduplicates identical source records', () => {
  const normalized = normalizeCloudKitExport({
    source: 'cloudkit',
    migrationId: 'migration-1',
    owner,
    database: 'private',
    zone: 'BillBandit.Group.zone-1',
    claims: [
      {
        personRecordName: 'person-1',
        cloudKitRecordName: 'owner-cloudkit',
        accountId: 'account-1',
      },
    ],
    records: [record(), record()],
  })

  assert.equal(normalized.sourceKey, 'migration-1')
  assert.equal(normalized.ownerCloudKitRecordName, 'owner-cloudkit')
  assert.equal(normalized.records.length, 1)
  assert.equal(normalized.records[0].recordType, 'group')
  assert.equal(normalized.records[0].zoneName, 'BillBandit.Group.zone-1')
  assert.deepEqual(normalized.claims, [
    {
      personRecordName: 'person-1',
      cloudKitRecordName: 'owner-cloudkit',
      accountId: 'account-1',
    },
  ])
})

test('rejects the same CloudKit identity with a changed checksum', () => {
  assert.throws(
    () =>
      normalizeCloudKitExport({
        source: 'cloudkit',
        owner,
        records: [record(), record({ checksum: 'checksum-group-2' })],
      }),
    (error: unknown) =>
      error instanceof CloudKitImportValidationError &&
      error.code === 'duplicate_source_record_conflict'
  )
})

test('source keys include every CloudKit dedupe dimension', () => {
  const left = sourceRecordKey({
    database: 'private',
    zoneName: 'zone-a',
    zoneOwnerName: 'owner-a',
    recordType: 'group',
    recordName: 'record-a',
  })
  const right = sourceRecordKey({
    database: 'shared',
    zoneName: 'zone-b',
    zoneOwnerName: 'owner-b',
    recordType: 'group',
    recordName: 'record-a',
  })

  assert.notEqual(left, right)
})

test('money parsing keeps signed zero-safe minor units and rejects floats', () => {
  assert.deepEqual(parseExactMoney({
    minorUnits: '-500',
    currencyCode: 'INR',
    currencyExponent: 2,
  }), {
    minorUnits: -500n,
    currencyCode: 'INR',
    currencyExponent: 2,
  })
  assert.deepEqual(parseExactMoney({
    minorUnits: '0',
    currencyCode: 'JPY',
    currencyExponent: 0,
  }), {
    minorUnits: 0n,
    currencyCode: 'JPY',
    currencyExponent: 0,
  })
  assert.throws(() => parseExactMoney(12.34), /exact money object or decimal string/)
  assert.throws(() => parseExactMoney({
    minorUnits: '-0',
    currencyCode: 'INR',
    currencyExponent: 2,
  }), /canonical signed-integer string/)
  assert.throws(() => parseExactMoney('1.001', { currencyCode: 'INR' }), /representable/)
})
