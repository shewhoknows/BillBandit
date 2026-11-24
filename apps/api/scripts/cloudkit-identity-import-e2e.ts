/**
 * E2E: the one-time CloudKit legacy import for real accounts (TestFlight
 * build 35 finding "Old iCloud data not moved").
 *
 * Story. Priya used the old iCloud version of BillBandit. Her iCloud holds two
 * legacy group zones:
 *   - "Goa Trip": Priya, Arjun, Meera, Kabir (four expenses/payments, three
 *     split modes)
 *   - "Flat 4B": Priya, Kabir and Dadi (shares and percent splits, a payment)
 * Arjun is on BillBandit, linked his iCloud from his phone and is Priya's
 * server friend. Meera is on BillBandit and linked, but is not Priya's friend.
 * Kabir never installed the new app. Dadi was typed in by name (no iCloud).
 * The export below is built exactly as the build-35 client builds it
 * (CloudCollaboration.swift makeLegacyRecord / makeClaims / sourceKey).
 *
 * Phases (one script, two servers, one database):
 *   PHASE=stuck  against the OLD server (origin/main before the fix): Priya's
 *                import must answer 409 needs-repair. This is the bug, and
 *                it leaves the real FAILED row that production has today.
 *   PHASE=fix    against the FIXED server: Priya's app resends the same frozen
 *                export and the stuck import completes, plus the identity
 *                safety cases. Without a STATE file from a stuck run, the
 *                stuck row is created as a fixture first.
 *
 * Replay (from apps/api; each server: DEV_DATABASE_URL=<db> DEV_API_BASE=<url> npm run dev:server):
 *   DEV_DATABASE_URL=postgresql://$USER@localhost:5432/bb_cloudkit_identity_e2e \
 *   DEV_API_BASE=http://127.0.0.1:3141 PHASE=stuck npx tsx scripts/cloudkit-identity-import-e2e.ts
 *   DEV_DATABASE_URL=postgresql://$USER@localhost:5432/bb_cloudkit_identity_e2e \
 *   DEV_API_BASE=http://127.0.0.1:3142 PHASE=fix STATE=<artifact dir>/state.json npx tsx scripts/cloudkit-identity-import-e2e.ts
 *
 * Evidence: ARTIFACT_DIR (default <repo>/.scratch/e2e/cloudkit-identity-import/<run>)
 * gets report.md (the table below), evidence.json (every status, money and
 * balance read), legacy-export-priya.json (the exact request body) and
 * state.json (input for the fix phase).
 *
 * Fixture rows (users) are written straight to the local database; every
 * behaviour under test goes through HTTP.
 */
import assert from 'node:assert/strict'
import { execSync } from 'node:child_process'
import { createHash, randomBytes, randomUUID } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { PrismaClient } from '@prisma/client'
import { apiRoot, assertLocalOnly, devApiBase, devDatabaseUrl, devJwtSecret } from './support/dev-env'

assertLocalOnly()
process.env.MOBILE_JWT_SECRET = devJwtSecret
process.env.NEXTAUTH_SECRET = devJwtSecret
process.env.DATABASE_URL = devDatabaseUrl
const db = new PrismaClient({ datasources: { db: { url: devDatabaseUrl } } })
type Json = Record<string, any>
type Person = { key: string; id: string; name: string; cloudUser: string | null }
type Cast = Record<'priya' | 'arjun' | 'meera' | 'kabir' | 'dadi' | 'rohan', Person>
type Account = { id: string; label: string; token: string }

const PHASE = (process.env.PHASE ?? 'fix').toLowerCase()
const statePath = process.env.STATE
const prior = statePath && existsSync(statePath) ? JSON.parse(readFileSync(statePath, 'utf8')) as Json : null
const run: string = prior?.run ?? `${Date.now().toString(36)}${randomBytes(2).toString('hex')}`
const artifactDir = resolve(process.env.ARTIFACT_DIR ?? join(apiRoot, '../../.scratch/e2e/cloudkit-identity-import', run))
mkdirSync(artifactDir, { recursive: true })
const results: { name: string; result: string; evidence: string }[] = []
const evidenceLog: Json = { phase: PHASE, run, steps: {} }

