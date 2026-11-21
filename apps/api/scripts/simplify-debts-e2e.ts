/**
 * Simplify-debts setting E2E: PATCH /api/groups/{id}/settlement-settings.
 *
 *   cd apps/api
 *   DEV_DATABASE_URL=postgresql://postgres@localhost:5432/billbandit \
 *   DEV_API_BASE=http://127.0.0.1:3000 npx tsx scripts/simplify-debts-e2e.ts
 *
 * Needs a running dev server (scripts/dev-server.ts) with the same env and the
 * dev-data scenario users (dev_you, dev_kabir, dev_aarav). Every step uses the
 * real HTTP API. It only adds data.
 *
 * The group: you pay 200 (you 100, Kabir 100); Kabir pays 200 (Kabir 100,
 * Aarav 100). Balances: you +100, Kabir 0, Aarav -100.
 *   simplified plan: Aarav -> you 100              (1 payment)
 *   direct plan:     Kabir -> you 100, Aarav -> Kabir 100 (2 payments)
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

const brief = (r: { status: number; data: Json }) => `${r.status} ${JSON.stringify(r.data).slice(0, 300)}`

async function main() {
  const { createMobileToken } = await import('../lib/mobile-auth')
  const [you, kabir, aarav] = await Promise.all(
    ['dev_you', 'dev_kabir', 'dev_aarav'].map((username) => db.user.findUniqueOrThrow({ where: { username } }))
  )
  const token = new Map([you, kabir, aarav].map((u) => [u.id, createMobileToken(u)]))
  const T = (u: { id: string }) => token.get(u.id)!

  const created = await request(T(you), '/api/mobile/groups', 'POST', {
    name: `Simplify E2E ${Date.now()}`, currency: 'INR', category: 'TRIP', memberAccountIds: [kabir.id, aarav.id],
  }, { 'Idempotency-Key': randomUUID() })
  assert.equal(created.status, 201, brief(created))
  const groupId = created.data.group.id as string
  const read = async (who = you) => {
    const r = await request(T(who), `/api/mobile/ledger/groups/${groupId}`)
    assert.equal(r.status, 200, brief(r))
    return r.data.data.group as Json
  }
  const addExpense = async (payer: { id: string }, other: { id: string }) => {
    const g = await read()
    const id = randomUUID()
    const r = await request(T(payer), '/api/mobile/expenses', 'POST', {
      groupId, operationId: randomUUID(), expectedRevision: g.revision, expenseId: id,
      description: 'Simplify E2E', amount: money(200), currency: 'INR', paidById: payer.id, splitType: 'EQUAL',
      splits: [payer, other].map((u, i) => ({ id: `${id}-${i}`, userId: u.id, amount: money(100) })),
    })
    assert.equal(r.status, 201, brief(r))
  }
  const setSimplify = (who: { id: string }, expectedVersion: number, simplifyDebts: unknown, key: string = randomUUID()) =>
    request(T(who), `/api/groups/${groupId}/settlement-settings`, 'PATCH', { expectedVersion, simplifyDebts }, { 'Idempotency-Key': key })
  const balances = (g: Json) => JSON.stringify(
    g.balances.byMember.map((b: Json) => [b.memberId, b.byCurrency.map((m: Json) => m.minorUnits)]).sort()
  )
  const sumIsZero = (g: Json) => g.balances.byMember.reduce((t: bigint, b: Json) =>
    t + (b.byCurrency as Json[]).reduce((u: bigint, m: Json) => u + BigInt(m.minorUnits), 0n), 0n) === 0n

  await addExpense(you, kabir)
  await addExpense(kabir, aarav)
  const start = await read()
  const startBalances = balances(start)

  await step('S0 A new group starts with simplify on: 1 payment (Aarav -> you)', async () => {
    assert.equal(start.settlementPlan.mode, 'SIMPLIFIED')
    assert.equal(start.settlementPlan.transfers.length, 1, JSON.stringify(start.settlementPlan.transfers))
  })

  let offKey = ''
  let offResult: Json = {}
  await step('S1 The owner turns simplify off: 200, revision +1, 2 direct payments, balances unchanged', async () => {
    offKey = randomUUID()
    const r = await setSimplify(you, start.revision, false, offKey)
    assert.equal(r.status, 200, brief(r))
    offResult = r.data.result
    assert.equal(r.data.result.version, start.revision + 1)
    const g = await read()
    assert.equal(g.revision, start.revision + 1)
    assert.equal(g.settlementPlan.mode, 'DIRECT')
    assert.equal(g.settlementPlan.transfers.length, 2, JSON.stringify(g.settlementPlan.transfers))
    assert.equal(balances(g), startBalances)
    assert.ok(sumIsZero(g))
    const audit = await db.settlementSettingAudit.findMany({ where: { groupId } })
    assert.equal(audit.length, 1)
    assert.equal(audit[0].simplifyDebts, false)
    assert.equal(audit[0].actorUserId, you.id)
  })

  await step('S2 Every member reads the same new plan', async () => {
    for (const who of [kabir, aarav]) {
      const g = await read(who)
      assert.equal(g.settlementPlan.mode, 'DIRECT', `${who.id} sees ${g.settlementPlan.mode}`)
    }
  })

  await step('S3 The same Idempotency-Key again replays the first answer; nothing new is written', async () => {
    const r = await setSimplify(you, start.revision, false, offKey)
    assert.equal(r.status, 200, brief(r))
    assert.equal(r.data.result.version, offResult.version)
    assert.equal((await read()).revision, start.revision + 1)
    assert.equal(await db.settlementSettingAudit.count({ where: { groupId } }), 1)
  })

  await step('S4 Sending the value the group already has changes nothing (noop, same revision)', async () => {
    const g = await read()
    const r = await setSimplify(you, g.revision, false)
    assert.equal(r.status, 200, brief(r))
    assert.equal(r.data.result.noop, true, brief(r))
    assert.equal((await read()).revision, g.revision)
    assert.equal(await db.settlementSettingAudit.count({ where: { groupId } }), 1)
  })

  await step('S5 A member who is not an owner is refused (403); the setting stays', async () => {
    const g = await read()
    const r = await setSimplify(kabir, g.revision, true)
    assert.equal(r.status, 403, brief(r))
    const after = await read()
    assert.equal(after.settlementPlan.mode, 'DIRECT')
    assert.equal(after.revision, g.revision)
  })

  await step('S6 A stale revision is refused with 409 and the current state', async () => {
    const g = await read()
    const r = await setSimplify(you, g.revision - 1, true)
    assert.equal(r.status, 409, brief(r))
    assert.equal(r.data.error, 'SETTLEMENT_VERSION_CONFLICT', brief(r))
    assert.ok(r.data.state, 'the answer carries the current state')
    assert.equal((await read()).settlementPlan.mode, 'DIRECT')
  })

  await step('S7 Bad bodies are refused with 400 and change nothing', async () => {
    const g = await read()
    for (const value of ['yes', 1, null]) {
      const r = await setSimplify(you, g.revision, value)
      assert.equal(r.status, 400, `${JSON.stringify(value)}: ${brief(r)}`)
    }
    const noKey = await request(T(you), `/api/groups/${groupId}/settlement-settings`, 'PATCH', { expectedVersion: g.revision, simplifyDebts: true })
    assert.equal(noKey.status, 400, brief(noKey))
    assert.equal((await read()).revision, g.revision)
  })

  await step('S8 A payment recorded under the direct plan stays when simplify is turned back on', async () => {
    const g = await read()
    const t = g.settlementPlan.transfers.find((x: Json) =>
      g.members.find((m: Json) => m.memberId === x.payerMemberId).accountId === kabir.id)
    assert.ok(t, 'direct plan has Kabir -> you')
    const paid = await request(T(kabir), `/api/groups/${groupId}/settlements`, 'POST', {
      expectedVersion: g.revision, planTransferId: t.planTransferId,
      payerParticipantId: t.payerMemberId, recipientParticipantId: t.recipientMemberId,
      currencyCode: 'INR', currencyExponent: 2, minorUnits: t.amount.minorUnits,
    }, { 'Idempotency-Key': randomUUID() })
    assert.equal(paid.status, 201, brief(paid))
    const afterPay = await read()
    const on = await setSimplify(you, afterPay.revision, true)
    assert.equal(on.status, 200, brief(on))
    const after = await read()
    assert.equal(after.settlementPlan.mode, 'SIMPLIFIED')
    assert.equal(balances(after), balances(afterPay), 'turning simplify on does not change balances')
    assert.equal(after.settlementHistory.filter((h: Json) => h.type === 'settlement' && h.status === 'active').length, 1)
    assert.ok(sumIsZero(after))
    assert.equal(await db.settlementSettingAudit.count({ where: { groupId } }), 2)
  })

  await step('S9 An old plan payment id from before the switch is refused (409, confirm again)', async () => {
    const g = await read()
    const old = await request(T(aarav), `/api/groups/${groupId}/settlements`, 'POST', {
      expectedVersion: g.revision, planTransferId: `stale-${randomUUID()}`,
      payerParticipantId: g.settlementPlan.transfers[0].payerMemberId,
      recipientParticipantId: g.settlementPlan.transfers[0].recipientMemberId,
      currencyCode: 'INR', currencyExponent: 2, minorUnits: g.settlementPlan.transfers[0].amount.minorUnits,
    }, { 'Idempotency-Key': randomUUID() })
    assert.equal(old.status, 409, brief(old))
  })

  await step('S10 An archived group refuses the setting', async () => {
    // Settle what is left, archive, then try.
    let g = await read()
    for (const t of g.settlementPlan.transfers) {
      const payer = g.members.find((m: Json) => m.memberId === t.payerMemberId).accountId
      const who = [you, kabir, aarav].find((u) => u.id === payer)!
      const r = await request(T(who), `/api/groups/${groupId}/settlements`, 'POST', {
        expectedVersion: g.revision, planTransferId: t.planTransferId,
        payerParticipantId: t.payerMemberId, recipientParticipantId: t.recipientMemberId,
        currencyCode: 'INR', currencyExponent: 2, minorUnits: t.amount.minorUnits,
      }, { 'Idempotency-Key': randomUUID() })
      assert.equal(r.status, 201, brief(r))
      g = await read()
    }
    const archived = await request(T(you), `/api/mobile/groups/${groupId}`, 'DELETE')
    assert.ok(archived.status === 200 || archived.status === 204, `archive: ${brief(archived)}`)
    const r = await setSimplify(you, g.revision, false)
    assert.ok(r.status === 403 || r.status === 404 || r.status === 409, brief(r))
    assert.notEqual(r.status, 200)
  })

  console.log('# Simplify-debts setting E2E')
  console.log(`Revision: ${revision()}`)
  console.log(`Environment: API ${devApiBase}, DB ${devDatabaseUrl.replace(/\/\/[^@]*@/, '//')}, node ${process.version}, ${new Date().toISOString()}`)
  console.log('Replay: cd apps/api && DEV_DATABASE_URL=... DEV_API_BASE=... npx tsx scripts/simplify-debts-e2e.ts')
  console.log(`Group: ${groupId}\n| Step | Result |\n| --- | --- |`)
  for (const row of results) console.log(`| ${row.name} | ${row.result.replaceAll('|', '/').replaceAll('\n', ' ')} |`)
  const failed = results.filter((row) => row.result !== 'PASS').length
  console.log(`\n${results.length - failed} PASS, ${failed} FAIL`)
  if (failed) process.exitCode = 1
}

main().catch((error) => { console.error(error); process.exitCode = 1 }).finally(() => db.$disconnect())
