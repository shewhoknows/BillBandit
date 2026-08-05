import assert from 'node:assert/strict'
import { test } from 'node:test'
import { loadGroupReadModel } from '../../lib/ledger/read-model/loader'
import {
  buildAccountLedgerSummary,
  buildGroupLedgerReadEnvelope,
} from '../../lib/ledger/read-model/projection'
import type { MigrationState } from '../../lib/ledger-contract'
import type { ReadModelGroupSource } from '../../lib/ledger/read-model/types'

const user = {
  id: 'user-1',
  name: 'Prateek',
  preferredName: null,
  email: 'prateek@example.com',
  externalIdentities: [],
}

const migration: MigrationState = {
  status: 'not_required',
  source: 'none',
  migrationId: null,
  importedAt: null,
  dualWriteEnabled: false,
  recoveryReadOnly: false,
}

// ─── Loader translation ──────────────────────────────────────────────────────
// Production data stores USER ids in Expense.paidById / ExpenseSplit.userId
// (FKs to User.id). The read model keys members by PARTICIPANT id, so the
// loader must translate — exactly like it already does for settlements.
function groupWithExpense() {
  return {
    id: 'grp-exp-001',
    name: 'With Expense',
    description: null,
    currency: 'INR',
    category: 'OTHER',
    simplifyDebts: true,
    settlementVersion: 1,
    isArchived: false,
    updatedAt: new Date('2026-07-30T15:30:48.975Z'),
    members: [
      { id: 'gm-1', userId: 'user-1', role: 'ADMIN', user },
      { id: 'gm-2', userId: 'user-2', role: 'MEMBER', user: { ...user, id: 'user-2', name: 'Other' } },
    ],
    participants: [
      { id: 'part-1', userId: 'user-1', displayName: 'Prateek', status: 'ACTIVE', user },
      { id: 'part-2', userId: 'user-2', displayName: 'Other', status: 'ACTIVE', user: { ...user, id: 'user-2', name: 'Other' } },
    ],
    expenses: [
      {
        id: 'exp-1',
        description: 'LiveTest-E2B',
        paidById: 'user-2', // USER id, as written by the mutation kernel
        currency: 'INR',
        amountMinorUnits: 4200n,
        currencyExponent: 2,
        splitType: 'EQUAL',
        date: new Date('2026-07-30T15:30:48.975Z'),
        createdAt: new Date('2026-07-30T15:30:48.975Z'),
        updatedAt: new Date('2026-07-30T15:30:48.975Z'),
        isDeleted: false,
        splits: [
          { id: 's-1', userId: 'user-2', amountMinorUnits: 2100n, currencyExponent: 2, percentage: null, shares: null },
          { id: 's-2', userId: 'user-1', amountMinorUnits: 2100n, currencyExponent: 2, percentage: null, shares: null },
        ],
      },
    ],
    transactions: [],
  }
}

function fakeDb(groups: unknown[]) {
  return {
    groupMember: { findUnique: async () => ({ userId: 'user-1' }) },
    group: { findMany: async () => groups },
    ledgerOperation: { findMany: async () => [] },
    ledgerImport: { findFirst: async () => null },
    moneyMigrationIssue: { findMany: async () => [] },
    friendship: { findMany: async () => [] },
  }
}

test('loader translates expense payer and split user ids into participant member ids', async () => {
  const result = await loadGroupReadModel('grp-exp-001', 'user-1', {}, fakeDb([groupWithExpense()]) as never)
  const model = result.group
  assert.equal(model.expenses.length, 1)
  const expense = model.expenses[0]
  assert.equal(expense.paidByMemberId, 'part-2') // translated from user-2
  assert.deepEqual(
    expense.splits.map((split) => split.memberId).sort(),
    ['part-1', 'part-2']
  )
  // Balances keyed by member ids and consistent: payer +4200, splits -2100 each
  const byMember = model.balances.byMember.find((entry) => entry.memberId === 'part-2')!
  assert.equal(byMember.byCurrency[0].minorUnits, '2100')
})

test('loader fails loudly when an expense references a user with no participant row', async () => {
  const group = groupWithExpense()
  group.expenses[0].paidById = 'user-ghost'
  await assert.rejects(
    loadGroupReadModel('grp-exp-001', 'user-1', {}, fakeDb([group]) as never),
    (error: unknown) => {
      assert.match((error as Error).message, /missing a participant identity/)
      return true
    }
  )
})

// ─── Containment ─────────────────────────────────────────────────────────────
function cleanSource(groupId: string): ReadModelGroupSource {
  return {
    groupId,
    accountId: 'user-1',
    name: 'Clean',
    baseCurrency: { currencyCode: 'INR', currencyExponent: 2 },
    revision: 0,
    simplifyDebts: true,
    localOnly: false,
    members: [
      { memberId: 'part-1', accountId: 'user-1', localIdentityId: null, displayName: 'Prateek', email: null, role: 'owner', status: 'active' },
    ],
    expenses: [],
    settlements: [],
    pendingOperationIds: [],
    migration,
    migrationIssueIds: [],
    updatedAt: '2026-08-05T22:00:00.000Z',
  }
}

function badSource(groupId: string): ReadModelGroupSource {
  const source = cleanSource(groupId)
  source.name = 'Bad'
  source.expenses = [
    {
      expenseId: 'exp-bad',
      description: 'Broken',
      paidByMemberId: 'member-ghost', // unknown member id
      amount: { currencyCode: 'INR', currencyExponent: 2, minorUnits: '100' },
      splitMethod: 'EQUAL',
      splits: [
        { splitId: 's-bad', memberId: 'part-1', amount: { currencyCode: 'INR', currencyExponent: 2, minorUnits: '100' }, percentage: null, shares: null },
      ],
      status: 'active',
      createdAt: '2026-08-05T22:00:00.000Z',
      updatedAt: '2026-08-05T22:00:00.000Z',
    },
  ]
  return source
}

test('account summary skips an unreadable group instead of failing the whole account', () => {
  const result = buildAccountLedgerSummary(
    { accountId: 'user-1', groups: [cleanSource('grp-clean'), badSource('grp-bad')], friends: [], pendingOperations: [], migration },
    { observedAt: '2026-08-05T22:00:00.000Z' }
  )
  assert.equal(result.summary.groups.length, 1)
  assert.equal(result.summary.groups[0].groupId, 'grp-clean')
  assert.equal(result.groups.length, 1)
})

test('group envelope keeps a clean requested group when a sibling group is unreadable', () => {
  const result = buildGroupLedgerReadEnvelope(
    cleanSource('grp-clean'),
    [cleanSource('grp-clean'), badSource('grp-bad')],
    [],
    { observedAt: '2026-08-05T22:00:00.000Z' }
  )
  assert.equal(result.envelope.data.group.groupId, 'grp-clean')
})

test('group envelope still fails when the requested group itself is unreadable', () => {
  assert.throws(() =>
    buildGroupLedgerReadEnvelope(
      badSource('grp-bad'),
      [cleanSource('grp-clean'), badSource('grp-bad')],
      [],
      { observedAt: '2026-08-05T22:00:00.000Z' }
    )
  )
})
