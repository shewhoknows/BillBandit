import assert from 'node:assert/strict'
import test from 'node:test'
import type { PrismaClient } from '@prisma/client'
import { createLedgerTestDatabase } from './ledger-harness'
import { seedLedgerFixture, type LedgerFixture } from './ledger-fixtures'

let database: Awaited<ReturnType<typeof createLedgerTestDatabase>> | undefined
let db!: PrismaClient
let executeMutation!: (typeof import('../../lib/ledger/mutation'))['executeMutation']
let MutationConflictError!: (typeof import('../../lib/ledger/mutation'))['MutationConflictError']
let executeSettlement!: (typeof import('../../lib/settlement/commands/settle'))['executeSettlement']
let loadGroupReadModel!: (typeof import('../../lib/ledger/read-model/loader'))['loadGroupReadModel']

test.before(async () => {
  database = await createLedgerTestDatabase()
  db = database.db
  const mutation = await import('../../lib/ledger/mutation')
  const settlement = await import('../../lib/settlement/commands/settle')
  const reads = await import('../../lib/ledger/read-model/loader')
  executeMutation = mutation.executeMutation
  MutationConflictError = mutation.MutationConflictError
  executeSettlement = settlement.executeSettlement
  loadGroupReadModel = reads.loadGroupReadModel
})

test.after(async () => database?.close())

function expenseRequest(
  fixture: LedgerFixture,
  operationId: string,
  expectedRevision: number,
  input: { expenseId: string; description?: string; amount?: string } = { expenseId: `${fixture.groupId}-expense` }
) {
  const amount = input.amount ?? '125'
  return {
    groupId: fixture.groupId,
    operationId,
    expectedRevision,
    accountId: fixture.aliceId,
    actorUserId: fixture.aliceId,
    kind: 'expense.create' as const,
    payload: {
      expenseId: input.expenseId,
      description: input.description ?? 'Lunch',
      amount: { minorUnits: amount, currencyCode: 'USD', currencyExponent: 2 },
      paidById: fixture.aliceId,
      splitType: 'EXACT' as const,
      splits: [{ userId: fixture.aliceId, amount: { minorUnits: amount, currencyCode: 'USD', currencyExponent: 2 } }],
    },
  }
}

test('duplicate expense requests replay one financial record and one journal', async () => {
  const fixture = await seedLedgerFixture(db, 'duplicate', { expenseMinorUnits: null })
  const request = expenseRequest(fixture, 'expense-duplicate', 0, { expenseId: `${fixture.groupId}-expense` })

  const first = await executeMutation(request, { db })
  const replay = await executeMutation(request, { db })

  assert.equal(first.outcome, 'applied')
  assert.equal(first.revision, 1)
  assert.equal(replay.outcome, 'replayed')
  assert.equal(replay.recordId, first.recordId)
  assert.equal(replay.revision, first.revision)
  assert.equal(await db.expense.count({ where: { id: first.recordId } }), 1)
  assert.equal(await db.expenseSplit.count({ where: { expenseId: first.recordId } }), 1)
  assert.equal(await db.ledgerOperation.count({ where: { accountId: fixture.aliceId } }), 1)
  assert.equal(await db.settlementVersionJournal.count({ where: { groupId: fixture.groupId } }), 1)
  assert.equal(await db.settlementOutbox.count({ where: { groupId: fixture.groupId } }), 1)
})

test('stale revisions are rejected without creating a second financial record', async () => {
  const fixture = await seedLedgerFixture(db, 'stale', { expenseMinorUnits: null })
  const first = await executeMutation(
    expenseRequest(fixture, 'expense-stale-first', 0, { expenseId: `${fixture.groupId}-first` }),
    { db }
  )

  await assert.rejects(
    () => executeMutation(
      expenseRequest(fixture, 'expense-stale-second', 0, { expenseId: `${fixture.groupId}-second` }),
      { db }
    ),
    (error: unknown) => error instanceof MutationConflictError && error.code === 'REVISION_CONFLICT'
  )

  assert.equal(await db.expense.count({ where: { groupId: fixture.groupId, isDeleted: false } }), 1)
  assert.equal(await db.expense.count({ where: { id: first.recordId } }), 1)
  assert.equal((await db.group.findUniqueOrThrow({ where: { id: fixture.groupId } })).settlementVersion, 1)
  assert.equal(await db.settlementVersionJournal.count({ where: { groupId: fixture.groupId } }), 1)
})

