/**
 * E2E for the identity / friends / CloudKit-import slice.
 *
 * Drives the real HTTP API (dev server) and checks the state-machine
 * properties in docs/state-machines/identity-friends-import.md:
 *   - account deletion never changes other members' balances
 *   - no token works after account deletion; re-sign-in makes a fresh account
 *   - friend codes: self / expired / deleted inviter / re-invite / one row per pair
 *   - the friend-code failure limit cannot be reset or raced past
 *   - first Apple sign-in from two devices at once gives one account
 *   - CloudKit import is idempotent: re-run, resume after a crash, two runs at once
 *
 * Replay (from apps/api, with the dev server running on the same DB/port):
 *   DEV_DATABASE_URL=postgresql://postgres@localhost:5432/billbandit_a3 \
 *   DEV_API_BASE=http://127.0.0.1:3103 bun run scripts/identity-friends-import-e2e.ts
 * The dev server must run with MOBILE_AUTH_MOCK_APPLE_SUBJECT=ifi-e2e-apple-subject
 * (any subject not used by another account) for the Apple steps.
 *
 * Fixture rows (users, CloudKit identities) are written straight to the local
 * database; every behaviour under test goes through HTTP.
 */
import assert from 'node:assert/strict'
import { execSync } from 'node:child_process'
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
const results: { name: string; result: string; evidence: string }[] = []
const run = `${Date.now().toString(36)}${Math.floor(Math.random() * 1e4).toString(36)}`
const money = (n: number) => ({ minorUnits: String(n), currencyCode: 'INR', currencyExponent: 2 })
const appleToken = process.env.MOBILE_AUTH_MOCK_APPLE_TOKEN ?? 'dev-apple-identity-token-local-only'

async function request(token: string | null, path: string, method = 'GET', body?: unknown, headers: Record<string, string> = {}) {
  const response = await fetch(new URL(path, devApiBase), {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), 'Content-Type': 'application/json', ...headers },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })
  const text = await response.text()
  let data: Json = {}
  try { data = JSON.parse(text) } catch { data = { text } }
  return { status: response.status, data }
}

let evidence = ''
async function step(name: string, fn: () => Promise<void>) {
  evidence = ''
  try {
    await fn()
    results.push({ name, result: 'PASS', evidence })
  } catch (error) {
    results.push({ name, result: `FAIL: ${error instanceof Error ? error.message : error}`, evidence })
  }
}
const note = (text: string) => { evidence = evidence ? `${evidence}; ${text}` : text }
const statuses = (list: { status: number }[]) => list.map((r) => r.status).join(',')

let makeToken: (user: User) => string
async function makeUser(label: string): Promise<User & { token: string }> {
  const id = `ifi-${run}-${label}`
  const user = await db.user.create({
    data: { id, email: `${id}@e2e.billbandit.local`, name: label, preferredName: label },
    select: { id: true, email: true, name: true },
  })
  return { ...user, token: makeToken(user) }
}

async function inviteCode(user: { token: string }) {
  const r = await request(user.token, '/api/mobile/friends/invitations', 'POST')
  assert.equal(r.status, 200, JSON.stringify(r.data))
  return r.data.invitation.code as string
}
const claim = (user: { token: string }, code: string) =>
  request(user.token, `/api/mobile/friends/invitations/${encodeURIComponent(code)}/claim`, 'POST')
const pairRows = (a: string, b: string) =>
  db.friendship.count({ where: { OR: [{ fromId: a, toId: b }, { fromId: b, toId: a }] } })

/** A code nobody owns: same alphabet, checked against the table. */
async function unusedCode(seed: number) {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
  for (let n = seed; ; n += 7919) {
    let x = n, code = ''
    for (let i = 0; i < 5; i += 1) { code += alphabet[x % alphabet.length]; x = Math.floor(x / alphabet.length) }
    if (!(await db.friendInvitation.findUnique({ where: { code } }))) return code
  }
}

