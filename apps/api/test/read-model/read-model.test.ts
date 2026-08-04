import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import {
  parseLedgerReadEnvelope,
  parseSharedLedgerFixture,
  stableStringify,
  type GroupLedgerReadModel,
  type LedgerExpense,
  type MigrationState,
  type PendingOperation,
} from '../../lib/ledger-contract'
import {
  buildAccountLedgerSummary,
  buildGroupLedgerProjection,
  buildGroupLedgerReadEnvelope,
  type ReadModelGroupSource,
} from '../../lib/ledger/read-model'

const here = dirname(fileURLToPath(import.meta.url))

function loadFixture(): ReturnType<typeof parseSharedLedgerFixture> {
  return parseSharedLedgerFixture(
    JSON.parse(readFileSync(join(here, '../fixtures/ledger-v2/shared-ledger.json'), 'utf8')) as unknown
  )
}

function fixtureSource(): ReadModelGroupSource {
  const fixture = loadFixture()
  const group = fixture.read.data.group
  const reversals = new Map(
    group.settlementHistory
      .filter((entry) => entry.type === 'reversal')
      .map((entry) => [entry.settlementId, entry])
  )
  const settlements = group.settlementHistory
    .filter((entry): entry is Extract<typeof entry, { type: 'settlement' }> => entry.type === 'settlement')
    .map((entry) => {
      const reversal = reversals.get(entry.settlementId)
      return {
        settlementId: entry.settlementId,
        payerMemberId: entry.payerMemberId,
        recipientMemberId: entry.recipientMemberId,
        amount: entry.amount,
        actorMemberId: entry.actorMemberId,
        createdAt: entry.createdAt,
        reversed: entry.status === 'reversed',
        reversal: reversal
          ? {
              reversalId: reversal.reversalId,
              actorMemberId: reversal.actorMemberId,
              createdAt: reversal.createdAt,
            }
          : null,
        allocationPaths: [],
      }
    })
  return {
    groupId: group.groupId,
    accountId: group.accountId,
    name: group.name,
    baseCurrency: group.baseCurrency,
    revision: group.revision,
    simplifyDebts: group.settlementPlan.mode === 'SIMPLIFIED',
    localOnly: false,
    members: group.members,
    expenses: group.expenses,
    settlements,
    pendingOperationIds: group.pendingOperationIds,
    migration: group.migration,
    updatedAt: '2026-08-03T10:00:00.000Z',
  }
}

function amounts(model: GroupLedgerReadModel) {
  return model.balances.byMember.map((entry) => ({
    memberId: entry.memberId,
    amounts: entry.byCurrency.map((money) => `${money.currencyCode}:${money.minorUnits}`),
  }))
}

test('one exact projection supplies every group surface from the complete fixture ledger', () => {
  const fixture = loadFixture()
  const source = fixtureSource()
  const projection = buildGroupLedgerProjection(source, { observedAt: '2026-08-03T10:00:00.000Z' })
  const model = projection.model

  assert.equal(projection.readOnly, false)
  assert.equal(model.expenses.length, 6)
  assert.deepEqual(amounts(model), [
    { memberId: 'mem-alex-001', amounts: ['INR:-4500', 'JPY:-500', 'KWD:822'] },
    { memberId: 'mem-bea-001', amounts: ['INR:5000', 'JPY:0', 'KWD:0'] },
    { memberId: 'mem-cleo-001', amounts: ['INR:-500', 'JPY:500', 'KWD:-822'] },
  ])
  assert.deepEqual(
    model.balances.currentAccount.byCurrency,
    fixture.read.data.account.balance.byCurrency
  )
  assert.deepEqual(
    model.settlementPlan.transfers.map((transfer) => [
      transfer.payerMemberId,
      transfer.recipientMemberId,
      transfer.amount.currencyCode,
      transfer.amount.minorUnits,
    ]),
    [
      ['mem-alex-001', 'mem-bea-001', 'INR', '4500'],
      ['mem-cleo-001', 'mem-bea-001', 'INR', '500'],
      ['mem-alex-001', 'mem-cleo-001', 'JPY', '500'],
      ['mem-cleo-001', 'mem-alex-001', 'KWD', '822'],
    ]
  )
  assert.equal(model.settlementHistory.length, 3)
  assert.equal(model.activity.length, 8)
  assert.equal(model.authority.serverAuthoritative, true)
  assert.equal(model.migration.dualWriteEnabled, false)
})

test('group envelope keeps account, group, balances, revision, and pending references aligned', () => {
  const fixture = loadFixture()
  const source = fixtureSource()
  const pendingOperations: PendingOperation[] = fixture.read.data.account.pendingOperations
  const result = buildGroupLedgerReadEnvelope(source, [source], pendingOperations, {
    observedAt: '2026-08-03T10:00:00.000Z',
  })

  assert.equal(result.envelope.readRevision, source.revision)
  assert.equal(result.envelope.revision, source.revision)
  assert.equal(result.envelope.data.account.readRevision, result.envelope.readRevision)
  assert.equal(result.envelope.data.group.readRevision, result.envelope.readRevision)
  assert.deepEqual(
    result.envelope.data.account.balance.byCurrency,
    result.envelope.data.group.balances.currentAccount.byCurrency
  )
  assert.deepEqual(result.envelope.pendingOperationIds, source.pendingOperationIds)
  assert.deepEqual(result.envelope.data.group.pendingOperationIds, source.pendingOperationIds)
  assert.doesNotThrow(() => parseLedgerReadEnvelope(result.envelope))
})

test('account projection excludes local-only input and aggregates group balances without float math', () => {
  const source = fixtureSource()
  const localOnly = { ...source, groupId: 'local-only-001', localOnly: true } as unknown as ReadModelGroupSource
  const result = buildAccountLedgerSummary(
    {
      accountId: source.accountId,
      groups: [source, localOnly],
      pendingOperations: [],
      friends: [],
    },
    { observedAt: '2026-08-03T10:00:00.000Z' }
  )

  assert.deepEqual(result.summary.groups.map((group) => group.groupId), [source.groupId])
  assert.deepEqual(result.summary.balanceByCurrency, source.expenses.length > 0
    ? result.groups[0].model.balances.currentAccount.byCurrency
    : [])
  assert.equal(result.summary.groups[0].localOnly, false)
})

test('unresolved money migration marks an otherwise exact group read-only', () => {
  const source = fixtureSource()
  const blockedMigration: MigrationState = {
    status: 'blocked',
    source: 'cloudkit',
    migrationId: 'money-migration:grp-goa-001',
    importedAt: null,
    dualWriteEnabled: false,
    recoveryReadOnly: true,
  }
  const projection = buildGroupLedgerProjection(
    { ...source, migration: blockedMigration, migrationIssueIds: ['issue-001'] },
    { observedAt: '2026-08-03T10:00:00.000Z' }
  )

  assert.equal(projection.readOnly, true)
  assert.equal(projection.model.migration.status, 'blocked')
  assert.equal(projection.model.migration.recoveryReadOnly, true)
  assert.equal(projection.model.expenses.every((expense: LedgerExpense) => typeof expense.amount.minorUnits === 'string'), true)
})

test('projection serialization is deterministic for a fixed server observation time', () => {
  const source = fixtureSource()
  const first = buildGroupLedgerReadEnvelope(source, [source], [], { observedAt: '2026-08-03T10:00:00.000Z' })
  const second = buildGroupLedgerReadEnvelope(source, [source], [], { observedAt: '2026-08-03T10:00:00.000Z' })
  assert.equal(stableStringify(first.envelope), stableStringify(second.envelope))
})
