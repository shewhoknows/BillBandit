/*
 * App Store polish end-to-end check, over real HTTP.
 *
 * Seeds a Goa trip crew (five people, paise that do not divide evenly), an SGD
 * group, an AED group, a VND group, a one-person group and a few groups used
 * only to test leave and delete rules. Then it drives the real Next.js mobile
 * routes and checks every server change this release depends on:
 *
 * - SGD and AED are registered currencies.
 * - A person's default currency is stored, validated and returned.
 * - Exchange rates come back for that default, in both directions.
 * - The account summary carries members, roles, totals and newest-first order.
 * - Activity pages by cursor with no gaps and no repeats.
 * - Expense notes, category and date read back exactly.
 * - A partial payment lowers the plan; an overpayment is refused.
 * - Leave and delete explain every refusal in plain words.
 * - A one-person group has a real zero balance.
 * - Avatars chosen by one person reach everyone in their groups.
 *
 * Set START_POLISH_SERVER=1 to start Next on port 31401 and leave it running
 * for simulator QA. The session for the simulator is written to
 * .scratch/polish-e2e/qa-session.json (chmod 600).
 */
import assert from 'node:assert/strict'
import { execFileSync, spawn, type ChildProcess } from 'node:child_process'
import { chmodSync, closeSync, mkdirSync, openSync, readFileSync, watch, writeFileSync } from 'node:fs'
import { randomBytes, randomUUID } from 'node:crypto'
import { createConnection } from 'node:net'
import { dirname, resolve } from 'node:path'

import { Prisma } from '@prisma/client'

import { createLedgerTestDatabase } from '../test/integration/ledger-harness'
import { frankfurterFetcher, refreshExchangeRates, supportedRateCurrencies } from '../lib/rates/exchange-rates'

const repositoryRoot = resolve(dirname(new URL(import.meta.url).pathname), '../..', '..')
const apiRoot = resolve(repositoryRoot, 'apps/api')
const evidenceRoot = process.env.POLISH_E2E_EVIDENCE_DIR?.trim() || resolve(repositoryRoot, '.scratch/polish-e2e')
const port = Number(process.env.POLISH_E2E_PORT ?? 31401)
const baseURL = `http://127.0.0.1:${port}`
const startServer = process.env.START_POLISH_SERVER === '1'
const suffix = `${Date.now().toString(36)}_${randomBytes(3).toString('hex')}`
const handleSuffix = randomBytes(2).toString('hex')
const mobileSecret = `polish-e2e-${randomBytes(32).toString('hex')}`

type Json = Record<string, any>
type HttpResult = { status: number; body: any }
type Check = { name: string; ok: boolean; detail?: string }

const checks: Check[] = []
const samples: Record<string, unknown> = {}

function redact(value: unknown): string {
  const text = typeof value === 'string' ? value : JSON.stringify(value)
  return text.replace(/Bearer\s+[A-Za-z0-9._-]+/gi, 'Bearer [redacted]').slice(0, 1_200)
}

async function request(
  path: string,
  options: { token?: string; method?: string; body?: unknown; headers?: Record<string, string> } = {}
): Promise<HttpResult> {
  const headers = new Headers(options.headers)
  headers.set('Accept', 'application/json')
  if (options.token) headers.set('Authorization', `Bearer ${options.token}`)
  if (options.body !== undefined) headers.set('Content-Type', 'application/json')
  const response = await fetch(new URL(path, baseURL), {
    method: options.method ?? (options.body === undefined ? 'GET' : 'POST'),
    headers,
    body: options.body === undefined ? undefined : JSON.stringify(options.body),
  })
  const text = await response.text()
  let body: unknown = null
  try { body = text ? JSON.parse(text) : null } catch { body = text }
  return { status: response.status, body }
}

function expect(result: HttpResult, status: number, label: string): Json {
  if (result.status !== status) throw new Error(`${label}: expected ${status}, got ${result.status}: ${redact(result.body)}`)
  return result.body as Json
}

async function step(name: string, fn: () => Promise<void> | void) {
  try {
    await fn()
    checks.push({ name, ok: true })
  } catch (error) {
    checks.push({ name, ok: false, detail: redact(error instanceof Error ? error.message : error) })
    throw error
  }
}