// ── Legacy CloudKit data, in the shape the old app wrote ─────────────────────
const subject = () => `_${randomBytes(16).toString('hex')}`
const uuid = () => randomUUID().toUpperCase()
function makeCast(): Cast {
  const person = (key: string, name: string, cloudUser: string | null): Person => ({ key, id: uuid(), name, cloudUser })
  return {
    priya: person('priya', 'Priya', subject()),
    arjun: person('arjun', 'Arjun', subject()),
    meera: person('meera', 'Meera', subject()),
    kabir: person('kabir', 'Kabir', subject()),
    dadi: person('dadi', 'Dadi', null),
    rohan: person('rohan', 'Rohan', subject()),
  }
}
const cast: Cast = prior?.cast ?? makeCast()
const iso = (daysAgo: number) => new Date(Date.UTC(2026, 3, 1) + daysAgo * 86400000).toISOString().replace('Z', '').padEnd(23, '0') + 'Z'

type LegacyRecord = { database: string; zone: { name: string; ownerName: string }; recordType: string; recordName: string; fields: Json }
type Split = [Person, 'equal' | 'exact' | 'percent' | 'shares', string, string]

/** One legacy zone (BillBandit.Group.<uuid>) with everything the old app wrote into it. */
function legacyZone(spec: {
  groupId: string; name: string; icon: string; createdDaysAgo: number; members: Person[]
  expenses: Array<{ id: string; title: string; amount: string; category: string; payer: Person; splits: Split[]; daysAgo: number }>
  settlements: Array<{ id: string; amount: string; from: Person; to: Person; daysAgo: number }>
}): LegacyRecord[] {
  const zone = { name: `BillBandit.Group.${spec.groupId}`, ownerName: '__defaultOwner__' }
  const rec = (recordType: string, prefix: string, id: string, fields: Json): LegacyRecord => ({ database: 'private', zone, recordType, recordName: `${prefix}-${id}`, fields: { id, ...fields } })
  const activity: LegacyRecord[] = []
  const log = (kind: string, summary: string, actor: Person, refID: string | null, daysAgo: number) => {
    const id = uuid()
    activity.push(rec('BBActivity', 'activity', id, { kind, summary, timestamp: iso(daysAgo), ...(refID ? { refID } : {}), actorID: actor.id, groupID: spec.groupId, groupName: spec.name }))
    return id
  }
  log('groupCreated', `${cast.priya.name} created “${spec.name}”`, cast.priya, null, spec.createdDaysAgo)
  for (const expense of spec.expenses) log('expenseAdded', `${expense.payer.name} added “${expense.title}”`, expense.payer, expense.id, expense.daysAgo)
  for (const payment of spec.settlements) log('settlementRecorded', `${payment.from.name} paid ${payment.to.name}`, payment.from, payment.id, payment.daysAgo)
  return [
    rec('BBGroup', 'group', spec.groupId, {
      name: spec.name, icon: spec.icon, simplifyDebts: true, createdAt: iso(spec.createdDaysAgo),
      memberIDs: spec.members.map((p) => p.id), expenseIDs: spec.expenses.map((e) => e.id),
      settlementIDs: spec.settlements.map((s) => s.id), activityIDs: activity.map((a) => a.fields.id),
    }),
    ...spec.members.map((p) => rec('BBPerson', 'person', p.id, { name: p.name, avatar: `raccoon-${p.key}`, ...(p.cloudUser ? { cloudUser: p.cloudUser } : {}) })),
    ...spec.expenses.map((e) => rec('BBExpense', 'expense', e.id, {
      groupID: spec.groupId, title: e.title, amount: e.amount, date: iso(e.daysAgo), category: e.category, notes: '', paidByID: e.payer.id,
      splits: e.splits.map(([person, modeRaw, valueString, computedAmountString]) => ({ personID: person.id, modeRaw, valueString, computedAmountString })),
    })),
    ...spec.settlements.map((s) => rec('BBSettlement', 'settlement', s.id, { groupID: spec.groupId, amount: s.amount, date: iso(s.daysAgo), fromID: s.from.id, toID: s.to.id })),
    ...activity,
  ]
}

