/**
 * Settlement slice E2E: payments, reversals, completion date and the outbox.
 *
 *   cd apps/api
 *   DEV_DATABASE_URL=postgresql://postgres@localhost:5432/billbandit_a2 \
 *   DEV_API_BASE=http://127.0.0.1:3102 npx tsx scripts/settlement-e2e.ts
 *
 * Needs a running dev server (scripts/dev-server.ts) with the same env and the
 * dev-data scenario users (dev_you, dev_kabir). Steps 1-10 use the real HTTP
 * API only. Step 11 runs the outbox dispatcher in this process against the
 * same real database, with a fake Pusher adapter (the dev server has no
 * Pusher keys, so its own dispatcher never runs and cannot interfere).
 */
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { PrismaClient } from '@prisma/client'
import { assertLocalOnly, devApiBase, devDatabaseUrl, devJwtSecret } from './support/dev-env'

assertLocalOnly()
process.env.MOBILE_JWT_SECRET = devJwtSecret
process.env.NEXTAUTH_SECRET = devJwtSecret
process.env.DATABASE_URL = devDatabaseUrl
const db = new PrismaClient({ datasources: { db: { url: devDatabaseUrl } } })
type Json = Record<string, any>
const results: { name: string; result: string }[] = []
const money = (n: number) => ({ minorUnits: String(n), currencyCode: 'INR', currencyExponent: 2 })
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

async function request(token: string, path: string, method = 'GET', body?: unknown, headers: Record<string, string> = {}) {
  const response = await fetch(new URL(path, devApiBase), {
    method,
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...headers },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })
  const text = await response.text()
  let data: Json = {}
  try { data = JSON.parse(text) } catch { data = { text } }
  return { status: response.status, data }
}

async function step(name: string, fn: () => Promise<void>) {
  try {
    await fn()
    results.push({ name, result: 'PASS' })
  } catch (error) {
    results.push({ name, result: `FAIL: ${error instanceof Error ? error.message : String(error)}` })
  }
}

function revision(): string {
  try {
    const head = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()
    const dirty = execFileSync('git', ['status', '--porcelain', '--', '.'], { encoding: 'utf8' }).trim()
    return `${head}${dirty ? ' (+ uncommitted changes)' : ''}`
  } catch {
    return 'unknown'
  }
}

