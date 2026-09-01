import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import {
  addMoney,
  aggregateMoneyByCurrency,
  assertIdempotencyReplay,
  formatExactMoney,
  hashLedgerRequest,
  parseMoney,
  parseMutationFixture,
  parseSharedLedgerFixture,
  roundTripJson,
  stableStringify,
  type Money,
} from '../../lib/ledger-contract'

const here = dirname(fileURLToPath(import.meta.url))
const fixtureDirectory = join(here, '../fixtures/ledger-v2')

function loadFixture(name: string): unknown {
  return JSON.parse(readFileSync(join(fixtureDirectory, name), 'utf8')) as unknown
}

function amount(minorUnits: string, currencyCode: string, currencyExponent: number): Money {
  return { minorUnits, currencyCode, currencyExponent }
}

test('shared ledger fixture round-trips and exposes every balance surface', () => {
  const raw = loadFixture('shared-ledger.json')
  const fixture = parseSharedLedgerFixture(raw)
  const roundTripped = parseSharedLedgerFixture(roundTripJson(fixture))

  assert.equal(stableStringify(roundTripped), stableStringify(fixture))
  assert.equal(fixture.read.revision, 7)
  assert.equal(fixture.read.readRevision, 7)
  assert.equal(fixture.read.data.group.revision, fixture.read.revision)
  assert.equal(fixture.read.data.group.expenses.length, 6)
  assert.equal(fixture.read.data.group.members.length, 3)
  assert.equal(fixture.read.data.group.settlementPlan.transfers.length, 4)
  assert.equal(fixture.read.data.group.settlementHistory.length, 3)
  assert.equal(fixture.read.data.group.activity.length, 8)

  const splitMethods = new Set(fixture.read.data.group.expenses.map((expense) => expense.splitMethod))
  assert.deepEqual(splitMethods, new Set(['EQUAL', 'EXACT', 'PERCENTAGE', 'SHARES']))

  const group = fixture.read.data.group
  assert.deepEqual(
    group.balances.currentAccount.byCurrency,
    fixture.read.data.account.balance.byCurrency
  )
  assert.deepEqual(
    group.balances.byCurrency.map((entry) => entry.net.minorUnits),
    ['0', '0', '0']
  )
  assert.equal(group.balances.byCurrency[0].currency.currencyCode, 'INR')
  assert.equal(group.balances.byCurrency[1].currency.currencyCode, 'JPY')
  assert.equal(group.balances.byCurrency[2].currency.currencyCode, 'KWD')
})

test('money is exact, signed, exponent-aware, and never nets currencies together', () => {
  assert.equal(formatExactMoney(amount('12345', 'INR', 2)), 'INR 123.45')
  assert.equal(formatExactMoney(amount('-500', 'INR', 2)), 'INR -5.00')
  assert.equal(formatExactMoney(amount('0', 'JPY', 0)), 'JPY 0')
  assert.equal(formatExactMoney(amount('1234', 'KWD', 3)), 'KWD 1.234')

  const grouped = aggregateMoneyByCurrency([
    amount('100', 'INR', 2),
    amount('-40', 'INR', 2),
    amount('5', 'JPY', 0),
  ])
  assert.deepEqual(grouped, [amount('60', 'INR', 2), amount('5', 'JPY', 0)])
  assert.throws(
    () => addMoney(amount('100', 'INR', 2), amount('1', 'JPY', 0)),
    /Cannot combine INR and JPY/
  )

  assert.throws(
    () => parseMoney({ minorUnits: 100, currencyCode: 'INR', currencyExponent: 2 }),
    /minorUnits/
  )
  assert.throws(
    () => parseMoney({ minorUnits: '-0', currencyCode: 'INR', currencyExponent: 2 }),
    /minorUnits/
  )
  assert.throws(
    () => parseMoney({ minorUnits: '1', currencyCode: 'KWD', currencyExponent: 2 }),
    /does not match/
  )
})

test('identity, migration, cache, authority, and local-only boundaries are explicit', () => {
  const fixture = parseSharedLedgerFixture(loadFixture('shared-ledger.json'))
  const { account, group } = fixture.read.data

  assert.equal(group.scope, 'shared')
  assert.equal(group.localOnly, false)
  assert.equal(account.sharedGroups[0].localOnly, false)
  assert.deepEqual(fixture.excludedLocalOnlyGroupIds, ['local-only-001'])
  assert.equal(account.sharedGroups.some((entry) => fixture.excludedLocalOnlyGroupIds.includes(entry.groupId)), false)

  assert.equal(account.accountId, 'acct-alex-001')
  assert.equal(account.currentMemberId, 'mem-alex-001')
  assert.equal(group.members[0].memberId, 'mem-alex-001')
  assert.notEqual(group.members[0].memberId, group.members[0].displayName)
  assert.equal(group.members[2].localIdentityId, null)

  assert.equal(group.migration.status, 'complete')
  assert.equal(group.migration.dualWriteEnabled, false)
  assert.equal(group.migration.recoveryReadOnly, true)
  assert.equal(group.authority.serverAuthoritative, true)
  assert.equal(group.authority.cacheRole, 'offline-cache')
  assert.deepEqual(group.pendingOperationIds, ['op-expense-retry-001'])
  assert.equal(account.pendingOperations[0].expectedRevision, group.revision)
  assert.equal(group.stale.isStale, false)
})

test('mutation envelopes freeze revision and idempotency semantics', () => {
  const fixture = parseMutationFixture(loadFixture('mutation-envelopes.json'))
  assertIdempotencyReplay(fixture.applied, fixture.replayed)

  assert.equal(fixture.request.headers['Idempotency-Key'], fixture.applied.idempotency.key)
  assert.equal(fixture.applied.idempotency.requestHash, hashLedgerRequest(fixture.request.body))
  assert.equal(fixture.request.headers['Expected-Revision'], '7')
  assert.equal(fixture.request.headers['Client-Contract'], 'ledger-v2')
  assert.equal(fixture.request.headers['Client-Compatibility'], 'ledger-v2')
  assert.equal(fixture.applied.outcome, 'applied')
  assert.equal(fixture.replayed.outcome, 'replayed')
  assert.equal(fixture.applied.revision, fixture.replayed.revision)
  assert.equal(fixture.applied.result.recordId, fixture.replayed.result.recordId)

  assert.equal(fixture.revisionConflict.conflict.code, 'REVISION_CONFLICT')
  assert.equal(fixture.revisionConflict.conflict.expectedRevision, 7)
  assert.equal(fixture.revisionConflict.conflict.currentRevision, 8)
  assert.equal(fixture.revisionConflict.conflict.retryable, true)
  assert.equal(fixture.idempotencyConflict.conflict.code, 'IDEMPOTENCY_KEY_REUSED')
  assert.equal(fixture.idempotencyConflict.conflict.retryable, false)
  assert.equal(fixture.revisionConflict.authority.serverAuthoritative, true)
})

test('request hashes are deterministic over object key order', () => {
  assert.equal(hashLedgerRequest({ b: 2, a: 1 }), hashLedgerRequest({ a: 1, b: 2 }))
  assert.notEqual(hashLedgerRequest({ amount: '100' }), hashLedgerRequest({ amount: '101' }))
})