async function main() {
  ;({ createMobileToken: makeToken } = await import('../lib/mobile-auth'))
  const revision = (() => { try { return execSync('git rev-parse HEAD', { encoding: 'utf8' }).trim() + (execSync('git status --porcelain', { encoding: 'utf8' }).trim() ? '+dirty' : '') } catch { return 'unknown' } })()
  const health = await request(null, '/api/health')

  // Warm up the dev server so the first parallel burst does not race route compilation.
  const warm = await makeUser('warm')
  await request(warm.token, '/api/mobile/auth/me')
  await request(warm.token, '/api/mobile/friends')
  await inviteCode(warm)
  await claim(warm, 'ZZZZZ')
  await request(warm.token, '/api/mobile/migrations/cloudkit')
  await request(null, '/api/mobile/auth/apple', 'POST', { identityToken: 'x'.repeat(30) })

  // ── 1. Account deletion keeps everyone else's money ────────────────────────
  const alice = await makeUser('alice')
  const bob = await makeUser('bob')
  await step('Deletion: friends via code (setup)', async () => {
    const r = await claim(bob, await inviteCode(alice))
    assert.equal(r.status, 201, JSON.stringify(r.data))
  })
  let groupId = ''
  const read = async (token: string) => {
    const r = await request(token, `/api/mobile/ledger/groups/${groupId}`)
    assert.equal(r.status, 200, JSON.stringify(r.data))
    return r.data.data.group as Json
  }
  const balances = (group: Json) => JSON.stringify({
    byMember: group.balances.byMember.map((m: Json) => ({ memberId: m.memberId, byCurrency: m.byCurrency })),
    transfers: group.settlementPlan.transfers.map((t: Json) => ({ from: t.payerMemberId, to: t.recipientMemberId, amount: t.amount.minorUnits })),
  })
  await step('Deletion: a reversed payment stays reversed for the other member', async () => {
    const created = await request(alice.token, '/api/mobile/groups', 'POST', { name: `IFI ${run}`, currency: 'INR', category: 'TRIP', memberAccountIds: [bob.id] }, { 'Idempotency-Key': randomUUID() })
    assert.equal(created.status, 201, JSON.stringify(created.data))
    groupId = created.data.group.id
    let group = await read(alice.token)
    const expenseId = randomUUID()
    const add = await request(alice.token, '/api/mobile/expenses', 'POST', { groupId, operationId: randomUUID(), expectedRevision: group.revision, expenseId, description: 'Dinner', amount: money(10000), currency: 'INR', paidById: alice.id, splitType: 'EQUAL', splits: [alice, bob].map((u, i) => ({ id: `${expenseId}-${i}`, userId: u.id, amount: money(5000) })) })
    assert.equal(add.status, 201, JSON.stringify(add.data))
    group = await read(bob.token)
    const transfer = group.settlementPlan.transfers[0]
    const paid = await request(bob.token, `/api/groups/${groupId}/settlements`, 'POST', { expectedVersion: group.revision, planTransferId: transfer.planTransferId, payerParticipantId: transfer.payerMemberId, recipientParticipantId: transfer.recipientMemberId, currencyCode: 'INR', currencyExponent: 2, minorUnits: '5000' }, { 'Idempotency-Key': randomUUID() })
    assert.equal(paid.status, 201, JSON.stringify(paid.data))
    const settlementId = paid.data.result.transactionId ?? paid.data.result.recordId
    group = await read(bob.token)
    const reversed = await request(bob.token, `/api/groups/${groupId}/settlements/${settlementId}/reversals`, 'POST', { expectedVersion: group.revision }, { 'Idempotency-Key': randomUUID() })
    assert.equal(reversed.status, 201, JSON.stringify(reversed.data))
    const before = balances(await read(bob.token))
    note(`before=${before}`)
    assert.ok(before.includes('"amount":"5000"'), 'bob should owe 50.00 after the reversal')
    const del = await request(alice.token, '/api/mobile/auth/me', 'DELETE')
    assert.equal(del.status, 200, JSON.stringify(del.data))
    const after = balances(await read(bob.token))
    note(`after=${after}`)
    assert.equal(after, before, 'deleting Alice changed Bob\'s balances')
  })
  await step('Deletion: old token refused everywhere', async () => {
    const r = await Promise.all(['/api/mobile/auth/me', '/api/mobile/friends', '/api/mobile/sync-token', '/api/mobile/rewards'].map((p) => request(alice.token, p)))
    note(statuses(r))
    assert.ok(r.every((x) => x.status === 401), statuses(r))
    const invite = await request(alice.token, '/api/mobile/friends/invitations', 'POST')
    assert.equal(invite.status, 401)
  })
  await step('Deletion: friend list and invitation of deleted user are gone', async () => {
    const friends = await request(bob.token, '/api/mobile/friends')
    assert.ok(!friends.data.friends.some((f: Json) => f.id === alice.id))
    assert.equal(await pairRows(alice.id, bob.id), 0)
    assert.equal(await db.friendInvitation.count({ where: { inviterId: alice.id } }), 0)
  })

  // ── 2. Friend invitation state machine ─────────────────────────────────────
  const carol = await makeUser('carol')
  const dave = await makeUser('dave')
  await step('Friends: own code refused (409), no row', async () => {
    const r = await claim(carol, await inviteCode(carol))
    assert.equal(r.status, 409, JSON.stringify(r.data))
    assert.equal(await db.friendship.count({ where: { fromId: carol.id, toId: carol.id } }), 0)
  })
  await step('Friends: expired code refused (410), inviter gets a new code, old code dead', async () => {
    const old = await inviteCode(dave)
    await db.friendInvitation.update({ where: { inviterId: dave.id }, data: { expiresAt: new Date(Date.now() - 1000) } })
    const expired = await claim(carol, old)
    assert.equal(expired.status, 410, JSON.stringify(expired.data))
    const fresh = await inviteCode(dave)
    assert.notEqual(fresh, old)
    const dead = await claim(carol, old)
    note(`old=${old} new=${fresh} oldAfterRotate=${dead.status}`)
    assert.equal(dead.status, 404)
    const ok = await claim(carol, fresh)
    assert.equal(ok.status, 201, JSON.stringify(ok.data))
  })
  await step('Friends: claim again is 200, unfriend, re-claim is 201; one row', async () => {
    const code = await inviteCode(dave)
    assert.equal((await claim(carol, code)).status, 200)
    assert.equal((await request(carol.token, `/api/mobile/friends/${dave.id}`, 'DELETE')).status, 200)
    assert.equal(await pairRows(carol.id, dave.id), 0)
    assert.equal((await claim(carol, code)).status, 201)
    assert.equal(await pairRows(carol.id, dave.id), 1)
  })
  await step('Friends: both people claim each other at the same moment (5 pairs) -> one row each, no 5xx', async () => {
    const pairs = await Promise.all([0, 1, 2, 3, 4].map(async (i) => {
      const left = await makeUser(`pl${i}`); const right = await makeUser(`pr${i}`)
      return { left, right, leftCode: await inviteCode(left), rightCode: await inviteCode(right) }
    }))
    const responses = await Promise.all(pairs.flatMap((p) => [claim(p.left, p.rightCode), claim(p.right, p.leftCode)]))
    const rows = await Promise.all(pairs.map((p) => pairRows(p.left.id, p.right.id)))
    note(`statuses=${statuses(responses)} rows=${rows.join(',')}`)
    assert.ok(responses.every((r) => r.status === 200 || r.status === 201), statuses(responses))
    assert.ok(rows.every((n) => n === 1))
  })
  await step('Friends: two phones of one account claim the same code at once (5 tries) -> no 5xx, one row', async () => {
    const all: { status: number }[] = []
    for (let i = 0; i < 5; i += 1) {
      const inviter = await makeUser(`tp${i}`); const phone = await makeUser(`tq${i}`)
      const code = await inviteCode(inviter)
      const r = await Promise.all([claim(phone, code), claim(phone, code), claim(phone, code)])
      all.push(...r)
      assert.equal(await pairRows(inviter.id, phone.id), 1)
    }
    note(`statuses=${statuses(all)}`)
    assert.ok(all.every((r) => r.status === 200 || r.status === 201), statuses(all))
  })
  await step('Friends: deleted inviter\'s code is refused (404)', async () => {
    const gone = await makeUser('gone')
    const code = await inviteCode(gone)
    assert.equal((await request(gone.token, '/api/mobile/auth/me', 'DELETE')).status, 200)
    const r = await claim(carol, code)
    assert.equal(r.status, 404, JSON.stringify(r.data))
    assert.equal(await pairRows(gone.id, carol.id), 0)
  })

  // ── 3. Friend-code failure limit ───────────────────────────────────────────
  await step('Rate limit: a successful claim does not reset the failure count', async () => {
    const guesser = await makeUser('guesser'); const known = await makeUser('known')
    const knownCode = await inviteCode(known)
    assert.equal((await claim(guesser, knownCode)).status, 201)
    const seen: number[] = []
    for (let i = 0; i < 9; i += 1) seen.push((await claim(guesser, await unusedCode(1000 + i))).status)
    seen.push((await claim(guesser, knownCode)).status) // already friends: success, 200
    seen.push((await claim(guesser, await unusedCode(2000))).status) // 10th failure in the window
    seen.push((await claim(guesser, await unusedCode(2001))).status)
    note(`statuses=${seen.join(',')}`)
    assert.deepEqual(seen.slice(0, 9), Array(9).fill(404))
    assert.equal(seen[9], 200)
    assert.equal(seen[10], 429, 'the 10th wrong code in the window must be blocked')
    assert.equal(seen[11], 429)
  })
  await step('Rate limit: 60 wrong codes in parallel -> at most 10 are looked up', async () => {
    const racer = await makeUser('racer')
    const codes = await Promise.all(Array.from({ length: 60 }, (_, i) => unusedCode(5000 + i * 31)))
    const r = await Promise.all(codes.map((code) => claim(racer, code)))
    const looked = r.filter((x) => x.status === 404).length
    const blocked = r.filter((x) => x.status === 429).length
    note(`404=${looked} 429=${blocked} other=${r.length - looked - blocked}`)
    assert.equal(looked + blocked, r.length, statuses(r))
    assert.ok(looked <= 9, `${looked} wrong codes were looked up before the block (limit 10, the 10th answers 429)`)
  })

  // ── 4. Sign in with Apple ──────────────────────────────────────────────────
  const apple = () => request(null, '/api/mobile/auth/apple', 'POST', { identityToken: appleToken, name: 'Apple E2E' })
  await step('Apple: first sign-in from two devices at once -> one account, no 401 (5 rounds)', async () => {
    const seen: string[] = []
    for (let round = 0; round < 5; round += 1) {
      // Start from "never signed in": delete whatever account the subject has now.
      const current = await apple()
      // Never delete a seeded dev account (dev_you, dev_kabir …). The dev
      // server's default mock Apple subject signs in as dev_you.
      if (current.status === 200 && /^dev_/.test(current.data.user?.username ?? '')) {
        throw new Error('The mock Apple subject belongs to a seeded dev account. Restart the dev server with MOBILE_AUTH_MOCK_APPLE_SUBJECT=ifi-e2e-apple-subject MOBILE_AUTH_MOCK_APPLE_EMAIL=ifi-e2e@dev.billbandit.local')
      }
      if (current.status === 200) assert.equal((await request(current.data.token, '/api/mobile/auth/me', 'DELETE')).status, 200)
      const r = await Promise.all([apple(), apple(), apple()])
      seen.push(statuses(r))
      assert.ok(r.every((x) => x.status === 200), `round ${round}: ${statuses(r)} ${JSON.stringify(r.map((x) => x.data.error ?? ''))}`)
      assert.equal(new Set(r.map((x) => x.data.user.id)).size, 1, `round ${round}: different accounts`)
    }
    note(`rounds=${seen.join(' | ')}`)
  })
  await step('Apple: re-sign-in after deletion gives a fresh account; old token stays dead', async () => {
    const first = await apple()
    assert.equal(first.status, 200, JSON.stringify(first.data))
    const claimName = `ifi${run}`.slice(0, 20)
    assert.equal((await request(first.data.token, '/api/mobile/auth/username', 'POST', { username: claimName })).status, 200)
    assert.equal((await request(first.data.token, '/api/mobile/auth/me', 'DELETE')).status, 200)
    const second = await apple()
    assert.equal(second.status, 200, JSON.stringify(second.data))
    note(`old=${first.data.user.id} new=${second.data.user.id}`)
    assert.notEqual(second.data.user.id, first.data.user.id)
    assert.equal(second.data.user.username ?? null, null)
    assert.equal((await request(first.data.token, '/api/mobile/auth/me')).status, 401)
    assert.equal((await request(second.data.token, '/api/mobile/auth/me')).status, 200)
    // The deleted account's handle is free again.
    assert.equal((await request(second.data.token, '/api/mobile/auth/username', 'POST', { username: claimName })).status, 200)
  })
  await step('Username: two accounts claim one handle at once -> exactly one wins', async () => {
    const a = await makeUser('ua'); const b = await makeUser('ub')
    const handle = `h${run}`.slice(0, 20)
    const r = await Promise.all([a, b].map((u) => request(u.token, '/api/mobile/auth/username', 'POST', { username: handle })))
    note(statuses(r))
    assert.deepEqual(r.map((x) => x.status).sort(), [200, 409])
  })

  // ── 5. CloudKit import ─────────────────────────────────────────────────────
  // One account may hold only one completed CloudKit import (by design), so
  // every CloudKit step gets its own owner and member.
  const ckPair = async (tag: string) => {
    const owner = await makeUser(`cko${tag}`); const member = await makeUser(`ckm${tag}`)
    await db.externalIdentity.createMany({ data: [
      { accountId: owner.id, provider: 'cloudkit', subject: `_ck-${owner.id}` },
      { accountId: member.id, provider: 'cloudkit', subject: `_ck-${member.id}` },
    ] })
    return { owner, member }
  }
  const exportFor = (tag: string, { owner, member }: { owner: User; member: User }) => {
    const zone = { name: `BillBandit.Group.${tag}`, ownerName: '__defaultOwner__' }
    const rec = (recordType: string, recordName: string, fields: Json) => ({ database: 'private', zone, recordType, recordName, fields: { id: recordName, ...fields } })
    const p1 = `${tag}-p1`, p2 = `${tag}-p2`, g = `${tag}-g`
    return {
      source: 'cloudkit',
      sourceKey: `ifi-${tag}`,
      owner: { cloudKitRecordName: `_ck-${owner.id}` },
      defaultCurrency: { currencyCode: 'INR', currencyExponent: 2 },
      claims: [
        { personRecordName: p1, cloudKitRecordName: `_ck-${owner.id}`, accountId: owner.id },
        { personRecordName: p2, cloudKitRecordName: `_ck-${member.id}` },
      ],
      records: [
        rec('BBPerson', p1, { name: 'Owner', cloudUser: `_ck-${owner.id}` }),
        rec('BBPerson', p2, { name: 'Member', cloudUser: `_ck-${member.id}` }),
        rec('BBGroup', g, { name: `CK ${tag}`, currencyCode: 'INR', memberIDs: [p1, p2] }),
        rec('BBExpense', `${tag}-e1`, { groupID: g, title: 'Rent', amount: money(30000), paidByID: p1, splits: [{ id: `${tag}-s1`, personID: p1, amount: money(15000) }, { id: `${tag}-s2`, personID: p2, amount: money(15000) }] }),
        rec('BBExpense', `${tag}-e2`, { groupID: g, title: 'Taxi', amount: money(999), paidByID: p2, splits: [{ id: `${tag}-s3`, personID: p1, amount: money(500) }, { id: `${tag}-s4`, personID: p2, amount: money(499) }] }),
        rec('BBSettlement', `${tag}-t1`, { groupID: g, fromID: p2, toID: p1, amount: money(2000) }),
      ],
    }
  }
  const moneyIn = async (gid: string) => {
    const [expenses, splits, transfers] = await Promise.all([
      db.expense.aggregate({ where: { groupId: gid }, _sum: { amountMinorUnits: true }, _count: true }),
      db.expenseSplit.aggregate({ where: { expense: { groupId: gid } }, _sum: { amountMinorUnits: true }, _count: true }),
      db.transaction.aggregate({ where: { groupId: gid }, _sum: { amountMinorUnits: true }, _count: true }),
    ])
    return `expenses=${expenses._count}/${expenses._sum.amountMinorUnits} splits=${splits._count}/${splits._sum.amountMinorUnits} payments=${transfers._count}/${transfers._sum.amountMinorUnits}`
  }
  const expected = 'expenses=2/30999 splits=4/30999 payments=1/2000'
  const postImport = (owner: { token: string }, exp: unknown, id?: string) => request(owner.token, id ? `/api/mobile/migrations/cloudkit/${id}` : '/api/mobile/migrations/cloudkit', 'POST', exp === undefined ? undefined : { export: exp })
  let importId = ''; let ckGroup = ''
  const ckA = await ckPair('a')
  await step('CloudKit: import completes with exact money', async () => {
    const r = await postImport(ckA.owner, exportFor(`${run}a`, ckA))
    assert.equal(r.status, 200, JSON.stringify(r.data))
    importId = r.data.importId; ckGroup = r.data.serverGroupId
    const m = await moneyIn(ckGroup); note(m)
    assert.equal(m, expected)
  })
  await step('CloudKit: same export again is a no-op (completed, same money)', async () => {
    const r = await postImport(ckA.owner, exportFor(`${run}a`, ckA))
    assert.equal(r.status, 200, JSON.stringify(r.data))
    assert.equal(r.data.importId, importId)
    const m = await moneyIn(ckGroup); note(m)
    assert.equal(m, expected)
  })
  await step('CloudKit: crash mid-import, then resume -> completes once', async () => {
    const ck = await ckPair('b')
    const exp = exportFor(`${run}b`, ck)
    const first = await postImport(ck.owner, exp)
    assert.equal(first.status, 200, JSON.stringify(first.data))
    // Simulate a crash after the expense commit: the import row and the later records go back.
    await db.ledgerImport.update({ where: { id: first.data.importId }, data: { state: 'RUNNING', completedAt: null } })
    await db.ledgerImportRecord.updateMany({ where: { importId: first.data.importId, sourceRecordType: { in: ['settlement', 'activity', 'split'] } }, data: { state: 'PENDING' } })
    const resumed = await postImport(ck.owner, undefined, first.data.importId)
    assert.equal(resumed.status, 200, JSON.stringify(resumed.data))
    const m = await moneyIn(first.data.serverGroupId); note(m)
    assert.equal(m, expected)
  })
  await step('CloudKit: changed pending payment after interruption imports once', async () => {
    const ck = await ckPair('changed-pending')
    const exp = exportFor(`${run}changed-pending`, ck)
    const { normalizeCloudKitExport } = await import('../lib/migrations/cloudkit/normalize')
    const normalized = normalizeCloudKitExport(exp)
    const payment = normalized.records.find((record) => record.recordType === 'settlement')!
    let importId = ''
    await db.$transaction(async (tx) => {
      const lockKey = `cloudkit-import:${ck.owner.id}:${payment.logicalKey}`
      await tx.$queryRaw`SELECT 1 FROM pg_advisory_xact_lock(hashtextextended(${lockKey}, 0))`
      const controller = new AbortController()
      const pending = fetch(new URL('/api/mobile/migrations/cloudkit', devApiBase), {
        method: 'POST', headers: { Authorization: `Bearer ${ck.owner.token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ export: exp }), signal: controller.signal,
      }).catch(() => undefined)
      const deadline = Date.now() + 60000
      let blocked: { pid: number }[] = []
      while (Date.now() < deadline && blocked.length === 0) {
        blocked = await tx.$queryRaw<{ pid: number }[]>`SELECT pid FROM pg_stat_activity WHERE datname = current_database() AND pg_backend_pid() = ANY(pg_blocking_pids(pid))`
        if (!blocked.length) await new Promise((resolve) => setTimeout(resolve, 100))
      }
      assert.equal(blocked.length, 1, 'first upload did not reach the blocked payment')
      const row = await tx.ledgerImport.findUniqueOrThrow({ where: { accountId_sourceSystem_sourceKey: { accountId: ck.owner.id, sourceSystem: 'cloudkit', sourceKey: normalized.sourceKey } } })
      importId = row.id
      setTimeout(() => controller.abort(), 250)
      await pending
      await tx.$queryRaw`SELECT pg_terminate_backend(${blocked[0].pid}::integer)`
    }, { timeout: 90000 })
    const reserved = await db.ledgerImportRecord.findFirstOrThrow({ where: { importId, sourceRecordType: 'settlement' } })
    assert.equal(reserved.state, 'PENDING')
    const changed = structuredClone(exp)
    ;(changed.records.find((record) => record.recordType === 'BBSettlement')!.fields as Json).amount = money(2500)
    const result = await postImport(ck.owner, changed)
    assert.equal(result.status, 200, JSON.stringify(result.data))
    assert.equal(result.data.status, 'completed')
    assert.equal(await moneyIn(result.data.serverGroupId), 'expenses=2/30999 splits=4/30999 payments=1/2500')
    const replay = await postImport(ck.owner, changed)
    assert.equal(replay.status, 200, JSON.stringify(replay.data))
    assert.equal(await moneyIn(result.data.serverGroupId), 'expenses=2/30999 splits=4/30999 payments=1/2500')
  })
  await step('CloudKit: changed export resumes when no record was imported', async () => {
    const ck = await ckPair('changed-before-records')
    const exp = exportFor(`${run}changed-before-records`, ck)
    const { normalizeCloudKitExport } = await import('../lib/migrations/cloudkit/normalize')
    const normalized = normalizeCloudKitExport(exp)
    const row = await db.ledgerImport.create({ data: {
      accountId: ck.owner.id, sourceSystem: 'cloudkit', sourceKey: normalized.sourceKey,
      sourceChecksum: normalized.sourceChecksum, state: 'RUNNING',
    } })
    await db.ledgerImportRecord.createMany({ data: normalized.records.map((record) => ({
      accountId: ck.owner.id, importId: row.id, sourceSystem: 'cloudkit',
      sourceRecordKey: record.logicalKey, sourceRecordType: record.recordType,
      payload: record.fields as Json, payloadChecksum: record.checksum, state: 'PENDING',
    })) })
    const changed = structuredClone(exp)
    ;(changed.records.find((record) => record.recordType === 'BBSettlement')!.fields as Json).amount = money(2500)
    const result = await postImport(ck.owner, changed)
    assert.equal(result.status, 200, JSON.stringify(result.data))
    assert.equal(result.data.status, 'completed')
    assert.equal(await moneyIn(result.data.serverGroupId), 'expenses=2/30999 splits=4/30999 payments=1/2500')
  })
  await step('CloudKit: changed imported expense is reported and not overwritten', async () => {
    const ck = await ckPair('changed-imported')
    const exp = exportFor(`${run}changed-imported`, ck)
    const first = await postImport(ck.owner, exp)
    assert.equal(first.status, 200, JSON.stringify(first.data))
    await db.ledgerImport.update({ where: { id: first.data.importId }, data: { state: 'RUNNING', completedAt: null } })
    const changed = structuredClone(exp)
    ;(changed.records.find((record) => record.recordType === 'BBExpense')!.fields as Json).title = 'Changed after import'
    const result = await postImport(ck.owner, changed)
    assert.equal(result.status, 409, JSON.stringify(result.data))
    assert.equal(result.data.status, 'needs-repair')
    assert.match(result.data.needsRepairReason, /imported CloudKit record changed/)
    assert.equal(await moneyIn(first.data.serverGroupId), expected)
    assert.equal(await db.expense.count({ where: { groupId: first.data.serverGroupId, description: 'Changed after import' } }), 0)
    const changedPayment = structuredClone(exp)
    ;(changedPayment.records.find((record) => record.recordType === 'BBSettlement')!.fields as Json).amount = money(2500)
    const paymentResult = await postImport(ck.owner, changedPayment)
    assert.equal(paymentResult.status, 409, JSON.stringify(paymentResult.data))
    assert.match(paymentResult.data.needsRepairReason, /imported CloudKit record changed/)
    assert.equal(await moneyIn(first.data.serverGroupId), expected)
    const restored = await postImport(ck.owner, exp)
    assert.equal(restored.status, 200, JSON.stringify(restored.data))
    assert.equal(await moneyIn(first.data.serverGroupId), expected)
  })
  await step('CloudKit: three runs of a new export at once -> no 5xx, no double money', async () => {
    const ck = await ckPair('c')
    const exp = exportFor(`${run}c`, ck)
    const r = await Promise.all([postImport(ck.owner, exp), postImport(ck.owner, exp), postImport(ck.owner, exp)])
    note(`statuses=${statuses(r)}`)
    const final = await postImport(ck.owner, exp)
    const m = await moneyIn(final.data.serverGroupId); note(m)
    assert.equal(m, expected)
    assert.ok(r.every((x) => x.status === 200 || x.status === 202), `parallel runs answered ${statuses(r)}`)
    assert.equal(final.status, 200, JSON.stringify(final.data))
  })

  console.log('# identity-friends-import E2E')
  console.log(`revision: ${revision}`)
  console.log(
    `environment: api=${devApiBase} db=${devDatabaseUrl} node=${process.version} health=${health.status} run=${run} at=${new Date().toISOString()}`,
  )
  console.log(
    'replay: cd apps/api && DEV_DATABASE_URL=' +
      devDatabaseUrl +
      ' DEV_API_BASE=' +
      devApiBase +
      ' bun run scripts/identity-friends-import-e2e.ts',
  )
  console.log('| Step | Result | Evidence |\n| --- | --- | --- |')
  for (const row of results) console.log(`| ${row.name} | ${row.result.replaceAll('|', '/').replaceAll('\n', ' ')} | ${row.evidence.replaceAll('|', '/')} |`)
  const failed = results.filter((row) => row.result !== 'PASS').length
  console.log(`\n${results.length - failed}/${results.length} PASS`)
  if (failed) process.exitCode = 1
}
main().catch((error) => { console.error(error); process.exitCode = 1 }).finally(() => db.$disconnect())