test('a conflicting edit loses to the committed revision and leaves the winner authoritative', async () => {
  const fixture = await seedLedgerFixture(db, 'edit', { expenseMinorUnits: null })
  const expenseId = `${fixture.groupId}-expense`
  await executeMutation(expenseRequest(fixture, 'expense-edit-create', 0, { expenseId }), { db })

  const edit = {
    ...expenseRequest(fixture, 'expense-edit-winner', 1, { expenseId, description: 'Updated lunch', amount: '200' }),
    kind: 'expense.edit' as const,
  }
  const winner = await executeMutation(edit, { db })
  const conflictingEdit = {
    ...expenseRequest(fixture, 'expense-edit-loser', 1, { expenseId, description: 'Lost lunch', amount: '300' }),
    kind: 'expense.edit' as const,
  }

  await assert.rejects(
    () => executeMutation(conflictingEdit, { db }),
    (error: unknown) => error instanceof MutationConflictError && error.code === 'REVISION_CONFLICT'
  )

  const stored = await db.expense.findUniqueOrThrow({ where: { id: expenseId } })
  assert.equal(winner.recordId, expenseId)
  assert.equal(stored.description, 'Updated lunch')
  assert.equal(stored.amountMinorUnits, 200n)
  assert.equal(await db.expense.count({ where: { groupId: fixture.groupId } }), 1)
  assert.equal(await db.settlementVersionJournal.count({ where: { groupId: fixture.groupId } }), 2)
})

test('delete replay is idempotent and never resurrects or duplicates the expense', async () => {
  const fixture = await seedLedgerFixture(db, 'delete', { expenseMinorUnits: null })
  const expenseId = `${fixture.groupId}-expense`
  await executeMutation(expenseRequest(fixture, 'expense-delete-create', 0, { expenseId }), { db })
  const request = {
    groupId: fixture.groupId,
    operationId: 'expense-delete-replay',
    expectedRevision: 1,
    accountId: fixture.aliceId,
    actorUserId: fixture.aliceId,
    kind: 'expense.delete' as const,
    payload: { expenseId },
  }

  const first = await executeMutation(request, { db })
  const replay = await executeMutation(request, { db })
  const stored = await db.expense.findUniqueOrThrow({ where: { id: expenseId } })

  assert.equal(first.revision, 2)
  assert.equal(replay.outcome, 'replayed')
  assert.equal(replay.recordId, first.recordId)
  assert.equal(stored.isDeleted, true)
  assert.equal(await db.expense.count({ where: { id: expenseId } }), 1)
  assert.equal(await db.settlementVersionJournal.count({ where: { groupId: fixture.groupId } }), 2)
})

test('settlement replay keeps exactly one transaction, allocation, and version', async () => {
  const fixture = await seedLedgerFixture(db, 'settlement-replay', { expenseMinorUnits: 1000n })
  const read = await loadGroupReadModel(fixture.groupId, fixture.bobId, {}, db)
  const transfer = read.group.settlementPlan.transfers[0]
  assert.ok(transfer)

  const input = {
    groupId: fixture.groupId,
    userId: fixture.bobId,
    idempotencyKey: 'settlement-replay',
    expectedVersion: read.group.revision,
    planTransferId: transfer.planTransferId,
    payerParticipantId: transfer.payerMemberId,
    recipientParticipantId: transfer.recipientMemberId,
    currencyCode: transfer.amount.currencyCode,
    currencyExponent: transfer.amount.currencyExponent,
    minorUnits: transfer.amount.minorUnits,
    db,
  } as const

  const first = await executeSettlement(input)
  const replay = await executeSettlement(input)

  assert.equal(first.version, 1)
  assert.equal(replay.version, first.version)
  assert.equal(replay.recordId, first.recordId)
  assert.equal(await db.transaction.count({ where: { groupId: fixture.groupId } }), 1)
  assert.equal(await db.settlementAllocation.count({ where: { groupId: fixture.groupId } }), 1)
  assert.equal(await db.ledgerOperation.count({ where: { accountId: fixture.bobId } }), 1)
  assert.equal(await db.settlementVersionJournal.count({ where: { groupId: fixture.groupId } }), 1)
  assert.equal(await db.settlementOutbox.count({ where: { groupId: fixture.groupId } }), 1)
})

test('two concurrent writes at one revision produce exactly one winner', async () => {
  const fixture = await seedLedgerFixture(db, 'concurrency', { expenseMinorUnits: null })
  const requests = [
    expenseRequest(fixture, 'concurrent-a', 0, { expenseId: `${fixture.groupId}-a` }),
    expenseRequest(fixture, 'concurrent-b', 0, { expenseId: `${fixture.groupId}-b` }),
  ]

  const results = await Promise.allSettled(requests.map((request) => executeMutation(request, { db })))
  const winners = results.filter((result): result is PromiseFulfilledResult<Awaited<ReturnType<typeof executeMutation>>> => result.status === 'fulfilled')
  const losers = results.filter((result): result is PromiseRejectedResult => result.status === 'rejected')

  assert.equal(winners.length, 1)
  assert.equal(losers.length, 1)
  assert.ok(losers[0].reason instanceof MutationConflictError)
  assert.equal(losers[0].reason.code, 'REVISION_CONFLICT')
  assert.equal(await db.expense.count({ where: { groupId: fixture.groupId } }), 1)
  assert.equal(await db.expenseSplit.count({ where: { expense: { groupId: fixture.groupId } } }), 1)
  assert.equal(await db.settlementVersionJournal.count({ where: { groupId: fixture.groupId } }), 1)
  assert.equal((await db.group.findUniqueOrThrow({ where: { id: fixture.groupId } })).settlementVersion, 1)
})
