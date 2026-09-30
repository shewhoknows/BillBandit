/*
 * Disposable backend QA for the Vietnam trip fixture.
 *
 * The script creates a task-owned local PostgreSQL database when TEST_DATABASE_URL
 * is absent, provisions one schema through the guarded ledger test harness, seeds
 * synthetic accounts, and drives the real Next.js mobile routes over HTTP.
 *
 * Set START_VIETNAM_TRIP_SERVER=1 to start Next on port 31301. The child process
 * remains attached to the fixture so the simulator can use the written session.
 */
import assert from 'node:assert/strict'
import { execFileSync, spawn, type ChildProcess } from 'node:child_process'
import { chmodSync, closeSync, existsSync, mkdirSync, openSync, readFileSync, watch, writeFileSync } from 'node:fs'
import { randomBytes, randomUUID } from 'node:crypto'
import { createConnection } from 'node:net'
import { dirname, resolve } from 'node:path'

import type { PrismaClient } from '@prisma/client'

import { createLedgerTestDatabase } from '../test/integration/ledger-harness'

const repositoryRoot = resolve(dirname(new URL(import.meta.url).pathname), '../..', '..')
const apiRoot = resolve(repositoryRoot, 'apps/api')
const defaultEvidenceRoot = resolve(repositoryRoot, '.scratch/vietnam-trip/evidence')
const baseURL = process.env.VIETNAM_TRIP_BASE_URL?.trim() || 'http://127.0.0.1:31300'
const evidenceRoot = process.env.VIETNAM_TRIP_EVIDENCE_DIR?.trim() || defaultEvidenceRoot
const startedServer = process.env.START_VIETNAM_TRIP_SERVER === '1'
const suffix = `${Date.now().toString(36)}_${randomBytes(3).toString('hex')}`
const handleSuffix = randomBytes(2).toString('hex')
const mobileSecret = process.env.VIETNAM_TRIP_MOBILE_JWT_SECRET?.trim() || `vietnam-trip-qa-${randomBytes(32).toString('hex')}`

type JsonRecord = Record<string, unknown>
type HttpResult = { status: number; headers: Headers; body: unknown }
type Check = { name: string; ok: boolean; detail?: string }

function ensureEvidenceRoot() {
  mkdirSync(evidenceRoot, { recursive: true, mode: 0o700 })
}

function safeDetail(value: unknown): string {
  const text = typeof value === 'string' ? value : JSON.stringify(value)
  return text
    .replace(/Bearer\s+[A-Za-z0-9._-]+/gi, 'Bearer [redacted]')
    .replace(/(token|secret|password)"?\s*:\s*"[^"]*"/gi, '$1: [redacted]')
    .slice(0, 1_000)
}

function jsonBody(value: unknown): BodyInit {
  return JSON.stringify(value)
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
    body: options.body === undefined ? undefined : jsonBody(options.body),
  })
  const text = await response.text()
  let body: unknown = null
  try {
    body = text ? JSON.parse(text) : null
  } catch {
    body = text
  }
  return { status: response.status, headers: response.headers, body }
}

function objectBody(result: HttpResult): JsonRecord {
  assert.equal(typeof result.body, 'object', `expected JSON object, got ${safeDetail(result.body)}`)
  assert.ok(result.body !== null && !Array.isArray(result.body), `expected JSON object, got ${safeDetail(result.body)}`)
  return result.body as JsonRecord
}

function expectStatus(result: HttpResult, status: number, label: string): JsonRecord {
  if (result.status !== status) {
    throw new Error(`${label}: expected ${status}, received ${result.status}: ${safeDetail(result.body)}`)
  }
  return objectBody(result)
}

function expectNumber(value: unknown, label: string): number {
  assert.equal(typeof value, 'number', `${label} must be a number`)
  return value as number
}

function expectString(value: unknown, label: string): string {
  assert.equal(typeof value, 'string', `${label} must be a string`)
  return value as string
}

function check(checks: Check[], name: string, fn: () => void) {
  try {
    fn()
    checks.push({ name, ok: true })
  } catch (error) {
    checks.push({ name, ok: false, detail: safeDetail(error instanceof Error ? error.message : error) })
    throw error
  }
}

function mark(checks: Check[], name: string): void {
  checks.push({ name, ok: true })
}