/** CloudCollaboration.swift: makeClaims, sourceKey, record order. */
function clientExport(owner: Person, ownerAccountId: string, records: LegacyRecord[]): Json {
  const line = (r: LegacyRecord) => `${r.database}|${r.zone.name}|${r.zone.ownerName}|${r.recordType}|${r.recordName}`
  const sourceKey = `billbandit-cloudkit-${createHash('sha256').update(records.map(line).sort().join('\n')).digest('hex').slice(0, 48)}`
  const claims = records.filter((r) => r.recordType === 'BBPerson').flatMap((r) => {
    const cloudUser: string | undefined = r.fields.cloudUser
    const isOwner = cloudUser === owner.cloudUser || r.fields.id === owner.id
    if (!isOwner && !cloudUser) return []
    return [{ personRecordName: r.fields.id, cloudKitRecordName: cloudUser ?? owner.cloudUser, ...(isOwner ? { accountId: ownerAccountId } : {}) }]
  }).sort((a, b) => a.personRecordName.localeCompare(b.personRecordName))
  const sorted = [...records].sort((a, b) => {
    const left = `${a.database}|${a.zone.name}|${a.recordType}|${a.recordName}`
    const right = `${b.database}|${b.zone.name}|${b.recordType}|${b.recordName}`
    return left < right ? -1 : left > right ? 1 : 0
  })
  return { source: 'cloudkit', sourceKey, owner: { cloudKitRecordName: owner.cloudUser }, defaultCurrency: { currencyCode: 'INR', currencyExponent: 2 }, claims, records: sorted }
}

const { priya: P, arjun: A, meera: M, kabir: K, dadi: D, rohan: R } = cast
const ids: Json = prior?.ids ?? { goa: uuid(), flat: uuid(), weekend: uuid(), e: Array.from({ length: 8 }, uuid) }
function priyaRecords(): LegacyRecord[] {
  return [
    ...legacyZone({
      groupId: ids.goa, name: 'Goa Trip', icon: 'airplane', createdDaysAgo: 0, members: [P, A, M, K],
      expenses: [
        // ₹24,000 villa, equal four ways.
        { id: ids.e[0], title: 'Villa', amount: '24000', category: 'stay', payer: P, daysAgo: 1, splits: [[P, 'equal', '0', '6000'], [A, 'equal', '0', '6000'], [M, 'equal', '0', '6000'], [K, 'equal', '0', '6000']] },
        // ₹1,000 scooters, equal three ways; the spare rupee goes to the first member.
        { id: ids.e[1], title: 'Scooters', amount: '1000', category: 'travel', payer: A, daysAgo: 2, splits: [[P, 'equal', '0', '334'], [A, 'equal', '0', '333'], [K, 'equal', '0', '333']] },
        // ₹3,250 dinner, exact amounts.
        { id: ids.e[2], title: 'Beach dinner', amount: '3250', category: 'food', payer: M, daysAgo: 3, splits: [[P, 'exact', '1000', '1000'], [A, 'exact', '750', '750'], [M, 'exact', '750', '750'], [K, 'exact', '750', '750']] },
      ],
      settlements: [{ id: ids.e[3], amount: '2000', from: K, to: P, daysAgo: 5 }],
    }),
    ...legacyZone({
      groupId: ids.flat, name: 'Flat 4B', icon: 'house', createdDaysAgo: 10, members: [P, K, D],
      expenses: [
        // ₹30,000 rent by shares 2:1:1.
        { id: ids.e[4], title: 'April rent', amount: '30000', category: 'rent', payer: P, daysAgo: 11, splits: [[P, 'shares', '2', '15000'], [K, 'shares', '1', '7500'], [D, 'shares', '1', '7500']] },
        // ₹1,200 groceries by percent 50/25/25, paid by Dadi.
        { id: ids.e[5], title: 'Groceries', amount: '1200', category: 'groceries', payer: D, daysAgo: 12, splits: [[P, 'percent', '50', '600'], [K, 'percent', '25', '300'], [D, 'percent', '25', '300']] },
      ],
      settlements: [{ id: ids.e[6], amount: '5000', from: K, to: P, daysAgo: 13 }],
    }),
  ]
}
function rohanRecords(): LegacyRecord[] {
  return legacyZone({
    groupId: ids.weekend, name: 'Weekend', icon: 'tent', createdDaysAgo: 20, members: [R, M],
    expenses: [{ id: ids.e[7], title: 'Cabin', amount: '4000', category: 'stay', payer: R, daysAgo: 21, splits: [[R, 'equal', '0', '2000'], [M, 'equal', '0', '2000']] }],
    settlements: [],
  }).map((record) => record.recordType === 'BBActivity' ? { ...record, fields: { ...record.fields, summary: String(record.fields.summary).replace('Priya', 'Rohan'), actorID: record.fields.actorID === P.id ? R.id : record.fields.actorID } } : record)
}

