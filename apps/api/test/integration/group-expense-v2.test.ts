import assert from 'node:assert/strict'
import test from 'node:test'
import { NextRequest } from 'next/server'
import { type GroupLedgerReadModel } from '../../lib/ledger-contract'
import {
  buildGroupDetailResponseFromLedger,
  mobileExpenseFromLedger,
} from '../../lib/mobile-groups'
import { authorityMarkers } from '../../lib/ledger/read-model'
import {
  hasExactMoney,
  readMutationMetadata,
  toKernelExpensePayload,
} from '../../lib/mobile-expenses'
import { mobileExpenseV2Schema } from '../../lib/validations-mobile-ledger'

const INR = { currencyCode: 'INR', currencyExponent: 2 } as const

function model(): GroupLedgerReadModel {
  const amount = { ...INR, minorUnits: '125' }
  return {
    groupId: 'group-v2',
    accountId: 'user-alice',
    name: 'V2 group',
    baseCurrency: INR,
    scope: 'shared',
    localOnly: false,
    revision: 4,
    readRevision: 4,
    members: [
      {
        memberId: 'participant-alice',
        accountId: 'user-alice',
        localIdentityId: null,
        displayName: 'Alice',
        email: 'alice@example.com',
        role: 'owner',
        status: 'active',
      },
      {
        memberId: 'participant-bob',
        accountId: 'user-bob',
        localIdentityId: null,
        displayName: 'Bob',
        email: 'bob@example.com',
        role: 'member',
        status: 'active',
      },
    ],
    expenses: [
      {
        expenseId: 'expense-v2',
        description: 'Lunch',
        paidByMemberId: 'participant-alice',
        amount,
        splitMethod: 'EXACT',
        splits: [
          {
            splitId: 'split-alice',
            memberId: 'participant-alice',
            amount: { ...amount, minorUnits: '25' },
            percentage: null,
            shares: null,
          },
          {
            splitId: 'split-bob',
            memberId: 'participant-bob',
            amount: { ...amount, minorUnits: '100' },
            percentage: null,
            shares: null,
          },
        ],
        status: 'active',
        createdAt: '2026-08-04T10:00:00.000Z',
        updatedAt: '2026-08-04T10:00:00.000Z',
      },
    ],
    balances: {
      byMember: [
        { memberId: 'participant-alice', byCurrency: [{ ...amount, minorUnits: '100' }] },
        { memberId: 'participant-bob', byCurrency: [{ ...amount, minorUnits: '-100' }] },
      ],
      byCurrency: [
        {
          currency: INR,
          totalPositive: { ...amount, minorUnits: '100' },
          totalNegative: { ...amount, minorUnits: '-100' },
          net: { ...amount, minorUnits: '0' },
        },
      ],
      currentAccount: {
        accountId: 'user-alice',
        memberId: 'participant-alice',
        byCurrency: [{ ...amount, minorUnits: '100' }],
      },
    },
    settlementPlan: {
      revision: 4,
      mode: 'SIMPLIFIED',
      transfers: [
        {
          planTransferId: 'transfer-v2',
          payerMemberId: 'participant-bob',
          recipientMemberId: 'participant-alice',
          amount: { ...amount, minorUnits: '100' },
          mode: 'SIMPLIFIED',
          obligationComponentIds: ['expense-v2:split-bob'],
        },
      ],
    },
    settlementHistory: [],
    activity: [
      {
        activityId: 'activity-expense-v2',
        type: 'expense',
        expenseId: 'expense-v2',
        amount,
        at: '2026-08-04T10:00:00.000Z',
      },
    ],
    pendingOperationIds: [],
    migration: {
      status: 'not_required',
      source: 'none',
      migrationId: null,
      importedAt: null,
      dualWriteEnabled: false,
      recoveryReadOnly: false,
    },
    stale: {
      isStale: false,
      reason: 'none',
      observedAt: '2026-08-04T10:00:00.000Z',
      readRevision: 4,
      serverRevision: 4,
    },
    authority: authorityMarkers(),
  }
}

function expenseBody() {
  return {
    groupId: 'group-v2',
    operationId: 'expense-operation-1',
    expectedRevision: 4,
    expenseId: 'expense-new',
    description: 'Dinner',
    amount: { ...INR, minorUnits: '300' },
    paidByMemberId: 'participant-alice',
    splitMethod: 'EXACT',
    splits: [
      { memberId: 'participant-alice', amount: { ...INR, minorUnits: '100' } },
      { memberId: 'participant-bob', amount: { ...INR, minorUnits: '200' } },
    ],
  }
}

test('v2 expense payloads require exact money and legacy numbers are rejected', () => {
  const body = expenseBody()
  assert.equal(mobileExpenseV2Schema.safeParse(body).success, true)
  assert.equal(hasExactMoney(body.amount), true)
  assert.equal(hasExactMoney({ ...body.amount, minorUnits: 300 }), false)
  assert.equal(
    mobileExpenseV2Schema.safeParse({ ...body, amount: 300 }).success,
    false
  )
})

test('adapter maps canonical member IDs to account IDs without changing exact fields', () => {
  const payload = toKernelExpensePayload(expenseBody(), model(), 'expense.create')
  assert.equal(payload.paidById, 'user-alice')
  assert.equal(payload.amount?.minorUnits, '300')
  assert.deepEqual(
    payload.splits?.map((split) => [split.userId, split.amount.minorUnits]),
    [
      ['user-alice', '100'],
      ['user-bob', '200'],
    ]
  )
})

test('operation ID and expected revision are mandatory and may be supplied by headers', () => {
  const missing = readMutationMetadata(new NextRequest('http://localhost'), {})
  assert.ok('response' in missing)
  assert.equal(missing.response.status, 400)

  const request = new NextRequest('http://localhost', {
    headers: {
      'Idempotency-Key': 'header-operation-1',
      'Expected-Revision': '4',
    },
  })
  const parsed = readMutationMetadata(request, {})
  assert.deepEqual(parsed, {
    metadata: { operationId: 'header-operation-1', expectedRevision: 4 },
  })
})

test('canonical read adapter keeps exact money authoritative and exposes bounded legacy projection', () => {
  const source = model()
  const expense = mobileExpenseFromLedger(source, 'expense-v2')!
  assert.equal(expense.money?.minorUnits, '125')
  assert.equal(expense.amountMinorUnits, '125')
  assert.equal(expense.amount, 1.25)
  assert.equal(expense.splits[1].money?.minorUnits, '100')

  const detail = buildGroupDetailResponseFromLedger(source)
  assert.equal(detail.group.revision, 4)
  assert.equal(detail.ledger.expenses[0].amount.minorUnits, '125')
  assert.equal(detail.balances.simplifiedDebts[0].money.minorUnits, '100')
})
