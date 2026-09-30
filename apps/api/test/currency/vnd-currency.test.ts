import assert from 'node:assert/strict'
import test from 'node:test'
import { parseDecimalToMinorUnits, formatMinorUnits } from '../../lib/settlement/money/canonical'
import { buildSimplifiedPlan } from '../../lib/settlement/ledger/projections'
import type { GroupLedgerInput } from '../../lib/settlement/ledger/types'
import { createGroupSchema } from '../../lib/validations-mobile-ledger'

const participants = [
  { id: 'p-alice', userId: 'alice', displayName: 'Alice', status: 'ACTIVE' as const },
  { id: 'p-bob', userId: 'bob', displayName: 'Bob', status: 'ACTIVE' as const },
  { id: 'p-cleo', userId: 'cleo', displayName: 'Cleo', status: 'ACTIVE' as const },
]

function ledger(
  currency: string,
  amountMinorUnits: bigint,
  splits: Array<[string, bigint]>,
  exponent = 0
): GroupLedgerInput {
  return {
    groupId: 'group-vnd',
    settlementVersion: 1,
    simplifyDebts: true,
    participants,
    expenses: [{
      id: `expense-${currency}`,
      paidByUserId: 'alice',
      currency,
      amountMinorUnits,
      currencyExponent: exponent,
      splits: splits.map(([userId, amount], index) => ({
        id: `split-${index}`,
        userId,
        amountMinorUnits: amount,
        currencyExponent: exponent,
      })),
    }],
    settlements: [],
  }
}

test('VND uses exponent zero and preserves whole-unit formatting', () => {
  const amount = parseDecimalToMinorUnits('100001', 'VND')
  assert.deepEqual(amount, {
    currencyCode: 'VND',
    currencyExponent: 0,
    minorUnits: 100001n,
  })
  assert.equal(formatMinorUnits(amount), '100001')
  const fractional = parseDecimalToMinorUnits('100001.5', 'VND')
  assert.equal('code' in fractional ? fractional.code : undefined, 'NONREPRESENTABLE')
})

test('VND equal odd split keeps the remainder deterministic', () => {
  const plan = buildSimplifiedPlan(ledger('VND', 100001n, [
    ['bob', 50001n],
    ['cleo', 50000n],
  ]))

  assert.deepEqual(
    plan
      .map((transfer) => [transfer.payerParticipantId, transfer.recipientParticipantId, transfer.amount.minorUnits])
      .sort((a, b) => (a[2] < b[2] ? -1 : 1)),
    [
      ['p-cleo', 'p-alice', 50000n],
      ['p-bob', 'p-alice', 50001n],
    ]
  )
})

test('VND unequal split remains exact in minor units', () => {
  const plan = buildSimplifiedPlan(ledger('VND', 100001n, [
    ['bob', 70001n],
    ['cleo', 30000n],
  ]))
  assert.deepEqual(
    plan.map((transfer) => transfer.amount.minorUnits).sort((a, b) => (a < b ? -1 : 1)),
    [30000n, 70001n]
  )
})

test('mixed currencies stay separate and are never netted', () => {
  const vnd = buildSimplifiedPlan(ledger('VND', 100001n, [['bob', 100001n]]))
  const usd = buildSimplifiedPlan({
    ...ledger('USD', 10001n, [['bob', 10001n]], 2),
    groupId: 'group-mixed',
  })
  assert.equal(vnd.length, 1)
  assert.equal(usd.length, 1)
  assert.equal(vnd[0].amount.currencyCode, 'VND')
  assert.equal(usd[0].amount.currencyCode, 'USD')
  assert.notEqual(vnd[0].amount.currencyCode, usd[0].amount.currencyCode)
})

test('new groups default to INR and accept only registered VND currency', () => {
  assert.equal(createGroupSchema.parse({ name: 'Legacy default' }).currency, 'INR')
  assert.equal(createGroupSchema.parse({ name: 'Vietnam', currency: 'VND' }).currency, 'VND')
  assert.throws(() => createGroupSchema.parse({ name: 'Unknown', currency: 'ZZZ' }))
})