function createDatabaseIfNeeded(): { url: string; databaseName: string | null; ownsDatabase: boolean } {
  if (process.env.TEST_DATABASE_URL?.trim()) {
    return { url: process.env.TEST_DATABASE_URL.trim(), databaseName: null, ownsDatabase: false }
  }
  const databaseName = `bb_vietnam_test_${suffix}`
  execFileSync('createdb', ['-h', '127.0.0.1', '-U', 'prateekranka', databaseName], {
    stdio: ['ignore', 'ignore', 'pipe'],
  })
  return {
    url: `postgresql://prateekranka@127.0.0.1:5432/${databaseName}`,
    databaseName,
    ownsDatabase: true,
  }
}

function realMobileToken(user: { id: string; email: string; name: string }): string {
  // Run the checked-in createMobileToken implementation from the API workspace.
  // tsx needs the API tsconfig for its @/* path alias; token output stays in
  // this process and is written only to the chmod 600 session file.
  const helper = [
    "import { createMobileToken } from './lib/mobile-auth.ts'",
    "const user = JSON.parse(process.env.VIETNAM_TRIP_USER ?? '{}')",
    'process.stdout.write(createMobileToken(user))',
  ].join(';')
  const token = execFileSync(process.execPath, ['--import', 'tsx', '--eval', helper], {
    cwd: apiRoot,
    env: {
      ...process.env,
      TSX_TSCONFIG_PATH: resolve(apiRoot, 'tsconfig.json'),
      VIETNAM_TRIP_USER: JSON.stringify(user),
      MOBILE_JWT_SECRET: mobileSecret,
      NEXTAUTH_SECRET: mobileSecret,
    },
    encoding: 'utf8',
  }).trim()
  if (!token) throw new Error('createMobileToken helper returned an empty token')
  return token
}

function databaseUrlWithSchema(url: string, schema: string): string {
  const parsed = new URL(url)
  parsed.searchParams.set('schema', schema)
  return parsed.toString()
}

async function waitForHealth(server: ChildProcess | null, readinessPaths: string[] = []): Promise<void> {
  if (!server) {
    expectStatus(await request('/api/health'), 200, 'existing API health')
    return
  }

  await new Promise<void>((resolvePromise, reject) => {
    let settled = false
    const timer = setTimeout(() => {
      if (settled) return
      settled = true
      reject(new Error('Next.js server did not emit a readiness line within 90 seconds'))
    }, 90_000)
    const ready = (line: string) => {
      if (settled || !/ready|started server/i.test(line)) return
      settled = true
      clearTimeout(timer)
      resolvePromise()
    }
    const watchers = readinessPaths.map((path) => watch(path, { persistent: false }, () => {
      try { ready(readFileSync(path, 'utf8')) } catch { /* the child may still be creating the file */ }
    }))
    const closeWatchers = () => watchers.forEach((entry) => entry.close())
    server.once('exit', closeWatchers)
    server.once('error', (error) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      closeWatchers()
      reject(error)
    })
    server.once('exit', (code) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      closeWatchers()
      reject(new Error(`Next.js server exited before readiness with code ${code ?? 'unknown'}`))
    })
  })

  // One bounded readiness request after the process readiness callback.
  expectStatus(await request('/api/health'), 200, 'started API health')
}

function portIsOccupied(port: number): Promise<boolean> {
  return new Promise((resolvePromise) => {
    const socket = createConnection({ host: '127.0.0.1', port })
    socket.once('connect', () => {
      socket.destroy()
      resolvePromise(true)
    })
    socket.once('error', () => {
      socket.destroy()
      resolvePromise(false)
    })
  })
}