function mobileToken(user: { id: string; email: string; name: string }): string {
  const helper = [
    "import { createMobileToken } from './lib/mobile-auth.ts'",
    "const user = JSON.parse(process.env.POLISH_USER ?? '{}')",
    'process.stdout.write(createMobileToken(user))',
  ].join(';')
  return execFileSync(process.execPath, ['--import', 'tsx', '--eval', helper], {
    cwd: apiRoot,
    env: {
      ...process.env,
      TSX_TSCONFIG_PATH: resolve(apiRoot, 'tsconfig.json'),
      POLISH_USER: JSON.stringify(user),
      MOBILE_JWT_SECRET: mobileSecret,
      NEXTAUTH_SECRET: mobileSecret,
    },
    encoding: 'utf8',
  }).trim()
}

function portIsOccupied(value: number): Promise<boolean> {
  return new Promise((done) => {
    const socket = createConnection({ host: '127.0.0.1', port: value })
    socket.once('connect', () => { socket.destroy(); done(true) })
    socket.once('error', () => { socket.destroy(); done(false) })
  })
}

async function startNext(databaseURL: string): Promise<ChildProcess> {
  const out = resolve(evidenceRoot, 'next-stdout.log')
  const err = resolve(evidenceRoot, 'next-stderr.log')
  writeFileSync(out, '', { mode: 0o600 })
  writeFileSync(err, '', { mode: 0o600 })
  const outFd = openSync(out, 'a', 0o600)
  const errFd = openSync(err, 'a', 0o600)
  const server = spawn('npm', ['--workspace', 'apps/api', 'run', 'dev', '--', '-p', String(port), '-H', '0.0.0.0'], {
    cwd: repositoryRoot,
    env: { ...process.env, DATABASE_URL: databaseURL, MOBILE_JWT_SECRET: mobileSecret, NEXTAUTH_SECRET: mobileSecret, NODE_ENV: 'development' },
    detached: true,
    stdio: ['ignore', outFd, errFd],
  })
  closeSync(outFd)
  closeSync(errFd)
  server.unref()
  await new Promise<void>((done, fail) => {
    let settled = false
    const finish = (error?: Error) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      watchers.forEach((entry) => entry.close())
      error ? fail(error) : done()
    }
    const timer = setTimeout(() => finish(new Error('Next did not start within 120 seconds')), 120_000)
    const watchers = [out, err].map((path) => watch(path, { persistent: false }, () => {
      try { if (/ready|started server/i.test(readFileSync(path, 'utf8'))) finish() } catch { /* file still opening */ }
    }))
    server.once('exit', (code) => finish(new Error(`Next exited early with code ${code}`)))
  })
  return server
}

/** Largest-remainder split, so shares always add back to the exact total. */
function equalShares(total: bigint, count: number): bigint[] {
  const base = total / BigInt(count)
  const remainder = Number(total % BigInt(count))
  return Array.from({ length: count }, (_, index) => base + (index < remainder ? 1n : 0n))
}

function money(minorUnits: bigint | string, currencyCode: string, currencyExponent: number) {
  return { minorUnits: minorUnits.toString(), currencyCode, currencyExponent }
}

type Person = { id: string; email: string; name: string; token: string }