async function main() {
  const { createMobileToken } = await import('../lib/mobile-auth')
  const [owner, member] = await Promise.all(
    ['dev_you', 'dev_kabir'].map((username) => db.user.findUniqueOrThrow({ where: { username } }))
  )
  const ownerToken = createMobileToken(owner)
  const memberToken = createMobileToken(member)
  const tokenFor = (userId: string) => (userId === owner.id ? ownerToken : memberToken)

  const makeGroup = async (label: string) => {
  const created = await request(ownerToken, '/api/mobile/groups', 'POST', {
    name: `${label} ${Date.now()}`, currency: 'INR', category: 'TRIP', memberAccountIds: [member.id],
  }, { 'Idempotency-Key': randomUUID() })
  assert.equal(created.status, 201, JSON.stringify(created.data))
  const groupId = created.data.group.id as string
  const read = async (token = ownerToken) => {
    const response = await request(token, `/api/mobile/ledger/groups/${groupId}`)
    assert.equal(response.status, 200, JSON.stringify(response.data))
    return response.data.data.group as Json
  }
  const accountOf = (group: Json, memberId: string) =>
    group.members.find((m: Json) => m.memberId === memberId).accountId as string
  const addExpense = async (amount: number) => {
    const group = await read()
    const id = randomUUID()
    const half = amount / 2
    const result = await request(ownerToken, '/api/mobile/expenses', 'POST', {
      groupId, operationId: randomUUID(), expectedRevision: group.revision, expenseId: id,
      description: `Expense ${amount}`, amount: money(amount), currency: 'INR', paidById: owner.id,
      splitType: 'EQUAL', splits: [owner, member].map((u, i) => ({ id: `${id}-${i}`, userId: u.id, amount: money(half) })),
    })
    assert.equal(result.status, 201, JSON.stringify(result.data))
  }
  const settleBody = (group: Json, transfer: Json, minorUnits: string) => ({
    expectedVersion: group.revision, planTransferId: transfer.planTransferId,
    payerParticipantId: transfer.payerMemberId, recipientParticipantId: transfer.recipientMemberId,
    currencyCode: 'INR', currencyExponent: 2, minorUnits,
  })
  const settle = (token: string, body: Json, key = randomUUID()) =>
    request(token, `/api/groups/${groupId}/settlements`, 'POST', body, { 'Idempotency-Key': key })
  const reverse = (token: string, settlementId: string, expectedVersion: number, key = randomUUID()) =>
    request(token, `/api/groups/${groupId}/settlements/${settlementId}/reversals`, 'POST', { expectedVersion }, { 'Idempotency-Key': key })
  const txCount = () => db.transaction.count({ where: { groupId } })
  const assertMoneyConserved = async () => {
    const g = await read()
    const sum = g.balances.byMember.reduce((t: bigint, b: Json) =>
      t + (b.byCurrency as Json[]).reduce((u: bigint, m: Json) => u + BigInt(m.minorUnits), 0n), 0n)
    assert.equal(sum, 0n, `balances do not sum to zero: ${JSON.stringify(g.balances.byMember)}`)
  }

  return { groupId, read, accountOf, addExpense, settleBody, settle, reverse, txCount, assertMoneyConserved }
  }
  const { groupId, read, accountOf, addExpense, settleBody, settle, reverse, txCount, assertMoneyConserved } = await makeGroup('Settlement E2E')

  await addExpense(10000) // member owes owner 5000

  await step('1. Pay more than owed is refused and records nothing', async () => {
    const g = await read(); const t = g.settlementPlan.transfers[0]
    const before = await txCount()
    const r = await settle(tokenFor(accountOf(g, t.payerMemberId)), settleBody(g, t, String(BigInt(t.amount.minorUnits) + 1n)))
    assert.equal(r.status, 409, JSON.stringify(r.data)); assert.equal(r.data.error, 'INVALID_SETTLEMENT_AMOUNT')
    assert.equal(await txCount(), before)
  })

  await step('2. Same payment sent 4 times at once with one Idempotency-Key (offline replay racing the original) is applied once', async () => {
    const g = await read(); const t = g.settlementPlan.transfers[0]
    const token = tokenFor(accountOf(g, t.payerMemberId)); const key = randomUUID(); const body = settleBody(g, t, '2000')
    const before = await txCount()
    const rs = await Promise.all([1, 2, 3, 4].map(() => settle(token, body, key)))
    assert.equal(await txCount(), before + 1, `transactions added: ${(await txCount()) - before}`)
    assert.ok(rs.every((r) => r.status === 201), `statuses ${rs.map((r) => `${r.status} ${r.data.error ?? ''}`).join(', ')}`)
    assert.equal(new Set(rs.map((r) => r.data.result.transactionId)).size, 1)
    const later = await settle(token, body, key) // replay after commit, stale expectedVersion
    assert.equal(later.status, 201, JSON.stringify(later.data)); assert.equal(later.data.result.transactionId, rs[0].data.result.transactionId)
    assert.equal(await txCount(), before + 1)
    await assertMoneyConserved()
  })

  let firstCompletedAt = ''
  await step('3. Paying the rest settles everyone and sets the completion date', async () => {
    const g = await read(); const t = g.settlementPlan.transfers[0]
    assert.equal(t.amount.minorUnits, '3000')
    const r = await settle(tokenFor(accountOf(g, t.payerMemberId)), settleBody(g, t, '3000'))
    assert.equal(r.status, 201, JSON.stringify(r.data))
    assert.equal(r.data.state.plan.length, 0); assert.ok(r.data.state.settlementCompletedAt, 'no completion date')
    firstCompletedAt = r.data.state.settlementCompletedAt
  })

  let lastSettlementId = ''
  await step('4. New expense, then settled again: completion date is the new payment, not the old one', async () => {
    await sleep(1200)
    await addExpense(4000) // member owes owner 2000
    const g = await read(); const t = g.settlementPlan.transfers[0]
    const r = await settle(tokenFor(accountOf(g, t.payerMemberId)), settleBody(g, t, t.amount.minorUnits))
    assert.equal(r.status, 201, JSON.stringify(r.data))
    lastSettlementId = r.data.result.transactionId
    const payment = await db.transaction.findUniqueOrThrow({ where: { id: lastSettlementId } })
    const shown = r.data.state.settlementCompletedAt
    assert.ok(shown, 'no completion date')
    assert.ok(new Date(shown) >= payment.createdAt,
      `shows ${shown} (first settle-up was ${firstCompletedAt}); the payment that settled everyone is ${payment.createdAt.toISOString()}`)
  })

  await step('5. Two phones reverse the same payment at once: one reversal, one 409, debt returns once', async () => {
    const g = await read()
    const rs = await Promise.all([reverse(ownerToken, lastSettlementId, g.revision), reverse(memberToken, lastSettlementId, g.revision)])
    assert.deepEqual(rs.map((r) => r.status).sort(), [201, 409], rs.map((r) => `${r.status} ${r.data.error ?? ''}`).join(', '))
    assert.equal(await db.settlementReversal.count({ where: { transactionId: lastSettlementId } }), 1)
    const after = await read()
    assert.equal(after.settlementPlan.transfers.length, 1); assert.equal(after.settlementPlan.transfers[0].amount.minorUnits, '2000')
    const loser = rs.find((r) => r.status === 409)!
    // READ COMMITTED: the loser fails either the revision check / CAS
    // (SETTLEMENT_VERSION_CONFLICT) or, if the winner committed between its
    // group read and its prepare read, the guard (ALREADY_REVERSED). Both 409.
    assert.ok(['SETTLEMENT_VERSION_CONFLICT', 'ALREADY_REVERSED'].includes(loser.data.error), loser.data.error)
    const state = rs.find((r) => r.status === 201)!.data.state
    assert.equal(state.settlementCompletedAt, null, 'completion date kept after the debt came back')
    await assertMoneyConserved()
  })

  await step('6. Retrying the loser with a fresh version is refused: ALREADY_REVERSED', async () => {
    const g = await read()
    const r = await reverse(memberToken, lastSettlementId, g.revision)
    assert.equal(r.status, 409, JSON.stringify(r.data)); assert.equal(r.data.error, 'ALREADY_REVERSED')
    assert.equal(await db.settlementReversal.count({ where: { transactionId: lastSettlementId } }), 1)
  })

  await step('7. A reversal cannot be reversed', async () => {
    const reversal = await db.settlementReversal.findFirstOrThrow({ where: { transactionId: lastSettlementId } })
    const g = await read()
    const r = await reverse(ownerToken, reversal.id, g.revision)
    assert.equal(r.status, 404, JSON.stringify(r.data)); assert.equal(r.data.error, 'SETTLEMENT_NOT_FOUND')
  })

  await step('8. Stale plan (version moved) is refused with requiresReconfirmation', async () => {
    const g = await read(); const t = g.settlementPlan.transfers[0]
    await addExpense(200)
    const before = await txCount()
    const r = await settle(tokenFor(accountOf(g, t.payerMemberId)), settleBody(g, t, '100'))
    assert.equal(r.status, 409, JSON.stringify(r.data)); assert.equal(r.data.requiresReconfirmation, true)
    assert.equal(await txCount(), before)
  })

  await step('9. Two phones pay the same transfer at once: one payment, no overpay', async () => {
    const g = await read(); const t = g.settlementPlan.transfers[0]
    const token = tokenFor(accountOf(g, t.payerMemberId)); const before = await txCount()
    const rs = await Promise.all([settle(token, settleBody(g, t, t.amount.minorUnits)), settle(token, settleBody(g, t, t.amount.minorUnits))])
    assert.deepEqual(rs.map((r) => r.status).sort(), [201, 409], rs.map((r) => `${r.status} ${r.data.error ?? ''}`).join(', '))
    assert.equal(await txCount(), before + 1)
    assert.equal((await read()).settlementPlan.transfers.length, 0)
    await assertMoneyConserved()
  })

  await step('10. Finalized group still accepts a reversal and a payment (api-contracts.md)', async () => {
    let g = await read()
    const fin = await request(ownerToken, `/api/mobile/groups/${groupId}/finalize`, 'POST', { operationId: randomUUID(), expectedRevision: g.revision })
    assert.equal(fin.status, 200, JSON.stringify(fin.data))
    const last = await db.transaction.findFirstOrThrow({ where: { groupId, reversal: null }, orderBy: { createdAt: 'desc' } })
    g = await read()
    const rv = await reverse(ownerToken, last.id, g.revision)
    assert.equal(rv.status, 201, JSON.stringify(rv.data))
    g = await read(); const t = g.settlementPlan.transfers[0]
    const pay = await settle(tokenFor(accountOf(g, t.payerMemberId)), settleBody(g, t, t.amount.minorUnits))
    assert.equal(pay.status, 201, JSON.stringify(pay.data))
    await assertMoneyConserved()
  })

  await step('11. Outbox: a slow worker whose lease expired cannot undo a newer worker\'s PUBLISHED row', async () => {
    process.env.PUSHER_APP_ID ||= 'e2e'; process.env.PUSHER_KEY ||= 'e2e'
    process.env.PUSHER_SECRET ||= 'e2e'; process.env.PUSHER_CLUSTER ||= 'e2e'
    const pusher = await import('../lib/settlement/outbox/pusher')
    const { drainOutboxOnce } = await import('../lib/settlement/outbox/dispatcher')
    let target = ''
    let release: () => void = () => {}
    const gate = new Promise<void>((r) => { release = r })
    let slowStarted = false
    const publishes: string[] = []
    pusher.setPusherAdapter({
      async publish(_channel, payload) {
        if (payload.recordId === target && !slowStarted) {
          slowStarted = true
          publishes.push(`slow:${payload.version}`)
          await gate
          throw new Error('Pusher timeout')
        }
        if (payload.recordId === target) publishes.push(`fast:${payload.version}`)
      },
    })
    // Clear older rows so this step only sees its own row.
    for (let i = 0; i < 400 && (await db.settlementOutbox.count({ where: { state: 'PENDING', nextAttemptAt: { lte: new Date() } } })) > 0; i++) {
      await drainOutboxOnce('e2e-clear')
    }
    const o = await makeGroup('Outbox E2E')
    await o.addExpense(600)
    const g2 = await o.read(); const t2 = g2.settlementPlan.transfers[0]
    const pay = await o.settle(tokenFor(o.accountOf(g2, t2.payerMemberId)), o.settleBody(g2, t2, '100'))
    assert.equal(pay.status, 201, JSON.stringify(pay.data))
    target = pay.data.result.transactionId
    const row = await db.settlementOutbox.findFirstOrThrow({ where: { groupId: o.groupId, recordId: target } })
    const workerA = drainOutboxOnce('worker-A')
    for (let i = 0; i < 200 && !slowStarted; i++) await sleep(10)
    assert.ok(slowStarted, 'worker A never started publishing')
    await db.settlementOutbox.update({ where: { id: row.id }, data: { leaseExpiresAt: new Date(Date.now() - 1000) } })
    await drainOutboxOnce('worker-B')
    const afterB = await db.settlementOutbox.findUniqueOrThrow({ where: { id: row.id } })
    assert.equal(afterB.state, 'PUBLISHED', `after worker B: ${afterB.state}`)
    release()
    await workerA
    const afterA = await db.settlementOutbox.findUniqueOrThrow({ where: { id: row.id } })
    await db.settlementOutbox.update({ where: { id: row.id }, data: { nextAttemptAt: new Date(0) } }).catch(() => {})
    await drainOutboxOnce('worker-C')
    const final = await db.settlementOutbox.findUniqueOrThrow({ where: { id: row.id } })
    assert.equal(afterA.state, 'PUBLISHED',
      `worker A moved PUBLISHED back to ${afterA.state} (failureCode ${afterA.failureCode}); publishes: ${publishes.join(', ')}`)
    assert.equal(final.state, 'PUBLISHED'); assert.ok(final.publishedAt)
    assert.equal(publishes.filter((p) => p.startsWith('fast')).length, 1, `publishes: ${publishes.join(', ')}`)
  })

  console.log('# Settlement E2E')
  console.log(`Revision: ${revision()}`)
  console.log(`Environment: API ${devApiBase}, DB ${devDatabaseUrl.replace(/\/\/[^@]*@/, '//')}, node ${process.version}, ${new Date().toISOString()}`)
  console.log('Replay: cd apps/api && DEV_DATABASE_URL=... DEV_API_BASE=... npx tsx scripts/settlement-e2e.ts')
  console.log(`Group: ${groupId}\n| Step | Result |\n| --- | --- |`)
  for (const row of results) console.log(`| ${row.name} | ${row.result.replaceAll('|', '/').replaceAll('\n', ' ')} |`)
  const failed = results.filter((row) => row.result !== 'PASS').length
  console.log(`\n${results.length - failed} PASS, ${failed} FAIL`)
  if (failed) process.exitCode = 1
}

main().catch((error) => { console.error(error); process.exitCode = 1 }).finally(() => db.$disconnect())