// Hand-computed from the story (paise; positive = is owed). See the comments above.
const EXPECTED = {
  goa: { money: 'expenses=3/2825000 splits=11/2825000 payments=1/200000', balances: { Priya: 1466600, Arjun: -608300, Meera: -350000, Kabir: -508300 } },
  flat: { money: 'expenses=2/3120000 splits=6/3120000 payments=1/500000', balances: { Priya: 940000, Kabir: -280000, Dadi: -660000 } },
  weekend: { money: 'expenses=1/400000 splits=2/400000 payments=0/null' },
}

// ── HTTP and evidence helpers ───────────────────────────────────────────────
async function request(token: string | null, path: string, method = 'GET', body?: unknown, signal?: AbortSignal) {
  const response = await fetch(new URL(path, devApiBase), {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), 'Content-Type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    signal,
  })
  const text = await response.text()
  let data: Json = {}
  try { data = JSON.parse(text) } catch { data = { text } }
  return { status: response.status, data }
}
let evidence = ''
let stepName = ''
async function step(name: string, fn: () => Promise<void>) {
  evidence = ''
  stepName = name
  evidenceLog.steps[name] = {}
  try {
    await fn()
    results.push({ name, result: 'PASS', evidence })
  } catch (error) {
    results.push({ name, result: `FAIL: ${error instanceof Error ? error.message : error}`, evidence })
  }
}
const note = (text: string) => { evidence = evidence ? `${evidence}; ${text}` : text }
const keep = (key: string, value: unknown) => { evidenceLog.steps[stepName][key] = value }
const statuses = (list: { status: number }[]) => list.map((r) => r.status).join(',')
const postImport = (owner: Account, body: unknown, importId?: string, signal?: AbortSignal) =>
  request(owner.token, importId ? `/api/mobile/migrations/cloudkit/${importId}` : '/api/mobile/migrations/cloudkit', 'POST', { export: body }, signal)
const link = (account: Account, cloudKitRecordName: string | null) =>
  request(account.token, '/api/mobile/migrations/cloudkit/identity', 'POST', { cloudKitRecordName })

let makeToken: (user: { id: string; email: string; name: string | null }) => string
async function account(label: string): Promise<Account> {
  const id = `ckid-${run}-${label}`
  const user = await db.user.upsert({
    where: { id },
    create: { id, email: `${id}@e2e.billbandit.local`, name: label, preferredName: label },
    update: {},
    select: { id: true, email: true, name: true },
  })
  return { id: user.id, label, token: makeToken(user) }
}
async function befriend(a: Account, b: Account) {
  const invite = await request(a.token, '/api/mobile/friends/invitations', 'POST')
  assert.equal(invite.status, 200, JSON.stringify(invite.data))
  const claim = await request(b.token, `/api/mobile/friends/invitations/${encodeURIComponent(invite.data.invitation.code)}/claim`, 'POST')
  assert.ok(claim.status === 201 || claim.status === 200, JSON.stringify(claim.data))
}
async function moneyIn(groupId: string) {
  const [expenses, splits, transfers] = await Promise.all([
    db.expense.aggregate({ where: { groupId }, _sum: { amountMinorUnits: true }, _count: true }),
    db.expenseSplit.aggregate({ where: { expense: { groupId } }, _sum: { amountMinorUnits: true }, _count: true }),
    db.transaction.aggregate({ where: { groupId }, _sum: { amountMinorUnits: true }, _count: true }),
  ])
  return `expenses=${expenses._count}/${expenses._sum.amountMinorUnits} splits=${splits._count}/${splits._sum.amountMinorUnits} payments=${transfers._count}/${transfers._sum.amountMinorUnits}`
}
async function readGroup(viewer: Account, groupId: string) {
  return request(viewer.token, `/api/mobile/ledger/groups/${groupId}`)
}
/** Net balance per member, labelled by who the member is (real account label, else display name). */
function balancesByName(group: Json, labels: Record<string, string>) {
  const memberName = new Map<string, string>(group.members.map((m: Json) => [m.memberId, labels[m.accountId] ?? m.displayName]))
  const out: Record<string, number> = {}
  for (const row of group.balances.byMember) {
    const inr = row.byCurrency.find((c: Json) => c.currencyCode === 'INR')
    out[memberName.get(row.memberId) ?? row.memberId] = Number(inr?.minorUnits ?? 0)
  }
  return out
}
async function isPlaceholder(accountId: string) {
  const user = await db.user.findUnique({ where: { id: accountId }, select: { password: true, username: true, phone: true, accounts: { select: { id: true } }, sessions: { select: { id: true } }, externalIdentities: { select: { provider: true } } } })
  return !!user && user.password === null && user.username === null && user.phone === null && user.accounts.length === 0 && user.sessions.length === 0 &&
    user.externalIdentities.length === 1 && user.externalIdentities[0].provider === 'cloudkit-legacy-person'
}
const cloudkitLink = (subjectName: string) => db.externalIdentity.findUnique({ where: { provider_subject: { provider: 'cloudkit', subject: subjectName } }, select: { accountId: true } })