async function main() {
  mkdirSync(evidenceRoot, { recursive: true, mode: 0o700 })
  process.env.MOBILE_JWT_SECRET = mobileSecret
  process.env.NEXTAUTH_SECRET = mobileSecret
  if (!process.env.TEST_DATABASE_URL?.trim()) {
    process.env.TEST_DATABASE_URL = 'postgresql://prateekranka@localhost:5432/bb_polish_e2e_20261022'
  }

  const fixture = await createLedgerTestDatabase()
  let server: ChildProcess | null = null
  let succeeded = false
  try {
    if (startServer) {
      if (await portIsOccupied(port)) throw new Error(`Port ${port} is busy; refusing to stop another process`)
      server = await startNext(fixture.url)
    }
    expect(await request('/api/health'), 200, 'API health')

    // ---- People ----
    const names = ['Prateek', 'Aarav', 'Meera', 'Kabir', 'Zoya'] as const
    const people = {} as Record<(typeof names)[number], Person>
    for (const name of names) {
      const id = `polish-${suffix}-${name.toLowerCase()}`
      const email = `${id}@example.test`
      await fixture.db.user.create({ data: { id, email, name } })
      people[name] = { id, email, name, token: mobileToken({ id, email, name }) }
    }
    const { Prateek: me, Aarav: aarav, Meera: meera, Kabir: kabir, Zoya: zoya } = people
    for (const person of Object.values(people)) {
      expect(await request('/api/mobile/auth/username', {
        token: person.token, method: 'POST', body: { username: `${person.name.toLowerCase()}_${handleSuffix}` },
      }), 200, `${person.name} username`)
    }
    // Everyone becomes Prateek's friend; Aarav and Zoya also become friends for Aarav's groups.
    const befriend = async (inviter: Person, invitee: Person) => {
      const invite = expect(await request('/api/mobile/friends/invitations', { token: inviter.token, method: 'POST' }), 200, 'invite')
      expect(await request(`/api/mobile/friends/invitations/${invite.invitation.code}/claim`, { token: invitee.token, method: 'POST' }), 201, 'claim')
    }
    for (const friend of [aarav, meera, kabir, zoya]) await befriend(me, friend)
    await befriend(aarav, zoya)

    // ---- 1. Currency registry ----
    await step('Capabilities list SGD and AED with exponent 2', async () => {
      const body = expect(await request('/api/mobile/capabilities', { token: me.token }), 200, 'capabilities')
      samples.capabilities = body
      const codes = new Map((body.currencies as Json[]).map((entry) => [entry.code, entry.exponent]))
      assert.equal(codes.get('SGD'), 2)
      assert.equal(codes.get('AED'), 2)
      assert.equal(codes.get('VND'), 0)
      assert.equal(codes.get('INR'), 2)
    })

    // ---- 2. Default currency ----
    await step('Default currency is stored, validated and returned', async () => {
      const before = expect(await request('/api/mobile/auth/me', { token: me.token }), 200, 'me')
      assert.equal(before.user.defaultCurrency, null, 'a new person has no default yet')
      const bad = await request('/api/mobile/auth/me', { token: me.token, method: 'PATCH', body: { defaultCurrency: 'XYZ' } })
      assert.equal(bad.status, 400)
      const empty = await request('/api/mobile/auth/me', { token: me.token, method: 'PATCH', body: {} })
      assert.equal(empty.status, 400)
      const sgd = expect(await request('/api/mobile/auth/me', { token: me.token, method: 'PATCH', body: { defaultCurrency: 'sgd' } }), 200, 'set SGD')
      assert.equal(sgd.user.defaultCurrency, 'SGD')
      const inr = expect(await request('/api/mobile/auth/me', { token: me.token, method: 'PATCH', body: { defaultCurrency: 'INR' } }), 200, 'set INR')
      assert.equal(inr.user.defaultCurrency, 'INR')
      const after = expect(await request('/api/mobile/auth/me', { token: me.token }), 200, 'me again')
      assert.equal(after.user.defaultCurrency, 'INR')
      samples.me = after
      expect(await request('/api/mobile/auth/me', { token: meera.token, method: 'PATCH', body: { defaultCurrency: 'SGD' } }), 200, 'Meera SGD')
    })

    // ---- 3. Avatars reach every member ----
    await step('Avatar choice is valid and saved', async () => {
      const bad = await request('/api/mobile/auth/me', { token: aarav.token, method: 'PATCH', body: { avatar: 'not-a-raccoon' } })
      assert.equal(bad.status, 400)
      expect(await request('/api/mobile/auth/me', { token: aarav.token, method: 'PATCH', body: { avatar: 'bandana' } }), 200, 'Aarav avatar')
      expect(await request('/api/mobile/auth/me', { token: kabir.token, method: 'PATCH', body: { avatar: 'bucket-hat' } }), 200, 'Kabir avatar')
      expect(await request('/api/mobile/auth/me', { token: me.token, method: 'PATCH', body: { avatar: 'sunglasses' } }), 200, 'Prateek avatar')
    })

    // ---- Groups ----
    const createGroup = async (owner: Person, name: string, currency: string, category: string, members: Person[]) => {
      const body = expect(await request('/api/mobile/groups', {
        token: owner.token, method: 'POST',
        headers: { 'Idempotency-Key': `group-${name.replace(/\s+/g, '-')}-${suffix}` },
        body: { name, currency, category, memberAccountIds: members.map((member) => member.id) },
      }), 201, `create ${name}`)
      return body.group.id as string
    }
    const readGroup = async (token: string, groupId: string) =>
      expect(await request(`/api/mobile/ledger/groups/${groupId}`, { token }), 200, 'group read')
    const memberIdFor = (envelope: Json, person: Person) =>
      (envelope.data.group.members as Json[]).find((member) => member.accountId === person.id)!.memberId as string

    const daysAgo = (days: number, hour = 13) => {
      const date = new Date()
      date.setUTCDate(date.getUTCDate() - days)
      date.setUTCHours(hour, 0, 0, 0)
      return date.toISOString()
    }

    const addExpense = async (input: {
      by: Person; groupId: string; description: string; total: bigint; currency: string; exponent: number
      payer: Person; among: Person[]; date?: string; category?: string; notes?: string
      splitType?: 'EQUAL' | 'EXACT' | 'SHARES'; shares?: number[]
    }) => {
      const envelope = await readGroup(input.by.token, input.groupId)
      const revision = envelope.data.group.revision as number
      let amounts: bigint[]
      if (input.shares) {
        const totalShares = input.shares.reduce((sum, value) => sum + value, 0)
        amounts = input.shares.map((value) => (input.total * BigInt(value)) / BigInt(totalShares))
        const leftover = input.total - amounts.reduce((sum, value) => sum + value, 0n)
        for (let index = 0; index < Number(leftover); index += 1) amounts[index] += 1n
      } else {
        amounts = equalShares(input.total, input.among.length)
      }
      const expenseId = randomUUID()
      const body = expect(await request('/api/mobile/expenses', {
        token: input.by.token, method: 'POST',
        body: {
          groupId: input.groupId,
          operationId: randomUUID(),
          expectedRevision: revision,
          expenseId,
          description: input.description,
          amount: money(input.total, input.currency, input.exponent),
          currency: input.currency,
          paidById: input.payer.id,
          splitType: input.splitType ?? (input.shares ? 'SHARES' : 'EQUAL'),
          splits: input.among.map((person, index) => ({
            id: `${expenseId}-${index}`,
            userId: person.id,
            amount: money(amounts[index], input.currency, input.exponent),
            ...(input.shares ? { shares: input.shares[index] } : {}),
          })),
          ...(input.date ? { date: input.date } : {}),
          ...(input.category ? { category: input.category } : {}),
          ...(input.notes ? { notes: input.notes } : {}),
        },
      }), 201, `expense ${input.description}`)
      samples.expenseCreate ??= body
      return { expenseId, body }
    }

    const crew = [me, aarav, meera, kabir, zoya]
    const goa = await createGroup(me, 'Goa trip', 'INR', 'TRIP', [aarav, meera, kabir, zoya])
    const villa = await addExpense({
      by: me, groupId: goa, description: 'Villa, 3 nights', total: 1_366_432n, currency: 'INR', exponent: 2,
      payer: me, among: crew, date: daysAgo(9), category: 'stay', notes: 'Booked through Kabir’s cousin. Deposit refunded.',
    })
    await addExpense({
      by: aarav, groupId: goa, description: 'Fish thali, Ritz Classic', total: 248_650n, currency: 'INR', exponent: 2,
      payer: aarav, among: crew, date: daysAgo(0, 8), category: 'food', notes: 'Kingfish thali for five, extra sol kadhi.',
    })
    await addExpense({
      by: kabir, groupId: goa, description: 'Scooter rental', total: 180_000n, currency: 'INR', exponent: 2,
      payer: kabir, among: crew, date: daysAgo(3), category: 'travel', shares: [2, 2, 1, 2, 1],
    })
    await addExpense({
      by: meera, groupId: goa, description: 'Sunset cruise', total: 499_999n, currency: 'INR', exponent: 2,
      payer: meera, among: [me, meera, kabir], date: daysAgo(20), category: 'fun',
    })

    const singapore = await createGroup(me, 'Singapore layover', 'SGD', 'TRIP', [meera])
    await addExpense({
      by: meera, groupId: singapore, description: 'Hawker centre dinner', total: 4_860n, currency: 'SGD', exponent: 2,
      payer: meera, among: [me, meera], date: daysAgo(25), category: 'food',
    })
    const dubai = await createGroup(me, 'Dubai stopover', 'AED', 'TRIP', [kabir])
    await addExpense({
      by: me, groupId: dubai, description: 'Desert safari', total: 45_000n, currency: 'AED', exponent: 2,
      payer: me, among: [me, kabir], date: daysAgo(40), category: 'fun',
    })
    const hanoi = await createGroup(me, 'Hanoi street food', 'VND', 'TRIP', [zoya])
    await addExpense({
      by: zoya, groupId: hanoi, description: 'Bun cha crawl', total: 385_001n, currency: 'VND', exponent: 0,
      payer: zoya, among: [me, zoya], date: daysAgo(5), category: 'food',
    })
    const solo = await createGroup(me, 'Solo budget', 'INR', 'OTHER', [])
    await addExpense({
      by: me, groupId: solo, description: 'Groceries', total: 123_456n, currency: 'INR', exponent: 2,
      payer: me, among: [me], date: daysAgo(1), category: 'groceries',
    })
    // Aarav's group, so Prateek is a member and not the owner.
    const cricket = await createGroup(aarav, 'Weekend cricket', 'INR', 'OTHER', [me, zoya])
    await addExpense({
      by: aarav, groupId: cricket, description: 'Turf booking', total: 150_000n, currency: 'INR', exponent: 2,
      payer: aarav, among: [aarav, zoya], date: daysAgo(2), category: 'sport',
    })

    // ---- 4. Exact paise ----
    await step('Odd paise split exactly and read back with notes, category and date', async () => {
      const envelope = await readGroup(me.token, goa)
      samples.groupEnvelope = envelope
      const expense = (envelope.data.group.expenses as Json[]).find((entry) => entry.expenseId === villa.expenseId)!
      assert.equal(expense.amount.minorUnits, '1366432')
      const shares = (expense.splits as Json[]).map((split) => BigInt(split.amount.minorUnits))
      assert.equal(shares.reduce((sum, value) => sum + value, 0n), 1_366_432n, 'shares add to the exact total')
      assert.deepEqual(shares.map(String), ['273287', '273287', '273286', '273286', '273286'])
      assert.equal(expense.notes, 'Booked through Kabir’s cousin. Deposit refunded.')
      assert.equal(expense.category, 'stay')
      assert.equal(expense.createdAt.slice(0, 10), daysAgo(9).slice(0, 10))
    })

    // ---- 5. Summary fields, order, one-person balance ----
    let summary: Json = {}
    await step('Summary carries members, role, totals and newest-first groups', async () => {
      summary = expect(await request('/api/mobile/ledger?activityLimit=5', { token: me.token }), 200, 'summary')
      samples.summary = summary
      const groups = summary.groups as Json[]
      assert.equal(groups.length, 6)
      const stamps = groups.map((group) => group.lastActivityAt as string)
      assert.deepEqual([...stamps].sort().reverse(), stamps, 'groups are newest first')
      const goaSummary = groups.find((group) => group.groupId === goa)!
      assert.equal(goaSummary.members.length, 5)
      assert.equal(goaSummary.currentRole, 'owner')
      assert.equal(goaSummary.activeExpenseCount, 4)
      assert.equal(goaSummary.totalSpent.minorUnits, String(1_366_432 + 248_650 + 180_000 + 499_999))
      const cricketSummary = groups.find((group) => group.groupId === cricket)!
      assert.equal(cricketSummary.currentRole, 'member')
      assert.ok(summary.profileImages[aarav.id]?.endsWith('bandana'), 'Aarav’s avatar reaches Prateek')
      assert.ok(summary.profileImages[kabir.id]?.endsWith('bucket-hat'), 'Kabir’s avatar reaches Prateek')
    })
    await step('A one-person group has a real zero balance, not a missing one', async () => {
      const soloSummary = (summary.groups as Json[]).find((group) => group.groupId === solo)!
      assert.equal(soloSummary.members.length, 1)
      const balances = soloSummary.balanceByCurrency as Json[]
      assert.ok(balances.every((entry) => entry.minorUnits === '0'), redact(balances))
      const envelope = await readGroup(me.token, solo)
      assert.equal(envelope.data.group.settlementPlan.transfers.length, 0)
      const mine = envelope.data.group.balances.currentAccount.byCurrency as Json[]
      assert.ok(mine.every((entry) => entry.minorUnits === '0'))
    })

    // ---- 6. Activity paging ----
    await step('Activity pages by cursor with no gaps and no repeats', async () => {
      const full = expect(await request('/api/mobile/ledger', { token: me.token }), 200, 'full summary')
      const fullIds = (full.activity as Json[]).map((item) => `${item.groupId}:${item.activityId}`)
      assert.ok(fullIds.length > 10, `expected a long feed, got ${fullIds.length}`)
      const paged: string[] = (summary.activity as Json[]).map((item) => `${item.groupId}:${item.activityId}`)
      assert.equal(paged.length, 5)
      let cursor = summary.activityNextCursor as string | null
      assert.ok(cursor, 'first page has a cursor')
      let pages = 1
      while (cursor) {
        const page = expect(await request(`/api/mobile/activity?limit=4&before=${encodeURIComponent(cursor)}`, { token: me.token }), 200, 'activity page')
        if (pages === 1) samples.activityPage = page
        paged.push(...(page.activity as Json[]).map((item) => `${item.groupId}:${item.activityId}`))
        cursor = page.nextCursor
        pages += 1
        assert.ok(pages < 50, 'paging terminates')
      }
      assert.deepEqual(paged, fullIds)
      const stamps = (full.activity as Json[]).map((item) => item.at as string)
      assert.deepEqual([...stamps].sort().reverse(), stamps, 'activity is newest first')
    })

    // ---- 7. Partial payment ----
    await step('A partial payment lowers the plan, and an overpayment is refused', async () => {
      const envelope = await readGroup(zoya.token, goa)
      const zoyaMember = memberIdFor(envelope, zoya)
      const transfer = (envelope.data.group.settlementPlan.transfers as Json[]).find((entry) => entry.payerMemberId === zoyaMember)
      assert.ok(transfer, 'Zoya owes someone in Goa')
      const owed = BigInt(transfer.amount.minorUnits)
      const partial = 100_000n
      assert.ok(owed > partial, `Zoya owes ${owed}`)
      const settle = (amount: bigint, key: string, revision: number) => request(`/api/groups/${goa}/settlements`, {
        token: zoya.token, method: 'POST', headers: { 'Idempotency-Key': key },
        body: {
          expectedVersion: revision,
          planTransferId: transfer.planTransferId,
          payerParticipantId: transfer.payerMemberId,
          recipientParticipantId: transfer.recipientMemberId,
          currencyCode: 'INR', currencyExponent: 2, minorUnits: amount.toString(), note: 'Part of the villa',
        },
      })
      const over = await settle(owed + 1n, `over-${suffix}`, envelope.data.group.revision)
      assert.ok(over.status >= 400 && over.status < 500, `overpayment must be refused, got ${over.status}`)
      const done = await settle(partial, `partial-${suffix}`, envelope.data.group.revision)
      assert.equal(done.status, 201, redact(done.body))
      samples.settlement = done.body
      const after = await readGroup(zoya.token, goa)
      const remaining = (after.data.group.settlementPlan.transfers as Json[])
        .filter((entry) => entry.payerMemberId === zoyaMember)
        .reduce((sum, entry) => sum + BigInt(entry.amount.minorUnits), 0n)
      const before = (envelope.data.group.settlementPlan.transfers as Json[])
        .filter((entry) => entry.payerMemberId === zoyaMember)
        .reduce((sum, entry) => sum + BigInt(entry.amount.minorUnits), 0n)
      assert.equal(remaining, before - partial)
    })

    // ---- 8. Leave rules ----
    await step('Leave explains each refusal and succeeds when settled', async () => {
      const club = await createGroup(aarav, 'Book club', 'INR', 'OTHER', [me, zoya])
      await addExpense({
        by: aarav, groupId: club, description: 'Two paperbacks', total: 99_900n, currency: 'INR', exponent: 2,
        payer: aarav, among: [aarav, zoya], date: daysAgo(30),
      })
      const owner = await request(`/api/mobile/groups/${club}/leave`, { token: aarav.token, method: 'POST' })
      assert.equal(owner.status, 409)
      assert.equal(owner.body.code, 'OWNER_CANNOT_LEAVE')
      assert.match(owner.body.message, /created this group/)
      const owing = await request(`/api/mobile/groups/${club}/leave`, { token: zoya.token, method: 'POST' })
      assert.equal(owing.status, 409)
      assert.equal(owing.body.code, 'MEMBER_UNSETTLED')
      assert.match(owing.body.message, /Settle your own balance/)
      const left = await request(`/api/mobile/groups/${club}/leave`, { token: me.token, method: 'POST', headers: { 'Idempotency-Key': `leave-${suffix}` } })
      assert.equal(left.status, 200, redact(left.body))
      assert.equal(left.body.left, true)
      const list = expect(await request('/api/mobile/ledger?activityLimit=1', { token: me.token }), 200, 'summary after leave')
      assert.ok(!(list.groups as Json[]).some((group) => group.groupId === club), 'a left group leaves the list')
    })

    // ---- 9. Delete rules ----
    await step('Delete explains each refusal and archives a settled group', async () => {
      const notOwner = await request(`/api/mobile/groups/${cricket}`, { token: me.token, method: 'DELETE' })
      assert.equal(notOwner.status, 403)
      assert.equal(notOwner.body.code, 'NOT_GROUP_OWNER')
      assert.match(notOwner.body.message, new RegExp(`Only ${aarav.name.toLowerCase()}_${handleSuffix} can delete this group`))
      const unsettled = await request(`/api/mobile/groups/${goa}`, { token: me.token, method: 'DELETE' })
      assert.equal(unsettled.status, 409)
      assert.equal(unsettled.body.code, 'GROUP_UNSETTLED')
      assert.match(unsettled.body.message, /still has \d+ payments? to settle/)

      const flat = await createGroup(me, 'Old flat', 'INR', 'HOME', [aarav])
      await addExpense({
        by: me, groupId: flat, description: 'Final electricity bill', total: 3_333n, currency: 'INR', exponent: 2,
        payer: me, among: [me, aarav], date: daysAgo(60),
      })
      const envelope = await readGroup(aarav.token, flat)
      const transfer = envelope.data.group.settlementPlan.transfers[0]
      expect(await request(`/api/groups/${flat}/settlements`, {
        token: aarav.token, method: 'POST', headers: { 'Idempotency-Key': `flat-${suffix}` },
        body: {
          expectedVersion: envelope.data.group.revision,
          planTransferId: transfer.planTransferId,
          payerParticipantId: transfer.payerMemberId,
          recipientParticipantId: transfer.recipientMemberId,
          currencyCode: 'INR', currencyExponent: 2, minorUnits: transfer.amount.minorUnits,
        },
      }), 201, 'settle old flat')
      const deleted = await request(`/api/mobile/groups/${flat}`, { token: me.token, method: 'DELETE' })
      assert.equal(deleted.status, 200, redact(deleted.body))
      assert.equal(deleted.body.code, 'GROUP_ARCHIVED')
      const list = expect(await request('/api/mobile/ledger?activityLimit=1', { token: me.token }), 200, 'summary after delete')
      assert.ok(!(list.groups as Json[]).some((group) => group.groupId === flat), 'a deleted group leaves the list')
    })

    // ---- 10. Exchange rates ----
    let rateSource = 'live Frankfurter'
    try {
      await refreshExchangeRates({ db: fixture.db, fetcher: frankfurterFetcher })
    } catch {
      // Offline run: seed fixed reference rates so the route can still be checked.
      rateSource = 'fixed offline fixture'
      const perINR: Record<string, number> = {
        USD: 0.01139, EUR: 0.00977, GBP: 0.00852, JPY: 1.722, CAD: 0.01589, AUD: 0.01742, VND: 273.14, SGD: 0.01536,
        AED: 0.04183, CNY: 0.0811, BRL: 0.0615, MXN: 0.2093, KWD: 0.003489, BHD: 0.004294, OMR: 0.004381, INR: 1,
      }
      const codes = supportedRateCurrencies()
      const now = new Date()
      await fixture.db.$transaction(codes.flatMap((base) => codes.filter((quote) => quote !== base).map((quote) =>
        fixture.db.exchangeRate.create({
          data: {
            base, quote, rate: new Prisma.Decimal((perINR[quote] / perINR[base]).toPrecision(10)),
            rateDate: new Date(`${now.toISOString().slice(0, 10)}T00:00:00.000Z`), source: 'fixture', fetchedAt: now,
          },
        })
      )))
    }
    await step(`Rates come back for the default currency (${rateSource})`, async () => {
      const bad = await request('/api/mobile/rates?base=XYZ', { token: me.token })
      assert.equal(bad.status, 400)
      const body = expect(await request('/api/mobile/rates', { token: me.token }), 200, 'rates')
      samples.rates = body
      assert.equal(body.base, 'INR', 'the base follows the default currency')
      const quotes = new Map((body.rates as Json[]).map((entry) => [entry.quote, entry]))
      for (const code of ['SGD', 'AED', 'VND', 'USD']) {
        const entry = quotes.get(code)
        assert.ok(entry, `${code} has a rate`)
        const product = Number(entry.quotePerBase) * Number(entry.basePerQuote)
        assert.ok(Math.abs(product - 1) < 0.01, `${code} directions agree (${product})`)
      }
      const meeraRates = expect(await request('/api/mobile/rates', { token: meera.token }), 200, 'Meera rates')
      assert.equal(meeraRates.base, 'SGD')
    })

    // ---- Evidence ----
    const sampleRoot = resolve(evidenceRoot, 'samples')
    mkdirSync(sampleRoot, { recursive: true, mode: 0o700 })
    for (const [name, value] of Object.entries(samples)) {
      writeFileSync(resolve(sampleRoot, `${name}.json`), JSON.stringify(value, null, 2) + '\n', { mode: 0o600 })
    }
    const session = {
      baseURL,
      token: me.token,
      userId: me.id,
      storeId: `vietnam-test-polish-${suffix.replaceAll('_', '-')}`,
      groups: { goa, singapore, dubai, hanoi, solo, cricket },
      people: Object.fromEntries(Object.entries(people).map(([name, person]) => [name, { id: person.id, token: person.token }])),
      databaseURL: fixture.url,
      serverPID: server?.pid ?? null,
    }
    const sessionPath = resolve(evidenceRoot, 'qa-session.json')
    writeFileSync(sessionPath, JSON.stringify(session, null, 2) + '\n', { mode: 0o600 })
    chmodSync(sessionPath, 0o600)
    succeeded = true
  } finally {
    writeReport()
    // A failed run stops the server it started, so the port is free for the next run.
    if (!succeeded && server?.pid) {
      try { process.kill(-server.pid, 'SIGTERM') } catch { /* already gone */ }
    }
    await fixture.db.$disconnect().catch(() => undefined)
    if (!startServer) await fixture.close().catch(() => undefined)
  }
}

