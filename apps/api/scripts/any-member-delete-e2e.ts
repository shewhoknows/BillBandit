import assert from 'node:assert/strict'
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
  const response = await fetch(new URL(path, devApiBase), { method, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...headers }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
  const text = await response.text()
  let data: Json = {}
  try { data = JSON.parse(text) } catch { data = { text } }
  return { status: response.status, data }
}
async function step(name: string, fn: () => Promise<void>) {
  try { await fn(); results.push({ name, result: 'PASS' }) } catch (error) { results.push({ name, result: `FAIL: ${error instanceof Error ? error.message : error}` }) }
}
async function main() {
  const { createMobileToken } = await import('../lib/mobile-auth')
  const users = await Promise.all(['dev_you', 'dev_kabir', 'dev_zoya'].map((username) => db.user.findUniqueOrThrow({ where: { username } })))
  const [owner, member, outsider] = users
  const tokens = users.map((user) => createMobileToken(user))
  const [ownerToken, memberToken, outsiderToken] = tokens
  const groupResult = await request(ownerToken, '/api/mobile/groups', 'POST', { name: `Delete E2E ${Date.now()}`, currency: 'INR', category: 'TRIP', memberAccountIds: [member.id] }, { 'Idempotency-Key': randomUUID() })
  assert.equal(groupResult.status, 201, JSON.stringify(groupResult.data))
  const groupId = groupResult.data.group.id as string
  const read = async (token = ownerToken) => {
    const response = await request(token, `/api/mobile/ledger/groups/${groupId}`)
    assert.equal(response.status, 200, JSON.stringify(response.data))
    return response.data.data.group as Json
  }
  const add = async (title: string) => {
    const group = await read()
    const id = randomUUID()
    const body = { groupId, operationId: randomUUID(), expectedRevision: group.revision, expenseId: id, description: title, amount: money(10000), currency: 'INR', paidById: owner.id, splitType: 'EQUAL', splits: [owner, member].map((u, i) => ({ id: `${id}-${i}`, userId: u.id, amount: money(5000) })) }
    const result = await request(ownerToken, '/api/mobile/expenses', 'POST', body)
    assert.equal(result.status, 201, JSON.stringify(result.data))
    return { id, body }
  }
  const del = (token: string, id: string, revision: number) => request(token, `/api/mobile/expenses/${id}`, 'DELETE', { operationId: randomUUID(), expectedRevision: revision })
  const first = await add('Non-payer deletion')
  await step('Non-payer deletes; activity identifies actor and payer', async () => {
    const result = await del(memberToken, first.id, (await read()).revision)
    assert.equal(result.status, 200, JSON.stringify(result.data))
    const log = await db.activityLog.findFirstOrThrow({ where: { metadata: { path: ['groupId'], equals: groupId }, type: 'EXPENSE_DELETED', userId: member.id }, orderBy: { createdAt: 'desc' } })
    const metadata = log.metadata as Json
    assert.equal(metadata.expenseId, first.id); assert.equal(metadata.paidByAccountId, owner.id); assert.equal(metadata.amount.minorUnits, '10000'); assert.ok(metadata.date)
    const group = await read()
    const event = group.activity.find((entry: Json) => entry.expenseId === first.id && entry.action === 'deleted')
    assert.equal(event.actorMemberId, group.members.find((entry: Json) => entry.accountId === member.id).memberId)
  })
  await step('Both members see the same balances', async () => {
    const a = await read(ownerToken); const b = await read(memberToken)
    assert.ok(a.balances.byMember.length >= 2)
    assert.deepEqual(a.balances.byMember, b.balances.byMember)
    assert.deepEqual(a.settlementPlan, b.settlementPlan)
  })
  const second = await add('Concurrent deletion')
  await step('Non-member is refused', async () => { const r = await del(outsiderToken, second.id, (await read()).revision); assert.equal(r.status, 403, `expected 403; got ${r.status}`) })
  await step('Concurrent deletes produce one success and one activity', async () => {
    const revision = (await read()).revision
    const responses = await Promise.all([del(ownerToken, second.id, revision), del(memberToken, second.id, revision)])
    assert.equal(responses.filter((r) => r.status === 200).length, 1, JSON.stringify(responses))
    assert.ok(responses.some((r) => r.status >= 400 && r.status < 500))
    const logs = await db.activityLog.findMany({ where: { metadata: { path: ['groupId'], equals: groupId }, type: 'EXPENSE_DELETED' } })
    assert.equal(logs.filter((log) => (log.metadata as Json)?.expenseId === second.id).length, 1)
  })
  await step('Edit after deletion is refused', async () => {
    const result = await request(ownerToken, `/api/mobile/expenses/${second.id}`, 'PUT', { ...second.body, operationId: randomUUID(), expectedRevision: (await read()).revision })
    assert.ok(result.status >= 400 && result.status < 500, `status ${result.status}`)
  })
  const paid = await add('Recorded payment deletion')
  await step('Payment survives deletion and balances recompute', async () => {
    const before = await read(memberToken); const transfer = before.settlementPlan.transfers[0]
    assert.ok(transfer)
    const payment = await request(memberToken, `/api/groups/${groupId}/settlements`, 'POST', { expectedVersion: before.revision, planTransferId: transfer.planTransferId, payerParticipantId: transfer.payerMemberId, recipientParticipantId: transfer.recipientMemberId, currencyCode: 'INR', currencyExponent: 2, minorUnits: '2000' }, { 'Idempotency-Key': randomUUID() })
    assert.equal(payment.status, 201, JSON.stringify(payment.data))
    const deletion = await del(memberToken, paid.id, (await read()).revision)
    assert.equal(deletion.status, 200, JSON.stringify(deletion.data))
    const after = await read(); const other = await read(memberToken)
    assert.ok(after.settlementHistory.some((item: Json) => item.status === 'active' && item.amount.minorUnits === '2000'))
    assert.deepEqual(after.settlementPlan, other.settlementPlan)
    assert.equal(after.settlementPlan.transfers[0].amount.minorUnits, '2000')
  })
  const removed = await add('Removed member refusal')
  await step('Removed member is refused', async () => {
    const group = await read(); const transfer = group.settlementPlan.transfers[0]
    if (transfer) {
      const who = group.members.find((m: Json) => m.memberId === transfer.payerMemberId).accountId === owner.id ? ownerToken : memberToken
      const settled = await request(who, `/api/groups/${groupId}/settlements`, 'POST', { expectedVersion: group.revision, planTransferId: transfer.planTransferId, payerParticipantId: transfer.payerMemberId, recipientParticipantId: transfer.recipientMemberId, currencyCode: 'INR', currencyExponent: 2, minorUnits: transfer.amount.minorUnits }, { 'Idempotency-Key': randomUUID() })
      assert.equal(settled.status, 201, JSON.stringify(settled.data))
    }
    const left = await request(memberToken, `/api/mobile/groups/${groupId}/leave`, 'POST', undefined, { 'Idempotency-Key': randomUUID() })
    assert.equal(left.status, 200, JSON.stringify(left.data))
    const result = await del(memberToken, removed.id, (await read()).revision)
    assert.equal(result.status, 403, `expected 403; got ${result.status}`)
  })
  await step('Archived group refuses deletion', async () => {
    const solo = await request(ownerToken, '/api/mobile/groups', 'POST', { name: `Archive E2E ${Date.now()}`, currency: 'INR', category: 'TRIP', memberAccountIds: [] }, { 'Idempotency-Key': randomUUID() })
    assert.equal(solo.status, 201); const gid = solo.data.group.id
    const g = (await request(ownerToken, `/api/mobile/ledger/groups/${gid}`)).data.data.group
    const id = randomUUID()
    const created = await request(ownerToken, '/api/mobile/expenses', 'POST', { groupId: gid, operationId: randomUUID(), expectedRevision: g.revision, expenseId: id, description: 'Archive expense', amount: money(100), currency: 'INR', paidById: owner.id, splitType: 'EQUAL', splits: [{ id: randomUUID(), userId: owner.id, amount: money(100) }] })
    assert.equal(created.status, 201, JSON.stringify(created.data))
    const archived = await request(ownerToken, `/api/mobile/groups/${gid}`, 'DELETE')
    assert.equal(archived.status, 200, JSON.stringify(archived.data))
    const result = await del(ownerToken, id, g.revision + 1)
    assert.ok(result.status >= 400 && result.status < 500, `status ${result.status}`)
  })
  console.log(`Group: ${groupId}\n| Check | Result |\n| --- | --- |`)
  for (const row of results) console.log(`| ${row.name} | ${row.result.replaceAll('|', '/').replaceAll('\n', ' ')} |`)
  if (results.some((row) => row.result !== 'PASS')) process.exitCode = 1
}
main().catch((error) => { console.error(error); process.exitCode = 1 }).finally(() => db.$disconnect())
