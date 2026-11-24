/**
 * Ledger kernel state machines, end to end over HTTP against the LOCAL server.
 *
 * Each check drives the real routes with real member tokens. The first group
 * of checks reproduces bugs found by the TLA+ models in specs/tla/ledger-kernel/
 * (they FAIL on the code before commit sm/ledger-kernel and PASS after); the
 * last group are regression checks that pass on both.
 *
 * Replay (from apps/api, with the local server running on the same DB):
 *   DEV_DATABASE_URL=postgresql://postgres@localhost:5432/billbandit_a1 \
 *   DEV_API_BASE=http://127.0.0.1:3101 npx tsx scripts/ledger-kernel-e2e.ts
 *
 * Needs the users of `npx tsx scripts/dev-data.ts scenario` (dev_you, dev_kabir).
 * It adds dev_zoya itself (local only, same rules as dev-data). It only adds data.
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
type User = { id: string; email: string; name: string | null }
const results: { id: string; name: string; result: string }[] = []
const groupsUsed: string[] = []
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
const brief = (r: { status: number; data: Json }) =>
  `${r.status} ${r.data.error ?? r.data.code ?? r.data.mutation?.outcome ?? ''} ${r.data.message ?? ''}`.trim()

async function step(id: string, name: string, fn: () => Promise<void>) {
  try {
    await fn()
    results.push({ id, name, result: 'PASS' })
  } catch (error) {
    results.push({ id, name, result: `FAIL: ${error instanceof Error ? error.message : String(error)}` })
  }
}

async function ensureZoya(you: User): Promise<User> {
  const user = await db.user.upsert({
    where: { email: 'zoya@dev.billbandit.local' },
    update: {},
    create: { id: 'dev-zoya', email: 'zoya@dev.billbandit.local', name: 'Zoya', preferredName: 'Zoya', username: 'dev_zoya' },
  })
  const [fromId, toId] = [you.id, user.id].sort()
  await db.friendship.upsert({
    where: { fromId_toId: { fromId, toId } },
    update: { status: 'ACCEPTED' },
    create: { fromId, toId, status: 'ACCEPTED' },
  })
  return user
}

async function main() {
  const scope = process.env.BILLBANDIT_LEDGER_E2E_SCOPE ?? 'all'
  if (scope !== 'all' && scope !== 'kernel' && scope !== 'membership') {
    throw new Error(`Unknown ledger E2E scope: ${scope}`)
  }
  const { createMobileToken } = await import('../lib/mobile-auth')
  const [you, kabir] = await Promise.all(
    ['dev_you', 'dev_kabir'].map((username) => db.user.findUniqueOrThrow({ where: { username } }))
  )
  const zoya = await ensureZoya(you)
  const tok = new Map([you, kabir, zoya].map((u) => [u.id, createMobileToken(u)]))
  const T = (u: User) => tok.get(u.id)!

  const newGroup = async (label: string, members: User[]) => {
    const r = await request(T(you), '/api/mobile/groups', 'POST',
      { name: `Kernel E2E ${label} ${Date.now()}`, currency: 'INR', category: 'TRIP', memberAccountIds: members.map((m) => m.id) },
      { 'Idempotency-Key': randomUUID() })
    assert.equal(r.status, 201, brief(r))
    groupsUsed.push(r.data.group.id)
    return r.data.group.id as string
  }
  const read = async (groupId: string, who: User = you) => {
    const r = await request(T(who), `/api/mobile/ledger/groups/${groupId}`)
    assert.equal(r.status, 200, brief(r))
    return r.data.data.group as Json
  }
  const memberOf = (group: Json, user: User) => group.members.find((m: Json) => m.accountId === user.id)
  const balanceOf = (group: Json, user: User) =>
    group.balances.byMember.find((b: Json) => b.memberId === memberOf(group, user).memberId)
      .byCurrency.map((m: Json) => m.minorUnits).join(',')
  const expenseBody = (groupId: string, revision: number, payer: User, shares: [User, number][], title = 'Kernel E2E') => {
    const expenseId = randomUUID()
    const total = shares.reduce((sum, [, n]) => sum + n, 0)
    return {
      groupId, operationId: randomUUID(), expectedRevision: revision, expenseId, description: title,
      amount: money(total), currency: 'INR', paidById: payer.id, splitType: 'EXACT',
      splits: shares.map(([u, n]) => ({ userId: u.id, amount: money(n) })),
    }
  }
  const addExpense = async (groupId: string, payer: User, shares: [User, number][], title?: string) => {
    const body = expenseBody(groupId, (await read(groupId)).revision, payer, shares, title)
    const r = await request(T(you), '/api/mobile/expenses', 'POST', body)
    assert.equal(r.status, 201, brief(r))
    return body
  }

  // ---------------------------------------------------------------- bugs
  // Bug 1 (LedgerKernel.tla ReplayStable, Fixes = {}): a retry of a committed delete answered 404.
  if (scope !== 'membership') {
    const g = await newGroup('replay-delete', [kabir])
    const e = await addExpense(g, you, [[you, 500], [kabir, 500]])
    await step('B1', 'Retry of a committed DELETE (same operationId) replays the first answer, not 404', async () => {
      const body = { operationId: randomUUID(), expectedRevision: (await read(g)).revision }
      const first = await request(T(you), `/api/mobile/expenses/${e.expenseId}`, 'DELETE', body)
      assert.equal(first.status, 200, `first: ${brief(first)}`)
      const retry = await request(T(you), `/api/mobile/expenses/${e.expenseId}`, 'DELETE', body)
      assert.equal(retry.status, 200, `retry: ${brief(retry)}`)
      assert.equal(retry.data.mutation.outcome, 'replayed')
      assert.equal(retry.data.mutation.revision, first.data.mutation.revision)
    })
    await step('B1b', 'A NEW delete of the deleted expense is still refused (404 already deleted)', async () => {
      const r = await request(T(kabir), `/api/mobile/expenses/${e.expenseId}`, 'DELETE',
        { operationId: randomUUID(), expectedRevision: (await read(g)).revision })
      assert.equal(r.status, 404, brief(r))
    })
    const e2 = await addExpense(g, you, [[you, 300], [kabir, 300]])
    await step('B1c', 'Retry of a committed edit after another member deleted the expense replays, not 404', async () => {
      const edit = { ...e2, description: 'Edited', operationId: randomUUID(), expectedRevision: (await read(g)).revision }
      const first = await request(T(you), `/api/mobile/expenses/${e2.expenseId}`, 'PUT', edit)
      assert.equal(first.status, 200, `edit: ${brief(first)}`)
      const del = await request(T(kabir), `/api/mobile/expenses/${e2.expenseId}`, 'DELETE',
        { operationId: randomUUID(), expectedRevision: (await read(g)).revision })
      assert.equal(del.status, 200, `delete: ${brief(del)}`)
      const retry = await request(T(you), `/api/mobile/expenses/${e2.expenseId}`, 'PUT', edit)
      assert.equal(retry.status, 200, `retry: ${brief(retry)}`)
      assert.equal(retry.data.mutation.outcome, 'replayed')
      assert.equal(retry.data.mutation.revision, first.data.mutation.revision)
      assert.equal((await read(g)).expenses.find((x: Json) => x.expenseId === e2.expenseId).status, 'voided')
    })
  }

  // Bug 2 (LedgerKernel.tla ReplayStable, Fixes = {"route"}): two attempts with one key at once -> one 500.
  if (scope !== 'membership') {
    const g = await newGroup('same-key', [kabir])
    await step('B2', 'Two attempts of one expense create at the same moment: both succeed, one applied + one replayed (8 rounds)', async () => {
      for (let round = 0; round < 8; round += 1) {
        const body = expenseBody(g, (await read(g)).revision, you, [[you, 100], [kabir, 100]], `Race ${round}`)
        const pair = await Promise.all([
          request(T(you), '/api/mobile/expenses', 'POST', body),
          request(T(you), '/api/mobile/expenses', 'POST', body),
        ])
        assert.ok(pair.every((r) => r.status === 200 || r.status === 201), `round ${round}: ${pair.map(brief).join(' | ')}`)
        assert.deepEqual(pair.map((r) => r.data.mutation.outcome).sort(), ['applied', 'replayed'], `round ${round}`)
        assert.equal(pair[0].data.mutation.revision, pair[1].data.mutation.revision)
        assert.equal(await db.expense.count({ where: { id: body.expenseId } }), 1)
      }
    })
    await step('B2b', 'Two attempts of one group create (same Idempotency-Key) at once: same group, no 500 (8 rounds)', async () => {
      for (let round = 0; round < 8; round += 1) {
        const key = randomUUID()
        const body = { name: `Kernel E2E race ${round} ${Date.now()}`, currency: 'INR', category: 'TRIP', memberAccountIds: [kabir.id] }
        const pair = await Promise.all([0, 1].map(() => request(T(you), '/api/mobile/groups', 'POST', body, { 'Idempotency-Key': key })))
        assert.ok(pair.every((r) => r.status === 200 || r.status === 201), `round ${round}: ${pair.map(brief).join(' | ')}`)
        assert.equal(pair[0].data.group.id, pair[1].data.group.id)
        groupsUsed.push(pair[0].data.group.id)
      }
    })
    await step('B2c', 'Two attempts of one finalize at once: both succeed with the same revision', async () => {
      const f = await newGroup('finalize-race', [kabir])
      const body = { operationId: randomUUID(), expectedRevision: (await read(f)).revision }
      const pair = await Promise.all([0, 1].map(() => request(T(you), `/api/mobile/groups/${f}/finalize`, 'POST', body)))
      assert.ok(pair.every((r) => r.status === 200), pair.map(brief).join(' | '))
      assert.equal(pair[0].data.revision, pair[1].data.revision)
    })
  }

  // Bug 3 (GroupMembership.tla DepartedAreSettled, Fixes = {}): leaving through DELETE /members skipped the balance check.
  if (scope !== 'kernel') {
    const g = await newGroup('leave-owing', [kabir])
    await addExpense(g, you, [[you, 500], [kabir, 500]])
    await step('B3', 'A member who owes money cannot remove themself through DELETE /members', async () => {
      const before = await read(g)
      const r = await request(T(kabir), `/api/mobile/groups/${g}/members`, 'DELETE',
        { userId: kabir.id, operationId: randomUUID(), expectedRevision: before.revision })
      const after = await read(g)
      assert.equal(memberOf(after, kabir).status, 'active', `kabir is ${memberOf(after, kabir).status} after ${brief(r)}`)
      assert.equal(r.status, 409, brief(r))
      assert.equal(r.data.error, 'MEMBER_UNSETTLED')
    })
    await step('B3b', 'The owner cannot remove a member who still owes money', async () => {
      const r = await request(T(you), `/api/mobile/groups/${g}/members`, 'DELETE',
        { userId: kabir.id, operationId: randomUUID(), expectedRevision: (await read(g)).revision })
      const after = await read(g)
      assert.equal(memberOf(after, kabir).status, 'active', `kabir is ${memberOf(after, kabir).status} after ${brief(r)}`)
      assert.equal(r.status, 409, brief(r))
    })
  }

  // Bug 4 (GroupMembership.tla HasAdmin, Fixes = {"balance"}): the last owner could remove or demote themself.
  if (scope !== 'kernel') {
    const g = await newGroup('last-owner', [kabir])
    await step('B4', 'The only owner cannot remove themself (group keeps an owner)', async () => {
      const r = await request(T(you), `/api/mobile/groups/${g}/members`, 'DELETE',
        { userId: you.id, operationId: randomUUID(), expectedRevision: (await read(g)).revision })
      const row = await db.groupMember.findUnique({ where: { groupId_userId: { groupId: g, userId: you.id } } })
      assert.ok(row, `owner row removed after ${brief(r)}`)
      assert.equal(r.status, 409, brief(r))
      assert.equal(r.data.error, 'LAST_ADMIN')
    })
    await step('B4b', 'The only owner cannot make themself a plain member', async () => {
      const g = await newGroup('last-owner-demote', [kabir])
      const r = await request(T(you), `/api/mobile/groups/${g}/members`, 'PATCH',
        { userId: you.id, role: 'MEMBER', operationId: randomUUID(), expectedRevision: (await read(g)).revision })
      const admins = await db.groupMember.count({ where: { groupId: g, role: 'ADMIN' } })
      assert.equal(admins, 1, `admins=${admins} after ${brief(r)}`)
      assert.equal(r.status, 409, brief(r))
    })
  }

  // Bug 5 (GroupMembership.tla DepartedAreSettled, Fixes = {"balance","admin"}):
  // a settled member leaves, then a delete / reversal moves their balance.
  if (scope !== 'kernel') {
    const g = await newGroup('departed-balance', [kabir, zoya])
    const taxi = await addExpense(g, you, [[you, 500], [kabir, 500]], 'Taxi')
    await addExpense(g, kabir, [[you, 500], [kabir, 500]], 'Dinner')
    // Bobby's rule (2026-11-21): after someone leaves, old expenses that
    // include them can still be edited or deleted. The debt that this makes
    // stays visible to the members, and either side can settle it.
    await step('B5', 'After a settled member leaves, deleting an expense they shared is allowed; their new debt shows', async () => {
      assert.equal(balanceOf(await read(g), kabir), '0')
      const left = await request(T(kabir), `/api/mobile/groups/${g}/leave`, 'POST', undefined, { 'Idempotency-Key': randomUUID() })
      assert.equal(left.status, 200, `leave: ${brief(left)}`)
      const del = await request(T(you), `/api/mobile/expenses/${taxi.expenseId}`, 'DELETE',
        { operationId: randomUUID(), expectedRevision: (await read(g)).revision })
      assert.equal(del.status, 200, brief(del))
      const after = await read(g)
      assert.notEqual(balanceOf(after, kabir), '0', 'the departed member now owes or is owed money')
      assert.ok(
        after.settlementPlan.transfers.some((t: Json) => t.payerMemberId === memberOf(after, kabir).memberId || t.recipientMemberId === memberOf(after, kabir).memberId),
        'the plan has a transfer with the departed member'
      )
    })
    await step('B5a', 'The departed member can settle their new debt themself; the balance is 0 again', async () => {
      const before = await read(g)
      const transfer = before.settlementPlan.transfers.find((t: Json) =>
        t.payerMemberId === memberOf(before, kabir).memberId || t.recipientMemberId === memberOf(before, kabir).memberId)
      const paid = await request(T(kabir), `/api/groups/${g}/settlements`, 'POST', {
        expectedVersion: before.revision, planTransferId: transfer.planTransferId,
        payerParticipantId: transfer.payerMemberId, recipientParticipantId: transfer.recipientMemberId,
        currencyCode: 'INR', currencyExponent: 2, minorUnits: transfer.amount.minorUnits,
      }, { 'Idempotency-Key': randomUUID() })
      assert.equal(paid.status, 201, `pay: ${brief(paid)}`)
      assert.equal(balanceOf(await read(g), kabir), '0')
    })
    await step('B5b', 'Unrelated writes still work in a group with a departed member', async () => {
      await addExpense(g, you, [[you, 200], [zoya, 200]], 'Coffee')
    })
    await step('B5c', 'Reversing a payment of a member who has since left is allowed; the debt shows again', async () => {
      const g2 = await newGroup('departed-reversal', [kabir])
      await addExpense(g2, you, [[you, 500], [kabir, 500]])
      const before = await read(g2)
      const transfer = before.settlementPlan.transfers[0]
      const paid = await request(T(kabir), `/api/groups/${g2}/settlements`, 'POST', {
        expectedVersion: before.revision, planTransferId: transfer.planTransferId,
        payerParticipantId: transfer.payerMemberId, recipientParticipantId: transfer.recipientMemberId,
        currencyCode: 'INR', currencyExponent: 2, minorUnits: transfer.amount.minorUnits,
      }, { 'Idempotency-Key': randomUUID() })
      assert.equal(paid.status, 201, `pay: ${brief(paid)}`)
      const left = await request(T(kabir), `/api/mobile/groups/${g2}/leave`, 'POST', undefined, { 'Idempotency-Key': randomUUID() })
      assert.equal(left.status, 200, `leave: ${brief(left)}`)
      const settled = await read(g2)
      const settlementId = settled.settlementHistory.find((s: Json) => s.status === 'active').settlementId
      const rev = await request(T(you), `/api/groups/${g2}/settlements/${settlementId}/reversals`, 'POST',
        { expectedVersion: settled.revision }, { 'Idempotency-Key': randomUUID() })
      assert.equal(rev.status, 201, brief(rev))
      assert.equal(balanceOf(await read(g2), kabir), '-500', 'kabir owes his share again')
    })
    await step('B5d', 'A departed member with no debt still cannot record payments (403)', async () => {
      const g3 = await newGroup('departed-settled', [kabir])
      await addExpense(g3, you, [[you, 300], [kabir, 300]])
      const open = await read(g3)
      const t = open.settlementPlan.transfers[0]
      const body = () => ({ payerParticipantId: t.payerMemberId, recipientParticipantId: t.recipientMemberId, currencyCode: 'INR', currencyExponent: 2, minorUnits: t.amount.minorUnits })
      assert.equal((await request(T(kabir), `/api/groups/${g3}/settlements`, 'POST', { ...body(), expectedVersion: open.revision, planTransferId: t.planTransferId }, { 'Idempotency-Key': randomUUID() })).status, 201)
      assert.equal((await request(T(kabir), `/api/mobile/groups/${g3}/leave`, 'POST', undefined, { 'Idempotency-Key': randomUUID() })).status, 200)
      const later = await read(g3)
      const again = await request(T(kabir), `/api/groups/${g3}/settlements`, 'POST', { ...body(), expectedVersion: later.revision, planTransferId: t.planTransferId }, { 'Idempotency-Key': randomUUID() })
      assert.ok(again.status === 403 || again.status === 404, brief(again))
    })
  }

  // Bobby's rule (2026-11-21): a person who left does not see the group,
  // but if they are added back, a debt that changed while they were away
  // shows for them again.
  if (scope !== 'kernel') {
    const g = await newGroup('departed-readd', [kabir])
    await addExpense(g, you, [[you, 500], [kabir, 500]], 'Taxi')
    const dinner = await addExpense(g, kabir, [[you, 500], [kabir, 500]], 'Dinner')
    await step('B5e', 'Left with 0, then an old expense is deleted: the group stays hidden for them; added back, their debt shows', async () => {
      assert.equal(balanceOf(await read(g), kabir), '0')
      const left = await request(T(kabir), `/api/mobile/groups/${g}/leave`, 'POST', undefined, { 'Idempotency-Key': randomUUID() })
      assert.equal(left.status, 200, `leave: ${brief(left)}`)
      const del = await request(T(you), `/api/mobile/expenses/${dinner.expenseId}`, 'DELETE',
        { operationId: randomUUID(), expectedRevision: (await read(g)).revision })
      assert.equal(del.status, 200, brief(del))
      assert.equal(balanceOf(await read(g), kabir), '-500', 'kabir owes 500 now')
      // Hidden while away: not in their group list, and the group read is refused.
      const list = await request(T(kabir), '/api/mobile/groups')
      assert.equal(list.status, 200, brief(list))
      assert.ok(!(list.data.groups as Json[]).some((x) => x.id === g), 'the group is not in their list while they are away')
      const away = await request(T(kabir), `/api/mobile/ledger/groups/${g}`)
      assert.notEqual(away.status, 200, `away read: ${brief(away)}`)
      // Added back by the owner.
      const back = await request(T(you), `/api/mobile/groups/${g}/members`, 'POST',
        { userId: kabir.id, operationId: randomUUID(), expectedRevision: (await read(g)).revision })
      assert.equal(back.status, 201, `re-add: ${brief(back)}`)
      const listBack = await request(T(kabir), '/api/mobile/groups')
      assert.ok((listBack.data.groups as Json[]).some((x) => x.id === g), 'the group is in their list again')
      const theirs = await read(g, kabir)
      assert.equal(memberOf(theirs, kabir).status, 'active')
      assert.equal(balanceOf(theirs, kabir), '-500', 'their own read shows the debt')
      const t = theirs.settlementPlan.transfers.find((x: Json) => x.payerMemberId === memberOf(theirs, kabir).memberId)
      assert.ok(t, 'their settle-up plan has the payment to make')
      assert.equal(t.amount.minorUnits, '500')
    })
  }

  // Bug 6: a self-removal through DELETE /members committed but answered 500 (phone retries forever).
  if (scope !== 'kernel') {
    const g = await newGroup('self-remove', [zoya])
    await step('B6', 'A settled member removing themself through DELETE /members gets 200, not 500', async () => {
      const r = await request(T(zoya), `/api/mobile/groups/${g}/members`, 'DELETE',
        { userId: zoya.id, operationId: randomUUID(), expectedRevision: (await read(g)).revision })
      assert.equal(r.status, 200, brief(r))
      assert.equal(memberOf(await read(g), zoya).status, 'departed')
    })
  }

  // ------------------------------------------------------- regressions
  if (scope !== 'membership') {
    const g = await newGroup('regression', [kabir])
    const e = await addExpense(g, you, [[you, 700], [kabir, 700]])
    await step('R1', 'Two phones edit one expense with the same stale revision: one 200, one REVISION_CONFLICT (no lost update)', async () => {
      const revision = (await read(g)).revision
      const pair = await Promise.all([
        request(T(you), `/api/mobile/expenses/${e.expenseId}`, 'PUT', { ...e, description: 'From you', operationId: randomUUID(), expectedRevision: revision }),
        request(T(kabir), `/api/mobile/expenses/${e.expenseId}`, 'PUT', { ...e, description: 'From kabir', operationId: randomUUID(), expectedRevision: revision }),
      ])
      assert.deepEqual(pair.map((r) => r.status).sort(), [200, 409], pair.map(brief).join(' | '))
      const winner = pair.find((r) => r.status === 200)!
      const loser = pair.find((r) => r.status === 409)!
      assert.equal(loser.data.error, 'REVISION_CONFLICT')
      assert.equal((await read(g)).expenses.find((x: Json) => x.expenseId === e.expenseId).description, winner.data.expense.description)
    })
    await step('R2', 'Same operationId with a different body is refused (IDEMPOTENCY_KEY_REUSED) and writes nothing', async () => {
      const body = expenseBody(g, (await read(g)).revision, you, [[you, 100], [kabir, 100]])
      const first = await request(T(you), '/api/mobile/expenses', 'POST', body)
      assert.equal(first.status, 201, brief(first))
      const other = await request(T(you), '/api/mobile/expenses', 'POST', { ...body, description: 'Different', expectedRevision: (await read(g)).revision })
      assert.equal(other.status, 409, brief(other))
      assert.equal(other.data.error, 'IDEMPOTENCY_KEY_REUSED')
    })
    await step('R3', 'A finalized group refuses new expenses; an archived group refuses everything', async () => {
      const f = await newGroup('finalized', [kabir])
      const fin = await request(T(you), `/api/mobile/groups/${f}/finalize`, 'POST', { operationId: randomUUID(), expectedRevision: (await read(f)).revision })
      assert.equal(fin.status, 200, brief(fin))
      const add = await request(T(you), '/api/mobile/expenses', 'POST', expenseBody(f, (await read(f)).revision, you, [[you, 100], [kabir, 100]]))
      assert.equal(add.status, 409, brief(add)); assert.equal(add.data.error, 'GROUP_FINALIZED')
      const archived = await request(T(you), `/api/mobile/groups/${f}`, 'DELETE')
      assert.equal(archived.status, 200, brief(archived))
      const row = await db.group.findUniqueOrThrow({ where: { id: f } })
      const add2 = await request(T(you), '/api/mobile/expenses', 'POST', expenseBody(f, row.settlementVersion, you, [[you, 100], [kabir, 100]]))
      assert.ok(add2.status >= 400 && add2.status < 500, brief(add2))
    })
  }

  if (scope !== 'membership') {
    const g = await newGroup('hash-stability', [kabir, zoya])
    await step('R4', 'A create sent with member ids replays after membership changed (zoya leaves, is added back): no IDEMPOTENCY_KEY_REUSED', async () => {
      const model = await read(g)
      const youMember = memberOf(model, you).memberId
      const body = {
        groupId: g, operationId: randomUUID(), expectedRevision: model.revision, expenseId: randomUUID(),
        description: 'Member-id body', amount: money(400), currency: 'INR', paidByMemberId: youMember, splitType: 'EXACT',
        splits: [{ memberId: youMember, amount: money(400) }],
      }
      const first = await request(T(you), '/api/mobile/expenses', 'POST', body)
      assert.equal(first.status, 201, `first: ${brief(first)}`)
      const left = await request(T(zoya), `/api/mobile/groups/${g}/leave`, 'POST', undefined, { 'Idempotency-Key': randomUUID() })
      assert.equal(left.status, 200, `leave: ${brief(left)}`)
      const afterLeave = await request(T(you), '/api/mobile/expenses', 'POST', body)
      assert.equal(afterLeave.status, 200, `after leave: ${brief(afterLeave)}`)
      assert.equal(afterLeave.data.mutation.outcome, 'replayed')
      const back = await request(T(you), `/api/mobile/groups/${g}/members`, 'POST',
        { userId: zoya.id, operationId: randomUUID(), expectedRevision: (await read(g)).revision })
      assert.equal(back.status, 201, `re-add: ${brief(back)}`)
      const afterAdd = await request(T(you), '/api/mobile/expenses', 'POST', body)
      assert.equal(afterAdd.status, 200, `after re-add: ${brief(afterAdd)}`)
      assert.equal(afterAdd.data.mutation.revision, first.data.mutation.revision)
    })
    await step('R5', 'An offline queue sent in order with a reserved revision chain (r, r+1, r+2) applies, and replays unchanged when sent again', async () => {
      const a = await addExpense(g, you, [[you, 100], [kabir, 100]])
      const b = await addExpense(g, you, [[you, 100], [kabir, 100]])
      const c = await addExpense(g, you, [[you, 100], [kabir, 100]])
      const r = (await read(g)).revision
      const queue = [
        () => request(T(you), `/api/mobile/expenses/${a.expenseId}`, 'DELETE', { operationId: `chain-a-${a.expenseId}`, expectedRevision: r }),
        () => request(T(you), `/api/mobile/expenses/${b.expenseId}`, 'PUT', { ...b, description: 'Chained edit', operationId: `chain-b-${b.expenseId}`, expectedRevision: r + 1 }),
        () => request(T(you), `/api/mobile/expenses/${c.expenseId}`, 'DELETE', { operationId: `chain-c-${c.expenseId}`, expectedRevision: r + 2 }),
      ]
      const firstPass = []
      for (const send of queue) firstPass.push(await send())
      assert.deepEqual(firstPass.map((x) => [x.status, x.data.mutation?.outcome, x.data.mutation?.revision]),
        [[200, 'applied', r + 1], [200, 'applied', r + 2], [200, 'applied', r + 3]], firstPass.map(brief).join(' | '))
      const secondPass = []
      for (const send of queue) secondPass.push(await send())
      assert.deepEqual(secondPass.map((x) => [x.status, x.data.mutation?.outcome, x.data.mutation?.revision]),
        [[200, 'replayed', r + 1], [200, 'replayed', r + 2], [200, 'replayed', r + 3]], secondPass.map(brief).join(' | '))
    })
  }

  // ------------------------------------------- invariants on every group used
  await step('I1', 'Every group used: balances sum to zero per currency; journal versions are exactly 1..revision; deleted expenses do not count', async () => {
    for (const groupId of groupsUsed) {
      const row = await db.group.findUniqueOrThrow({ where: { id: groupId } })
      const versions = (await db.settlementVersionJournal.findMany({ where: { groupId }, select: { version: true } }))
        .map((v) => v.version).sort((a, b) => a - b)
      assert.deepEqual(versions, Array.from({ length: row.settlementVersion }, (_, i) => i + 1), `group ${groupId} journal ${versions}`)
      const expenses = await db.expense.findMany({ where: { groupId, isDeleted: false }, include: { splits: true } })
      const transactions = await db.transaction.findMany({ where: { groupId }, include: { reversal: true } })
      const net = new Map<string, bigint>()
      const add = (k: string, v: bigint) => net.set(k, (net.get(k) ?? 0n) + v)
      for (const e of expenses) { add(e.paidById, e.amountMinorUnits ?? 0n); for (const s of e.splits) add(s.userId, -(s.amountMinorUnits ?? 0n)) }
      for (const t of transactions) if (!t.reversal) { add(t.senderId, t.amountMinorUnits ?? 0n); add(t.receiverId, -(t.amountMinorUnits ?? 0n)) }
      assert.equal([...net.values()].reduce((a, b) => a + b, 0n), 0n, `group ${groupId} does not sum to zero`)
      const youInGroup = await db.groupMember.findUnique({ where: { groupId_userId: { groupId, userId: you.id } } })
      if (!row.isArchived && youInGroup) {
        const model = await read(groupId)
        for (const c of model.balances.byCurrency) assert.equal(c.net.minorUnits, '0', `group ${groupId} read model net ${c.net.minorUnits}`)
        for (const b of model.balances.byMember) {
          const accountId = model.members.find((m: Json) => m.memberId === b.memberId).accountId
          assert.equal(b.byCurrency[0]?.minorUnits ?? '0', String(net.get(accountId) ?? 0n), `group ${groupId} member ${accountId}`)
        }
      }
    }
  })

  let revision = 'unknown'
  try {
    revision = execFileSync('git', ['rev-parse', '--short', 'HEAD'], { encoding: 'utf8' }).trim()
    const dirty = execFileSync('git', ['status', '--porcelain', '--', '.'], { encoding: 'utf8' }).trim()
    if (dirty) revision += ' (+ uncommitted changes)'
  } catch { /* not a git checkout */ }
  console.log('# Ledger kernel E2E')
  console.log(`Revision: ${revision}`)
  console.log(`Environment: API ${devApiBase}, database ${new URL(devDatabaseUrl).pathname.slice(1)} on ${new URL(devDatabaseUrl).host}, node ${process.version}`)
  console.log(`Run at: ${new Date().toISOString()}`)
  console.log(`Replay: cd apps/api && DEV_DATABASE_URL=${devDatabaseUrl} DEV_API_BASE=${devApiBase} BILLBANDIT_LEDGER_E2E_SCOPE=${scope} bun run scripts/ledger-kernel-e2e.ts`)
  console.log(`Groups: ${groupsUsed.length} (first ${groupsUsed[0]})`)
  console.log('\n| Step | Check | Result |\n| --- | --- | --- |')
  for (const row of results) console.log(`| ${row.id} | ${row.name} | ${row.result.replaceAll('|', '/').replaceAll('\n', ' ')} |`)
  const failed = results.filter((row) => row.result !== 'PASS').length
  console.log(`\n${results.length - failed} passed, ${failed} failed`)
  if (failed > 0) process.exitCode = 1
}

main().catch((error) => { console.error(error); process.exitCode = 1 }).finally(() => db.$disconnect())