function startNextServer(databaseURL: string): { server: ChildProcess; readinessPaths: string[] } {
  const stdoutPath = resolve(evidenceRoot, 'vietnam-trip-next-stdout.log')
  const stderrPath = resolve(evidenceRoot, 'vietnam-trip-next-stderr.log')
  writeFileSync(stdoutPath, '', { encoding: 'utf8', mode: 0o600 })
  writeFileSync(stderrPath, '', { encoding: 'utf8', mode: 0o600 })
  const stdoutFd = openSync(stdoutPath, 'a', 0o600)
  const stderrFd = openSync(stderrPath, 'a', 0o600)
  const server = spawn('npm', ['--workspace', 'apps/api', 'run', 'dev', '--', '-p', '31301'], {
    cwd: repositoryRoot,
    env: {
      ...process.env,
      DATABASE_URL: databaseURL,
      MOBILE_JWT_SECRET: mobileSecret,
      NEXTAUTH_SECRET: mobileSecret,
      NODE_ENV: 'development',
    },
    detached: true,
    stdio: ['ignore', stdoutFd, stderrFd],
  })
  closeSync(stdoutFd)
  closeSync(stderrFd)
  return { server, readinessPaths: [stdoutPath, stderrPath] }
}

function money(minorUnits: string, currencyCode = 'VND', currencyExponent = 0) {
  return { minorUnits, currencyCode, currencyExponent }
}

function expenseBody(input: {
  groupId: string
  operationId: string
  expectedRevision: number
  expenseId: string
  description: string
  amount: string
  paidById: string
  splitType: 'EXACT' | 'PERCENTAGE' | 'SHARES'
  splits: Array<{ userId: string; amount: string; percentage?: number; shares?: number }>
  currencyCode?: string
  currencyExponent?: number
}) {
  const currencyCode = input.currencyCode ?? 'VND'
  const currencyExponent = input.currencyExponent ?? 0
  return {
    groupId: input.groupId,
    operationId: input.operationId,
    expectedRevision: input.expectedRevision,
    expenseId: input.expenseId,
    description: input.description,
    amount: money(input.amount, currencyCode, currencyExponent),
    currency: currencyCode,
    paidById: input.paidById,
    splitType: input.splitType,
    splits: input.splits.map((split, index) => ({
      id: `${input.expenseId}-split-${index}`,
      userId: split.userId,
      amount: money(split.amount, currencyCode, currencyExponent),
      ...(split.percentage === undefined ? {} : { percentage: split.percentage }),
      ...(split.shares === undefined ? {} : { shares: split.shares }),
    })),
  }
}

