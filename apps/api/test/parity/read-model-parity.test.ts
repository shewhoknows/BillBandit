import assert from 'node:assert/strict'
import test from 'node:test'
import type { PrismaClient } from '@prisma/client'
import { createLedgerTestDatabase } from '../integration/ledger-harness'
import { seedLedgerFixture } from '../integration/ledger-fixtures'

let database: Awaited<ReturnType<typeof createLedgerTestDatabase>> | undefined
let db!: PrismaClient
let executeMutation!: (typeof import('../../lib/ledger/mutation'))['executeMutation']
let executeSettlement!: (typeof import('../../lib/settlement/commands/settle'))['executeSettlement']
let loadAccountReadModel!: (typeof import('../../lib/ledger/read-model/loader'))['loadAccountReadModel']
let loadGroupReadModel!: (typeof import('../../lib/ledger/read-model/loader'))['loadGroupReadModel']
let buildGroupDetailResponseFromLedger!: (typeof import('../../lib/mobile-groups'))['buildGroupDetailResponseFromLedger']
let getSettleUpState!: (typeof import('../../lib/settlement/read/sync'))['getSettleUpState']
let prisma!: PrismaClient

test.before(async () => {
  database = await createLedgerTestDatabase()
  db = database.db
  const mutation = await import('../../lib/ledger/mutation')
  const settlement = await import('../../lib/settlement/commands/settle')
  const reads = await import('../../lib/ledger/read-model/loader')
  const mobile = await import('../../lib/mobile-groups')
  const compatibility = await import('../../lib/settlement/read/sync')
  const databaseModule = await import('../../lib/prisma')
  executeMutation = mutation.executeMutation
  executeSettlement = settlement.executeSettlement
  loadAccountReadModel = reads.loadAccountReadModel
  loadGroupReadModel = reads.loadGroupReadModel
  buildGroupDetailResponseFromLedger = mobile.buildGroupDetailResponseFromLedger
  getSettleUpState = compatibility.getSettleUpState
  prisma = databaseModule.prisma
})

test.after(async () => {
  await prisma?.$disconnect()
  await database?.close()
})

test('account, group, mobile detail, and settle-up compatibility surfaces share one golden ledger', async () => {
  const fixture = await seedLedgerFixture(db, 'parity', { expenseMinorUnits: null })
  const expenseId = `${fixture.groupId}-expense`
  await executeMutation({
    groupId: fixture.groupId,
    operationId: 'parity-expense',
    expectedRevision: 0,
    accountId: fixture.aliceId,
    actorUserId: fixture.aliceId,
    kind: 'expense.create',
    payload: {
      expenseId,
      description: 'Parity dinner',
      amount: { minorUnits: '1000', currencyCode: 'USD', currencyExponent: 2 },
      paidById: fixture.aliceId,
      splitType: 'EXACT',
      splits: [
        { userId: fixture.aliceId, amount: { minorUnits: '0', currencyCode: 'USD', currencyExponent: 2 } },
        { userId: fixture.bobId, amount: { minorUnits: '1000', currencyCode: 'USD', currencyExponent: 2 } },
      ],
    },
  }, { db })

  const before = await loadGroupReadModel(fixture.groupId, fixture.bobId, {
    observedAt: '2026-08-04T00:00:00.000Z',
  }, db)
  const compatibilityBefore = await getSettleUpState(fixture.groupId, fixture.bobId)
  const transfer = before.group.settlementPlan.transfers[0]
  assert.ok(transfer)
  assert.equal(compatibilityBefore.mode, 'snapshot')
  assert.deepEqual(
    compatibilityBefore.plan.map((entry) => [
      entry.payerParticipantId,
      entry.recipientParticipantId,
      entry.amount,
      entry.currencyCode,
      entry.currencyExponent,
      entry.mode,
    ]),
    [[
      transfer.payerMemberId,
      transfer.recipientMemberId,
      '10.00',
      transfer.amount.currencyCode,
      transfer.amount.currencyExponent,
      transfer.mode,
    ]]
  )

  await executeSettlement({
    groupId: fixture.groupId,
    userId: fixture.bobId,
    idempotencyKey: 'parity-settlement',
    expectedVersion: before.group.revision,
    planTransferId: transfer.planTransferId,
    payerParticipantId: transfer.payerMemberId,
    recipientParticipantId: transfer.recipientMemberId,
    currencyCode: transfer.amount.currencyCode,
    currencyExponent: transfer.amount.currencyExponent,
    minorUnits: transfer.amount.minorUnits,
    db,
  })

  const account = await loadAccountReadModel(fixture.bobId, {
    observedAt: '2026-08-04T00:00:00.000Z',
  }, db)
  const group = await loadGroupReadModel(fixture.groupId, fixture.bobId, {
    observedAt: '2026-08-04T00:00:00.000Z',
  }, db)
  const mobileDetail = buildGroupDetailResponseFromLedger(group.group)
  const compatibilityAfter = await getSettleUpState(fixture.groupId, fixture.bobId)

  assert.deepEqual(account.summary.groups[0]?.balanceByCurrency, group.group.balances.currentAccount.byCurrency)
  assert.deepEqual(account.summary.balanceByCurrency, group.group.balances.currentAccount.byCurrency)
  assert.deepEqual(group.envelope.data.account.balance.byCurrency, group.group.balances.currentAccount.byCurrency)
  assert.deepEqual(group.envelope.data.group, group.group)
  assert.deepEqual(mobileDetail.ledger, group.group)
  assert.deepEqual(
    mobileDetail.balances.netBalances.map((entry) => [entry.memberId, entry.money]),
    group.group.balances.byMember.map((entry) => [entry.memberId, entry.byCurrency[0]])
  )
  assert.deepEqual(account.summary.authority, group.group.authority)
  assert.equal(account.summary.readRevision, group.group.readRevision)
  assert.equal(compatibilityAfter.version, group.group.revision)
  assert.deepEqual(compatibilityAfter.plan, [])
  assert.equal(compatibilityAfter.settled.items.length, 1)
  assert.equal(compatibilityAfter.settled.items[0]?.type, 'settlement')
  assert.equal(compatibilityAfter.settled.items[0]?.amount, '10.00')
  assert.equal(compatibilityAfter.settled.items[0]?.currencyCode, 'USD')
})