function writeReport() {
  const passed = checks.filter((entry) => entry.ok).length
  const revision = (() => {
    try { return execFileSync('git', ['rev-parse', '--short', 'HEAD'], { cwd: repositoryRoot, encoding: 'utf8' }).trim() } catch { return 'unknown' }
  })()
  const report = [
    '# App Store polish: server end-to-end check',
    '',
    `- Base commit: ${revision} (plus uncommitted changes)`,
    `- API: ${baseURL}`,
    `- Result: ${passed} passed, ${checks.length - passed} failed`,
    '',
    '## Checks',
    '',
    ...checks.map((entry) => `- ${entry.ok ? 'PASS' : 'FAIL'} ${entry.name}${entry.detail ? `: ${entry.detail}` : ''}`),
    '',
    '## Run it again',
    '',
    '```sh',
    'node --import tsx apps/api/scripts/polish-e2e.ts',
    '```',
    '',
  ].join('\n')
  mkdirSync(evidenceRoot, { recursive: true, mode: 0o700 })
  writeFileSync(resolve(evidenceRoot, 'report.md'), report, { mode: 0o600 })
  console.log(report)
}

main().catch((error) => {
  console.error(`Polish E2E failed: ${redact(error instanceof Error ? error.stack ?? error.message : error)}`)
  process.exitCode = 1
})