async function main() {
  ensureEvidenceRoot()
  process.env.MOBILE_JWT_SECRET = mobileSecret
  process.env.NEXTAUTH_SECRET = mobileSecret
  const database = createDatabaseIfNeeded()
  process.env.TEST_DATABASE_URL = database.url

  let fixture: Awaited<ReturnType<typeof createLedgerTestDatabase>> | undefined
  let server: ChildProcess | null = null
  const checks: Check[] = []
  let qaSessionPath = resolve(evidenceRoot, 'qa-session.json')
  try {
    fixture = await createLedgerTestDatabase()
    const databaseURL = fixture.url

    if (startedServer) {
      if (await portIsOccupied(31301)) throw new Error('Port 31301 is already occupied; refusing to stop another process')
      const started = startNextServer(databaseURL)
      server = started.server
      server.unref()
      await waitForHealth(server, started.readinessPaths)
    } else {
      await waitForHealth(null)
    }

    const aliceID = `vietnam-trip-${suffix}-alice`
    const bobID = `vietnam-trip-${suffix}-bob`
    const outsiderID = `vietnam-trip-${suffix}-outsider`
    const aliceEmail = `${aliceID}@example.test`
    const bobEmail = `${bobID}@example.test`
    const outsiderEmail = `${outsiderID}@example.test`
    await fixture.db.user.createMany({
      data: [
        { id: aliceID, email: aliceEmail, name: 'Alice Vietnam QA' },
        { id: bobID, email: bobEmail, name: 'Bob Vietnam QA' },
        { id: outsiderID, email: outsiderEmail, name: 'Outsider Vietnam QA' },
      ],
    })

    const aliceToken = realMobileToken({ id: aliceID, email: aliceEmail, name: 'Alice Vietnam QA' })
    const bobToken = realMobileToken({ id: bobID, email: bobEmail, name: 'Bob Vietnam QA' })
    const outsiderToken = realMobileToken({ id: outsiderID, email: outsiderEmail, name: 'Outsider Vietnam QA' })

    expectStatus(await request('/api/mobile/auth/me', { token: aliceToken }), 200, 'Alice auth/me')
    expectStatus(await request('/api/mobile/auth/me', { token: bobToken }), 200, 'Bob auth/me')

    expectStatus(await request('/api/mobile/auth/username', {
      token: aliceToken,
      method: 'POST',
      body: { username: `vqa_alice_${handleSuffix}` },
    }), 200, 'Alice username claim')
    expectStatus(await request('/api/mobile/auth/username', {
      token: bobToken,
      method: 'POST',
      body: { username: `vqa_bob_${handleSuffix}` },
    }), 200, 'Bob username claim')

    const invitation = expectStatus(await request('/api/mobile/friends/invitations', {
      token: aliceToken,
      method: 'POST',
    }), 200, 'friend invitation')
    const inviteCode = expectString((invitation.invitation as JsonRecord).code, 'friend invitation code')
    expectStatus(await request(`/api/mobile/friends/invitations/${encodeURIComponent(inviteCode)}/claim`, {
      token: bobToken,
      method: 'POST',
    }), 201, 'friend invitation claim')
    mark(checks, 'HTTP auth, username claims, and friend invitation')

    const groupName = `Vietnam QA ${suffix}`
    const groupResult = expectStatus(await request('/api/mobile/groups', {
      token: aliceToken,
      method: 'POST',
      headers: { 'Idempotency-Key': `vietnam-group-${suffix}` },
      body: {
        name: groupName,
        description: 'Synthetic backend QA fixture',
        currency: 'VND',
        category: 'TRIP',
        memberAccountIds: [bobID],
      },
    }), 201, 'VND group creation')
    const group = groupResult.group as JsonRecord
    const groupID = expectString(group.id, 'group id')

    const groupDetail = expectStatus(await request(`/api/mobile/groups/${groupID}`, { token: aliceToken }), 200, 'group detail')
    const groupMembers = groupDetail.group as JsonRecord
    const members = groupMembers.members as Array<JsonRecord>
    assert.equal(members.length, 2, 'group must contain Alice and Bob')
    assert.equal(groupMembers.currency, 'VND')
    mark(checks, 'VND group creation through accepted friendship')

    const outsiderGroup = await request(`/api/mobile/groups/${groupID}`, { token: outsiderToken })
    assert.equal(outsiderGroup.status, 403, `outsider group read must be forbidden: ${safeDetail(outsiderGroup.body)}`)
    const outsiderExpense = await request('/api/mobile/expenses', {
      token: outsiderToken,
      method: 'POST',
      body: expenseBody({
        groupId: groupID,
        operationId: `outsider-${suffix}`,
        expectedRevision: 0,
        expenseId: `outsider-expense-${suffix}`,
        description: 'Outsider attempt',
        amount: '1',
        paidById: outsiderID,
        splitType: 'EXACT',
        splits: [{ userId: outsiderID, amount: '1' }],
      }),
    })
    assert.equal(outsiderExpense.status, 403, `outsider expense must be forbidden: ${safeDetail(outsiderExpense.body)}`)
    mark(checks, 'Outsider group read and expense write denied')

    const firstExpenseID = `vietnam-expense-exact-${suffix}`
    const firstExpenseBody = expenseBody({
      groupId: groupID,
      operationId: `expense-exact-create-${suffix}`,
      expectedRevision: 0,
      expenseId: firstExpenseID,
      description: 'Odd VND exact split',
      amount: '100001',
      paidById: aliceID,
      splitType: 'EXACT',
      splits: [
        { userId: aliceID, amount: '50001' },
        { userId: bobID, amount: '50000' },
      ],
    })
    const firstExpenseResult = expectStatus(await request('/api/mobile/expenses', {
      token: aliceToken,
      method: 'POST',
      body: firstExpenseBody,
    }), 201, 'exact expense create')
    const firstExpense = firstExpenseResult.expense as JsonRecord
    assert.equal((firstExpense.money as JsonRecord).minorUnits, '100001')
    assert.equal((firstExpense.splits as Array<JsonRecord>).map((split) => (split.money as JsonRecord).minorUnits).join(','), '50001,50000')
    const firstRevision = expectNumber(firstExpenseResult.revision, 'exact create revision')

    const editBody = expenseBody({
      groupId: groupID,
      operationId: `expense-exact-edit-${suffix}`,
      expectedRevision: firstRevision,
      expenseId: firstExpenseID,
      description: 'Odd VND exact split edited',
      amount: '100001',
      paidById: aliceID,
      splitType: 'EXACT',
      splits: [
        { userId: aliceID, amount: '50001' },
        { userId: bobID, amount: '50000' },
      ],
    })
    const editResult = expectStatus(await request(`/api/mobile/expenses/${firstExpenseID}`, {
      token: aliceToken,
      method: 'PUT',
      body: editBody,
    }), 200, 'expense revision edit')
    assert.equal(((editResult.expense as JsonRecord).description), 'Odd VND exact split edited')
    const secondRevision = expectNumber(editResult.revision, 'expense edit revision')
    assert.equal(secondRevision, firstRevision + 1)
    mark(checks, 'Odd exact expense and revisioned edit')

    const percentResult = expectStatus(await request('/api/mobile/expenses', {
      token: bobToken,
      method: 'POST',
      body: expenseBody({
        groupId: groupID,
        operationId: `expense-percent-${suffix}`,
        expectedRevision: secondRevision,
        expenseId: `vietnam-expense-percent-${suffix}`,
        description: 'VND percentage split',
        amount: '100',
        paidById: bobID,
        splitType: 'PERCENTAGE',
        splits: [
          { userId: aliceID, amount: '25', percentage: 25 },
          { userId: bobID, amount: '75', percentage: 75 },
        ],
      }),
    }), 201, 'percentage expense create')
    const percentExpense = percentResult.expense as JsonRecord
    assert.equal((percentExpense.splits as Array<JsonRecord>)[0].percentage, 25)

    const percentRevision = expectNumber(percentResult.revision, 'percentage expense revision')
    const sharesResult = expectStatus(await request('/api/mobile/expenses', {
      token: aliceToken,
      method: 'POST',
      body: expenseBody({
        groupId: groupID,
        operationId: `expense-shares-${suffix}`,
        expectedRevision: percentRevision,
        expenseId: `vietnam-expense-shares-${suffix}`,
        description: 'VND odd shares split',
        amount: '101',
        paidById: aliceID,
        splitType: 'SHARES',
        splits: [
          { userId: aliceID, amount: '51', shares: 50001 },
          { userId: bobID, amount: '50', shares: 50000 },
        ],
      }),
    }), 201, 'shares expense create')
    const sharesExpense = sharesResult.expense as JsonRecord
    assert.equal((sharesExpense.splits as Array<JsonRecord>)[0].shares, 50001)
    const sharesRevision = expectNumber(sharesResult.revision, 'shares expense revision')
    mark(checks, 'Percentage and shares split preservation')

    const mixedCurrency = await request('/api/mobile/expenses', {
      token: aliceToken,
      method: 'POST',
      body: expenseBody({
        groupId: groupID,
        operationId: `expense-mixed-${suffix}`,
        expectedRevision: sharesRevision,
        expenseId: `vietnam-expense-mixed-${suffix}`,
        description: 'Mixed currency must fail',
        amount: '100',
        paidById: aliceID,
        splitType: 'EXACT',
        splits: [{ userId: aliceID, amount: '100' }],
        currencyCode: 'USD',
        currencyExponent: 2,
      }),
    })
    assert.equal(mixedCurrency.status, 400, `mixed currency must be rejected: ${safeDetail(mixedCurrency.body)}`)
    mark(checks, 'Mixed-currency expense rejected')

    const settlementBefore = expectStatus(await request(`/api/groups/${groupID}/settle-up`, { token: bobToken }), 200, 'settlement snapshot before partial')
    const planBefore = settlementBefore.plan as Array<JsonRecord>
    assert.equal(planBefore.length, 1, `expected one net VND transfer, got ${safeDetail(planBefore)}`)
    const transfer = planBefore[0]
    const planAmount = expectString(transfer.amount, 'settlement plan amount')
    const planVersion = expectNumber(settlementBefore.version, 'settlement version')
    const payerParticipantID = expectString(transfer.payerParticipantId, 'payer participant')
    const recipientParticipantID = expectString(transfer.recipientParticipantId, 'recipient participant')
    const planTransferID = expectString(transfer.planTransferId, 'plan transfer id')
    assert.equal(transfer.currencyCode, 'VND')
    assert.equal(planAmount, '50025')

    const partialAmount = '1'
    const partialKey = `settlement-partial-${suffix}`
    const partialSettlement = expectStatus(await request(`/api/groups/${groupID}/settlements`, {
      token: bobToken,
      method: 'POST',
      headers: { 'Idempotency-Key': partialKey },
      body: {
        expectedVersion: planVersion,
        planTransferId: planTransferID,
        payerParticipantId: payerParticipantID,
        recipientParticipantId: recipientParticipantID,
        currencyCode: 'VND',
        currencyExponent: 0,
        minorUnits: partialAmount,
        note: 'QA partial settlement',
      },
    }), 201, 'partial settlement')
    assert.ok((partialSettlement.result as JsonRecord).recordId)
    const settlementAfterPartial = expectStatus(await request(`/api/groups/${groupID}/settle-up`, { token: bobToken }), 200, 'settlement snapshot after partial')
    const partialPlan = settlementAfterPartial.plan as Array<JsonRecord>
    assert.equal(partialPlan.length, 1)
    assert.equal(partialPlan[0].amount, '50024')

    const fullVersion = expectNumber(settlementAfterPartial.version, 'full settlement version')
    const fullKey = `settlement-full-${suffix}`
    const fullRequest = {
      expectedVersion: fullVersion,
      planTransferId: expectString(partialPlan[0].planTransferId, 'remaining transfer id'),
      payerParticipantId: expectString(partialPlan[0].payerParticipantId, 'remaining payer participant'),
      recipientParticipantId: expectString(partialPlan[0].recipientParticipantId, 'remaining recipient participant'),
      currencyCode: 'VND',
      currencyExponent: 0,
      minorUnits: '50024',
      note: 'QA full settlement',
    }
    const fullSettlement = expectStatus(await request(`/api/groups/${groupID}/settlements`, {
      token: bobToken,
      method: 'POST',
      headers: { 'Idempotency-Key': fullKey },
      body: fullRequest,
    }), 201, 'full settlement')
    const fullRecordID = expectString((fullSettlement.result as JsonRecord).recordId, 'full settlement record id')
    const retrySettlement = expectStatus(await request(`/api/groups/${groupID}/settlements`, {
      token: bobToken,
      method: 'POST',
      headers: { 'Idempotency-Key': fullKey },
      body: fullRequest,
    }), 201, 'lost-response full settlement retry')
    assert.equal((retrySettlement.result as JsonRecord).recordId, fullRecordID)
    assert.equal((retrySettlement.result as JsonRecord).eventType, (fullSettlement.result as JsonRecord).eventType)
    const settlementAfterFull = expectStatus(await request(`/api/groups/${groupID}/settle-up`, { token: bobToken }), 200, 'settlement snapshot after full')
    assert.equal((settlementAfterFull.plan as Array<unknown>).length, 0, 'full settlement must clear the plan')
    const transactionCount = await fixture.db.transaction.count({ where: { groupId: groupID } })
    assert.equal(transactionCount, 2, 'partial plus full retry must create exactly two transactions')
    mark(checks, 'Partial/full settlement clears plan and retries exactly once')

    // Exercise the task proxy's dropped-response switch. The server commits the
    // expense, the first client fetch loses its transport response, and the same
    // operation ID then replays the stored result.
    const lostExpenseID = `vietnam-expense-lost-response-${suffix}`
    const lostExpenseBody = expenseBody({
      groupId: groupID,
      operationId: `expense-lost-response-${suffix}`,
      expectedRevision: expectNumber(settlementAfterFull.version, 'lost response expense revision'),
      expenseId: lostExpenseID,
      description: 'Proxy dropped response expense',
      amount: '10',
      paidById: aliceID,
      splitType: 'EXACT',
      splits: [
        { userId: aliceID, amount: '5' },
        { userId: bobID, amount: '5' },
      ],
    })
    const proxyControl = await request('/__qa/network', {
      method: 'PUT',
      body: { offline: false, dropNextExpenseResponse: true },
    })
    if (proxyControl.status === 200) {
      let dropped = false
      try {
        await request('/api/mobile/expenses', {
          token: aliceToken,
          method: 'POST',
          headers: { 'Idempotency-Key': lostExpenseBody.operationId },
          body: lostExpenseBody,
        })
      } catch {
        dropped = true
      }
      assert.equal(dropped, true, 'proxy must drop the first expense response')
    } else {
      // Direct-port runs still verify replay, but cannot simulate transport loss.
      await request('/api/mobile/expenses', { token: aliceToken, method: 'POST', body: lostExpenseBody })
    }
    const replayedLostExpense = expectStatus(await request('/api/mobile/expenses', {
      token: aliceToken,
      method: 'POST',
      headers: { 'Idempotency-Key': lostExpenseBody.operationId },
      body: lostExpenseBody,
    }), 200, 'lost-response expense retry')
    assert.equal((replayedLostExpense.mutation as JsonRecord).replayed, true)
    const lostExpenseRevision = expectNumber(replayedLostExpense.revision, 'lost response replay revision')
    const deletedLostExpense = expectStatus(await request(`/api/mobile/expenses/${lostExpenseID}`, {
      token: aliceToken,
      method: 'DELETE',
      body: {
        operationId: `expense-lost-response-delete-${suffix}`,
        expectedRevision: lostExpenseRevision,
        expenseId: lostExpenseID,
      },
    }), 200, 'lost-response cleanup delete')
    assert.equal((deletedLostExpense.mutation as JsonRecord).replayed, false)
    mark(checks, 'Proxy-dropped expense response replays one UUID exactly once')

    const inrGroupResult = expectStatus(await request('/api/mobile/groups', {
      token: aliceToken,
      method: 'POST',
      headers: { 'Idempotency-Key': `inr-control-${suffix}` },
      body: {
        name: `INR control ${suffix}`,
        currency: 'INR',
        category: 'OTHER',
        memberAccountIds: [bobID],
      },
    }), 201, 'INR control group creation')
    const inrGroupID = expectString((inrGroupResult.group as JsonRecord).id, 'INR control group id')
    const inrDetail = expectStatus(await request(`/api/mobile/groups/${inrGroupID}`, { token: aliceToken }), 200, 'INR control group detail')
    assert.equal((inrDetail.group as JsonRecord).currency, 'INR')
    mark(checks, 'Separate INR control aggregate remains independent')

    const uiGroupName = `Vietnam UI ${suffix}`
    const uiGroupResult = expectStatus(await request('/api/mobile/groups', {
      token: aliceToken,
      method: 'POST',
      headers: { 'Idempotency-Key': `ui-vnd-${suffix}` },
      body: {
        name: uiGroupName,
        description: 'Empty UI simulator fixture',
        currency: 'VND',
        category: 'TRIP',
        memberAccountIds: [bobID],
      },
    }), 201, 'empty VND UI group creation')
    const uiGroupID = expectString((uiGroupResult.group as JsonRecord).id, 'empty UI group id')
    const uiDetail = expectStatus(await request(`/api/mobile/groups/${uiGroupID}`, { token: aliceToken }), 200, 'empty VND UI group detail')
    const uiGroup = uiDetail.group as JsonRecord
    assert.equal(uiGroup.currency, 'VND')
    assert.equal(uiGroup.expenseCount, 0)
    assert.equal((uiGroup.members as Array<unknown>).length, 2)
    mark(checks, 'Empty VND UI group has two members and no expenses')

    const qaSession = {
      baseURL,
      aliceToken,
      bobToken,
      aliceID,
      bobID,
      groupID: uiGroupID,
      groupName: uiGroupName,
      backendGroupID: groupID,
      backendGroupName: groupName,
      databaseURL,
      inrGroupID,
      storeID: `vietnam-test-${suffix.replaceAll('_', '-')}`,
      serverPort: 31301,
      serverPID: server?.pid ?? null,
    }
    qaSessionPath = resolve(evidenceRoot, 'qa-session.json')
    writeFileSync(qaSessionPath, JSON.stringify(qaSession, null, 2) + '\n', { encoding: 'utf8', mode: 0o600 })
    chmodSync(qaSessionPath, 0o600)

    const revision = await fixture.db.group.findUniqueOrThrow({ where: { id: groupID }, select: { settlementVersion: true } })
    const reportPath = resolve(evidenceRoot, 'backend-trip-qa.md')
    const passed = checks.filter((entry) => entry.ok).length
    const report = [
      '# Vietnam trip backend QA',
      '',
      `- Revision: ${execFileSync('git', ['rev-parse', 'HEAD'], { cwd: repositoryRoot, encoding: 'utf8' }).trim()}`,
      `- Base URL: ${baseURL}`,
      `- API port: 31301${server?.pid ? ` (PID ${server.pid})` : ''}`,
      `- Database URL: ${databaseURL.replace(/([?&]schema=).*/, '$1[task-schema]')}`,
      `- Schema: ${fixture.schema}`,
      `- Financial QA group: ${groupName} (${groupID})`,
      `- Empty UI group: ${uiGroupName} (${uiGroupID})`,
      `- Final settlement revision: ${revision.settlementVersion}`,
      `- Checks: ${passed} passed, ${checks.length - passed} failed`,
      '',
      '## Commands',
      '',
      '```sh',
      `VIETNAM_TRIP_EVIDENCE_DIR='${evidenceRoot}' START_VIETNAM_TRIP_SERVER=1 node --import tsx apps/api/scripts/vietnam-trip-qa.ts`,
      '```',
      '',
      '## Covered behavior',
      '',
      '- Real HTTP auth, username claims, friend invitation, and group creation.',
      '- VND exact odd total 100001 with 50001/50000 exact splits.',
      '- Expense edit revision, percentage splits, and shares 50001/50000.',
      '- Mixed-currency rejection and separate INR control-group aggregate.',
      '- Outsider read/write denial.',
      '- Partial settlement, full settlement, zero remaining plan, and exactly-once retry.',
      '- Proxy-dropped expense response replay and cleanup.',
      '',
      '## Check results',
      '',
      ...checks.map((entry) => `- ${entry.ok ? 'PASS' : 'FAIL'} ${entry.name}${entry.detail ? ` — ${entry.detail}` : ''}`),
      '',
      `Credentials for the simulator are in chmod 600 [qa-session.json](${qaSessionPath}).`,
      `Task-owned database ${database.databaseName ?? '[provided TEST_DATABASE_URL]'} and schema ${fixture.schema} remain available for simulator QA.`,
      '',
    ].join('\n')
    writeFileSync(reportPath, report, { encoding: 'utf8', mode: 0o600 })
    chmodSync(reportPath, 0o600)

    const scratchSessionPath = resolve(repositoryRoot, '.scratch/vietnam-trip/qa-session.json')
    mkdirSync(dirname(scratchSessionPath), { recursive: true, mode: 0o700 })
    writeFileSync(scratchSessionPath, JSON.stringify(qaSession, null, 2) + '\n', { encoding: 'utf8', mode: 0o600 })
    chmodSync(scratchSessionPath, 0o600)

    console.log(`Vietnam trip backend QA passed: ${checks.length} checks; API ${baseURL}; group ${groupID}; evidence ${reportPath}`)
  } catch (error) {
    const reportPath = resolve(evidenceRoot, 'backend-trip-qa.md')
    const report = [
      '# Vietnam trip backend QA',
      '',
      `- Revision: ${execFileSync('git', ['rev-parse', 'HEAD'], { cwd: repositoryRoot, encoding: 'utf8' }).trim()}`,
      `- Base URL: ${baseURL}`,
      `- Checks before failure: ${checks.filter((entry) => entry.ok).length} passed, ${checks.filter((entry) => !entry.ok).length} failed`,
      '',
      '## Failure',
      '',
      `- ${safeDetail(error instanceof Error ? error.stack ?? error.message : error)}`,
      '',
      '## Check results',
      '',
      ...checks.map((entry) => `- ${entry.ok ? 'PASS' : 'FAIL'} ${entry.name}${entry.detail ? ` — ${entry.detail}` : ''}`),
      '',
    ].join('\n')
    writeFileSync(reportPath, report, { encoding: 'utf8', mode: 0o600 })
    chmodSync(reportPath, 0o600)
    throw error
  } finally {
    await fixture?.db.$disconnect().catch(() => undefined)
    // Keep the disposable schema and detached server for simulator QA. The root
    // agent can drop the schema and database after the mobile flow completes.
    if (!startedServer) await fixture?.close().catch(() => undefined)
  }
}

main().catch((error) => {
  console.error(`Vietnam trip backend QA failed: ${safeDetail(error instanceof Error ? error.message : error)}`)
  process.exitCode = 1
})