async function main() {
  ;({ createMobileToken: makeToken } = await import('../lib/mobile-auth'))
  const revision = (() => { try { return execSync('git rev-parse HEAD', { encoding: 'utf8' }).trim() + (execSync('git status --porcelain', { encoding: 'utf8' }).trim() ? '+dirty' : '') } catch { return 'unknown' } })()
  const health = await request(null, '/api/health')

  const priya = await account('priya'); const arjun = await account('arjun'); const meera = await account('meera')
  const mallory = await account('mallory'); const rohan = await account('rohan'); const sam = await account('sam')
  const labels: Record<string, string> = { [priya.id]: 'Priya', [arjun.id]: 'Arjun', [meera.id]: 'Meera', [rohan.id]: 'Rohan' }
  const priyaExport = clientExport(P, priya.id, priyaRecords())
  writeFileSync(join(artifactDir, 'legacy-export-priya.json'), JSON.stringify({ export: priyaExport }, null, 2))
  evidenceLog.export = { sourceKey: priyaExport.sourceKey, records: priyaExport.records.length, claims: priyaExport.claims.length }
  // Warm up route compilation so later parallel steps measure the server, not the compiler.
  await request(priya.token, '/api/mobile/migrations/cloudkit')
  await request(priya.token, '/api/mobile/auth/me')

  if (PHASE === 'stuck') {
    await step('Build 35: Priya\'s first import -> 409 needs-repair ("Old iCloud data not moved")', async () => {
      const r = await postImport(priya, priyaExport)
      keep('response', r)
      note(`status=${r.status} code=${r.data.code ?? r.data.status} reason=${r.data.needsRepairReason ?? r.data.error}`)
      assert.equal(r.status, 409)
      const row = await db.ledgerImport.findFirst({ where: { accountId: priya.id, sourceSystem: 'cloudkit' }, select: { id: true, state: true, failureReason: true } })
      keep('row', row)
      note(`row=${row?.state} records=${row ? await db.ledgerImportRecord.count({ where: { importId: row.id } }) : 0}`)
      assert.equal(row?.state, 'FAILED')
    })
    writeFileSync(join(artifactDir, 'state.json'), JSON.stringify({ run, cast, ids }, null, 2))
  } else {
    // Without a stuck run against the old server, make the row the old server leaves.
    if (!prior) {
      const { normalizeCloudKitExport } = await import('../lib/migrations/cloudkit/normalize')
      const normalized = normalizeCloudKitExport(priyaExport)
      await db.ledgerImport.create({ data: {
        accountId: priya.id, sourceSystem: 'cloudkit', sourceKey: normalized.sourceKey, sourceChecksum: normalized.sourceChecksum,
        state: 'FAILED', failureReason: `CloudKit identity ${P.cloudUser} is not linked to an API account`,
      } })
    }

    await step('Setup: Arjun is Priya\'s server friend; Meera and Rohan are not', async () => {
      await befriend(priya, arjun)
      const pair = [priya.id, arjun.id].sort()
      assert.equal((await db.friendship.findUnique({ where: { fromId_toId: { fromId: pair[0], toId: pair[1] } } }))?.status, 'ACCEPTED')
    })
    await step('Device link: Arjun and Meera link their own iCloud from their phones; repeat is a no-op', async () => {
      const r = [await link(arjun, A.cloudUser), await link(meera, M.cloudUser), await link(arjun, A.cloudUser)]
      keep('responses', r)
      note(`${statuses(r)} ${r.map((x) => x.data.status).join(',')}`)
      assert.deepEqual(r.map((x) => x.data.status), ['linked', 'linked', 'already_linked'])
      assert.equal((await cloudkitLink(A.cloudUser!))?.accountId, arjun.id)
    })
    await step('Device link: a second account cannot take Arjun\'s iCloud identity; bad input is 400', async () => {
      const squat = await link(mallory, A.cloudUser)
      const second = await link(arjun, subject())
      const bad = await link(mallory, '  ')
      keep('responses', { squat, second, bad })
      note(`squat=${squat.status}/${squat.data.code} secondSubject=${second.status}/${second.data.code} blank=${bad.status}`)
      assert.equal(squat.status, 409); assert.equal(squat.data.code, 'identity_conflict')
      assert.equal(second.status, 409); assert.equal(second.data.code, 'identity_conflict')
      assert.equal(bad.status, 400)
      assert.equal((await cloudkitLink(A.cloudUser!))?.accountId, arjun.id)
      assert.equal(await db.externalIdentity.count({ where: { accountId: mallory.id } }), 0)
    })

    let importId = ''; let goaId = ''; let flatId = ''
    await step('Stuck account: Priya\'s build-35 import is listed as needs-repair before the retry', async () => {
      const list = await request(priya.token, '/api/mobile/migrations/cloudkit')
      const stuck = (list.data.imports ?? []) as Json[]
      keep('list', list)
      note(`imports=${stuck.map((i) => `${i.status}:${i.needsRepairReason}`).join(',')}`)
      assert.equal(stuck.length, 1)
      assert.equal(stuck[0].status, 'needs-repair')
      importId = stuck[0].importId
    })
    await step('Recovery: the app resends the same frozen export -> 200 completed on the same import', async () => {
      const r = await postImport(priya, priyaExport)
      keep('response', r)
      note(`status=${r.status} importId=${r.data.importId === importId ? 'same' : r.data.importId} counts=${JSON.stringify(r.data.counts)}`)
      assert.equal(r.status, 200, JSON.stringify(r.data))
      assert.equal(r.data.status, 'completed')
      assert.equal(r.data.importId, importId)
      assert.equal(r.data.serverGroupIds.length, 2)
      assert.equal(r.data.migrationMarkers.length, 2)
      const byName = new Map<string, string>()
      for (const groupId of r.data.serverGroupIds as string[]) byName.set((await db.group.findUniqueOrThrow({ where: { id: groupId } })).name, groupId)
      goaId = byName.get('Goa Trip')!; flatId = byName.get('Flat 4B')!
      assert.ok(goaId && flatId)
      assert.equal((await cloudkitLink(P.cloudUser!))?.accountId, priya.id, 'Priya\'s own iCloud identity is linked by her import')
    })
    await step('Money: every rupee imported exactly once in both groups', async () => {
      const goa = await moneyIn(goaId); const flat = await moneyIn(flatId)
      keep('money', { goa, flat })
      note(`goa ${goa}; flat ${flat}`)
      assert.equal(goa, EXPECTED.goa.money)
      assert.equal(flat, EXPECTED.flat.money)
    })
    await step('Balances: Priya\'s app shows the hand-computed balances for all five people', async () => {
      const goa = await readGroup(priya, goaId); const flat = await readGroup(priya, flatId)
      assert.equal(goa.status, 200, JSON.stringify(goa.data)); assert.equal(flat.status, 200, JSON.stringify(flat.data))
      const goaBalances = balancesByName(goa.data.data.group, labels)
      const flatBalances = balancesByName(flat.data.data.group, labels)
      keep('balances', { goa: goaBalances, flat: flatBalances, goaTransfers: goa.data.data.group.settlementPlan?.transfers })
      note(`goa=${JSON.stringify(goaBalances)} flat=${JSON.stringify(flatBalances)}`)
      assert.deepEqual(goaBalances, EXPECTED.goa.balances)
      assert.deepEqual(flatBalances, EXPECTED.flat.balances)
    })
    await step('Friends: Arjun (linked + friend) is a real member and sees Goa; Meera (linked, not friend) does not', async () => {
      const goaMembers = await db.groupMember.findMany({ where: { groupId: goaId }, select: { userId: true, role: true } })
      keep('goaMembers', goaMembers)
      const arjunView = await readGroup(arjun, goaId)
      const meeraView = await readGroup(meera, goaId)
      note(`members=${goaMembers.length} arjunGET=${arjunView.status} meeraGET=${meeraView.status}`)
      assert.ok(goaMembers.some((m) => m.userId === priya.id && m.role === 'ADMIN'))
      assert.ok(goaMembers.some((m) => m.userId === arjun.id))
      assert.ok(!goaMembers.some((m) => m.userId === meera.id))
      assert.equal(arjunView.status, 200)
      assert.equal(balancesByName(arjunView.data.data.group, labels).Arjun, EXPECTED.goa.balances.Arjun)
      assert.ok(meeraView.status === 403 || meeraView.status === 404, `Meera read Goa: ${meeraView.status}`)
    })
    await step('Placeholders: Meera, Kabir and Dadi are sign-in-less placeholders; Kabir is one member across both groups', async () => {
      const members = await db.groupParticipant.findMany({ where: { groupId: { in: [goaId, flatId] } }, select: { groupId: true, userId: true, displayName: true } })
      const others = members.filter((m) => m.userId !== priya.id && m.userId !== arjun.id)
      keep('placeholders', others)
      const kabir = others.filter((m) => m.displayName === 'Kabir')
      note(`placeholders=${others.map((m) => m.displayName).sort().join(',')} kabirAccounts=${new Set(kabir.map((m) => m.userId)).size}`)
      assert.deepEqual(others.map((m) => m.displayName).sort(), ['Dadi', 'Kabir', 'Kabir', 'Meera'])
      assert.equal(kabir.length, 2); assert.equal(new Set(kabir.map((m) => m.userId)).size, 1)
      for (const m of others) assert.ok(await isPlaceholder(m.userId), `${m.displayName} is not a sign-in-less placeholder`)
    })
    await step('Replay: same export again and three at once -> 200, no 5xx, money unchanged', async () => {
      const again = await postImport(priya, priyaExport)
      const parallel = await Promise.all([postImport(priya, priyaExport), postImport(priya, priyaExport), postImport(priya, priyaExport)])
      const goa = await moneyIn(goaId); const flat = await moneyIn(flatId)
      keep('statuses', { again: again.status, parallel: parallel.map((r) => r.status) })
      note(`again=${again.status} parallel=${statuses(parallel)} goa ${goa}`)
      assert.equal(again.status, 200)
      assert.ok(parallel.every((r) => r.status === 200), statuses(parallel))
      assert.equal(goa, EXPECTED.goa.money); assert.equal(flat, EXPECTED.flat.money)
      assert.equal(await db.user.count({ where: { externalIdentities: { some: { provider: 'cloudkit-legacy-person', subject: { startsWith: `${priya.id}:` } } } } }), 3)
    })
    await step('Frozen: completed import refuses a different export (409 completed_import_frozen)', async () => {
      const changed = structuredClone(priyaExport)
      changed.records.find((r: Json) => r.recordType === 'BBExpense').fields.title = 'Edited after import'
      const r = await postImport(priya, changed)
      keep('response', r)
      note(`status=${r.status} code=${r.data.code}`)
      assert.equal(r.status, 409); assert.equal(r.data.code, 'completed_import_frozen')
      assert.equal(await moneyIn(goaId), EXPECTED.goa.money)
    })
    await step('Conflict: another account sending Priya\'s iCloud export is refused; nothing imported', async () => {
      const stolen = clientExport(P, mallory.id, priyaRecords())
      const r = await postImport(mallory, stolen)
      keep('response', r)
      note(`status=${r.status} state=${r.data.status} reason=${r.data.needsRepairReason}`)
      assert.equal(r.status, 409); assert.equal(r.data.status, 'needs-repair')
      assert.match(r.data.needsRepairReason, /already linked to another BillBandit account/)
      assert.equal(await db.groupMember.count({ where: { userId: mallory.id } }), 0)
      assert.equal((await cloudkitLink(P.cloudUser!))?.accountId, priya.id)
    })
    await step('Conflict: an account linked to one iCloud cannot import another iCloud\'s export', async () => {
      const own = subject(); const other: Person = { key: 'sam', id: uuid(), name: 'Sam', cloudUser: subject() }
      const linked = await link(sam, own)
      const zone = legacyZone({ groupId: uuid(), name: 'Solo', icon: 'star', createdDaysAgo: 30, members: [other], expenses: [{ id: uuid(), title: 'Lunch', amount: '300', category: 'food', payer: other, daysAgo: 30, splits: [[other, 'equal', '0', '300']] }], settlements: [] })
      const r = await postImport(sam, clientExport(other, sam.id, zone))
      keep('responses', { linked, r })
      note(`link=${linked.data.status} import=${r.status}/${r.data.status} reason=${r.data.needsRepairReason}`)
      assert.equal(linked.data.status, 'linked')
      assert.equal(r.status, 409); assert.match(r.data.needsRepairReason, /already linked to a different iCloud account/)
      assert.equal(await db.groupMember.count({ where: { userId: sam.id } }), 0)
    })
    await step('Crash between people and money: a friendship made mid-import does not move Meera; resume completes once', async () => {
      const exp = clientExport(R, rohan.id, rohanRecords())
      const { normalizeCloudKitExport } = await import('../lib/migrations/cloudkit/normalize')
      const group = normalizeCloudKitExport(exp).records.find((record) => record.recordType === 'group')!
      let blockedAt = ''
      await db.$transaction(async (tx) => {
        // Hold the group record's lock: the run commits all people (phase 1), then waits here.
        await tx.$queryRaw`SELECT 1 FROM pg_advisory_xact_lock(hashtextextended(${`cloudkit-import:${rohan.id}:${group.logicalKey}`}, 0))`
        const controller = new AbortController()
        const pending = postImport(rohan, exp, undefined, controller.signal).catch(() => undefined)
        let blocked: { pid: number }[] = []
        for (const deadline = Date.now() + 60000; Date.now() < deadline && blocked.length === 0;) {
          blocked = await tx.$queryRaw<{ pid: number }[]>`SELECT pid FROM pg_stat_activity WHERE datname = current_database() AND pg_backend_pid() = ANY(pg_blocking_pids(pid))`
          if (!blocked.length) await new Promise((r) => setTimeout(r, 100))
        }
        assert.equal(blocked.length, 1, 'the import did not reach the group record')
        const people = await tx.ledgerImportRecord.findMany({ where: { accountId: rohan.id, sourceRecordType: 'person' }, select: { state: true, targetId: true } })
        blockedAt = people.map((p) => p.state).join(',')
        // Rohan and Meera become friends while the import is stuck in phase 2 (separate connection).
        await befriend(rohan, meera)
        setTimeout(() => controller.abort(), 250)
        await pending
        await tx.$queryRaw`SELECT pg_terminate_backend(${blocked[0].pid}::integer)`
      }, { timeout: 90000 })
      const resumed = await postImport(rohan, exp)
      keep('resumed', resumed)
      const weekendId = resumed.data.serverGroupId
      const members = await db.groupMember.findMany({ where: { groupId: weekendId }, select: { userId: true } })
      const meeraPlaceholder = members.find((m) => m.userId !== rohan.id)
      const money = await moneyIn(weekendId)
      keep('after', { blockedAt, members, money })
      note(`peopleAtCrash=${blockedAt} resume=${resumed.status}/${resumed.data.status} meeraMember=${meeraPlaceholder?.userId === meera.id ? 'real-account' : 'placeholder'} ${money}`)
      assert.equal(blockedAt, 'IMPORTED,IMPORTED')
      assert.equal(resumed.status, 200, JSON.stringify(resumed.data))
      assert.equal(money, EXPECTED.weekend.money)
      assert.ok(meeraPlaceholder && meeraPlaceholder.userId !== meera.id && await isPlaceholder(meeraPlaceholder.userId), 'Meera was re-resolved after people were frozen')
      assert.equal(await db.expenseSplit.count({ where: { expense: { groupId: weekendId }, userId: meera.id } }), 0)
    })
  }

  const header = [
    `# CloudKit identity import E2E (phase ${PHASE})`,
    `revision: ${revision}`,
    `environment: api=${devApiBase} db=${devDatabaseUrl} node=${process.version} health=${health.status} run=${run} at=${new Date().toISOString()}`,
    `artifacts: ${artifactDir}`,
    `replay: cd apps/api && DEV_DATABASE_URL=${devDatabaseUrl} DEV_API_BASE=${devApiBase} PHASE=${PHASE}${statePath ? ` STATE=${statePath}` : ''} npx tsx scripts/cloudkit-identity-import-e2e.ts`,
    '',
    '| Step | Result | Evidence |',
    '| --- | --- | --- |',
  ]
  const rows = results.map((row) => `| ${row.name} | ${row.result.replaceAll('|', '/').replaceAll('\n', ' ')} | ${row.evidence.replaceAll('|', '/')} |`)
  const failed = results.filter((row) => row.result !== 'PASS').length
  const report = [...header, ...rows, '', `${results.length - failed}/${results.length} PASS`].join('\n')
  console.log(report)
  writeFileSync(join(artifactDir, `report-${PHASE}.md`), `${report}\n`)
  writeFileSync(join(artifactDir, `evidence-${PHASE}.json`), JSON.stringify(evidenceLog, (_k, v) => typeof v === 'bigint' ? v.toString() : v, 2))
  mkdirSync(dirname(join(artifactDir, 'x')), { recursive: true })
  if (failed) process.exitCode = 1
}
main().catch((error) => { console.error(error); process.exitCode = 1 }).finally(() => db.$disconnect())
