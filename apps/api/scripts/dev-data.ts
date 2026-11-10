/**
 * Add test data to the LOCAL server. It only adds. It never deletes or resets.
 *
 * Start the local server first, in another terminal:
 *   npm run dev:server
 *
 * Then, from the repo root:
 *   npm run dev:data                       a new trip group with friends, 3 expenses and 1 payment
 *   npm run dev:data -- group "Goa trip" --currency INR --with Aarav,Meera
 *   npm run dev:data -- expense --group "Goa trip" --amount 1250.50 --title "Dinner" --payer Aarav
 *   npm run dev:data -- payment --group "Goa trip" --from Aarav --amount 200
 *   npm run dev:data -- friend Riya
 *   npm run dev:data -- signin               print a sign-in for the simulator app (as "You")
 *   npm run dev:data -- signin --launch      also open the app on the booted simulator, signed in
 *   npm run dev:data -- list                 show your groups
 *   npm run dev:data -- ui-session           write .scratch/ui-session.json for the UI flows (a new,
 *                                            empty account each time, so runs never collide)
 *
 * Every person except "You" is a stable test friend (Aarav, Meera, Kabir, Zoya, or any
 * new name you pass). "You" is the same account the local fake Apple sign-in uses.
 *
 * Groups, expenses and payments go through the real API, so the server's own rules
 * (balances, activity, revisions) run exactly as they do for the app.
 */
import { randomUUID } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { mkdirSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { PrismaClient } from '@prisma/client'
import { apiRoot, assertLocalOnly, devApiBase, devDatabaseUrl, devJwtSecret } from './support/dev-env'

assertLocalOnly()
process.env.MOBILE_JWT_SECRET = devJwtSecret
process.env.NEXTAUTH_SECRET = devJwtSecret
process.env.DATABASE_URL = devDatabaseUrl

const db = new PrismaClient({ datasources: { db: { url: devDatabaseUrl } } })

type Json = Record<string, any>
type Person = { id: string; email: string; name: string; token: string }

const YOU = { id: 'dev-you', email: 'you@dev.billbandit.local', name: 'You', username: 'dev_you' }
const DEFAULT_FRIENDS = ['Aarav', 'Meera', 'Kabir']
const TRIP_NAMES = ['Goa weekend', 'Coorg homestay', 'Pondy road trip', 'Flat groceries', 'Office lunch club', 'Ladakh ride']
const EXPENSE_IDEAS = [
  { title: 'Dinner', amount: '2480.50', category: 'food' },
  { title: 'Cab to airport', amount: '845', category: 'travel' },
  { title: 'Groceries', amount: '1234.56', category: 'groceries' },
  { title: 'Hotel, 2 nights', amount: '9600', category: 'stay' },
  { title: 'Movie tickets', amount: '1100', category: 'fun' },
]

// ---------- arguments ----------

const [command = 'scenario', ...rest] = process.argv.slice(2)
const positional: string[] = []
const flags: Record<string, string | true> = {}
for (let index = 0; index < rest.length; index += 1) {
  const arg = rest[index]
  if (arg.startsWith('--')) {
    const next = rest[index + 1]
    if (next !== undefined && !next.startsWith('--')) { flags[arg.slice(2)] = next; index += 1 } else flags[arg.slice(2)] = true
  } else positional.push(arg)
}
const flag = (name: string) => (typeof flags[name] === 'string' ? (flags[name] as string) : undefined)
const pick = <T>(items: T[]) => items[Math.floor(Math.random() * items.length)]

// ---------- HTTP ----------

async function api(path: string, token: string, method = 'GET', body?: unknown, headers: Record<string, string> = {}) {
  let response: Response
  try {
    response = await fetch(new URL(path, devApiBase), {
      method,
      headers: {
        Accept: 'application/json',
        Authorization: `Bearer ${token}`,
        ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
        ...headers,
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    })
  } catch {
    throw new Error(`The local server is not running at ${devApiBase}. Start it with: npm run dev:server`)
  }
  const text = await response.text()
  let parsed: any = null
  try { parsed = text ? JSON.parse(text) : null } catch { parsed = text }
  if (response.status === 401) {
    throw new Error('The local server refused the sign-in. Start it with `npm run dev:server` so both use the same secret.')
  }
  if (!response.ok) throw new Error(`${method} ${path} failed (${response.status}): ${JSON.stringify(parsed).slice(0, 400)}`)
  return parsed as Json
}

// ---------- people ----------

async function tokenFor(user: { id: string; email: string; name: string | null }) {
  const { createMobileToken } = await import('../lib/mobile-auth')
  return createMobileToken(user)
}

async function ensureYou(): Promise<Person> {
  const user = await db.user.upsert({
    where: { email: YOU.email },
    update: {},
    create: { id: YOU.id, email: YOU.email, name: YOU.name, preferredName: YOU.name, username: YOU.username },
  })
  return { id: user.id, email: user.email, name: user.name ?? YOU.name, token: await tokenFor(user) }
}

async function ensureFriend(you: Person, rawName: string): Promise<Person> {
  const name = rawName.trim().replace(/^\w/, (letter) => letter.toUpperCase())
  const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, '_')
  const email = `${slug}@dev.billbandit.local`
  const user = await db.user.upsert({
    where: { email },
    update: {},
    create: { id: `dev-${slug}`, email, name, preferredName: name, username: `dev_${slug}`.slice(0, 30) },
  })
  const [fromId, toId] = [you.id, user.id].sort()
  await db.friendship.upsert({
    where: { fromId_toId: { fromId, toId } },
    update: { status: 'ACCEPTED' },
    create: { fromId, toId, status: 'ACCEPTED' },
  })
  return { id: user.id, email: user.email, name: user.name ?? name, token: await tokenFor(user) }
}

function personByName(people: Person[], name: string | undefined, fallback: Person) {
  if (!name) return fallback
  const found = people.find((person) => person.name.toLowerCase() === name.toLowerCase())
  if (!found) throw new Error(`"${name}" is not in this group. Members: ${people.map((p) => p.name).join(', ')}`)
  return found
}

// ---------- money ----------

function toMinor(amount: string, exponent: number): bigint {
  if (!/^\d+(\.\d+)?$/.test(amount)) throw new Error(`"${amount}" is not an amount. Use a number like 450 or 450.50.`)
  const [whole, fraction = ''] = amount.split('.')
  if (fraction.length > exponent) throw new Error(`${amount} has more decimals than this currency allows (${exponent}).`)
  return BigInt(whole + fraction.padEnd(exponent, '0'))
}

const money = (minor: bigint, currencyCode: string, currencyExponent: number) =>
  ({ minorUnits: minor.toString(), currencyCode, currencyExponent })

function equalShares(total: bigint, count: number) {
  const base = total / BigInt(count)
  const remainder = Number(total % BigInt(count))
  return Array.from({ length: count }, (_, index) => base + (index < remainder ? 1n : 0n))
}

function format(minor: string | bigint, currency: string, exponent: number) {
  const text = minor.toString().padStart(exponent + 1, '0')
  return exponent === 0 ? `${currency} ${text}` : `${currency} ${text.slice(0, -exponent)}.${text.slice(-exponent)}`
}

// ---------- groups ----------

async function readGroup(token: string, groupId: string) {
  return (await api(`/api/mobile/ledger/groups/${groupId}`, token)).data.group as Json
}

async function findGroup(you: Person, ref: string) {
  const summary = await api('/api/mobile/ledger?activityLimit=1', you.token)
  const groups = (summary.groups ?? []) as Json[]
  const match = groups.find((group) => (group.groupId ?? group.id) === ref)
    ?? groups.find((group) => String(group.name).toLowerCase() === ref.toLowerCase())
  if (!match) throw new Error(`No group called "${ref}". Run \`npm run dev:data -- list\` to see your groups.`)
  return readGroup(you.token, (match.groupId ?? match.id) as string)
}

async function membersOf(you: Person, group: Json): Promise<Person[]> {
  const people: Person[] = []
  for (const member of group.members as Json[]) {
    if (member.accountId === you.id) { people.push(you); continue }
    const user = await db.user.findUnique({ where: { id: member.accountId } })
    if (user) people.push({ id: user.id, email: user.email, name: user.name ?? user.email, token: await tokenFor(user) })
  }
  return people
}

async function createGroup(you: Person, name: string, currency: string, friends: Person[]) {
  const body = await api('/api/mobile/groups', you.token, 'POST',
    { name, currency, category: flag('category')?.toUpperCase() ?? 'TRIP', memberAccountIds: friends.map((f) => f.id) },
    { 'Idempotency-Key': `dev-group-${randomUUID()}` })
  const group = await readGroup(you.token, body.group.id)
  console.log(`+ Group "${name}" (${currency}) with ${[you, ...friends].map((p) => p.name).join(', ')}  id=${group.groupId ?? body.group.id}`)
  return group
}

async function addExpense(you: Person, group: Json, input: { title: string; amount: string; payer?: string; category?: string; notes?: string }) {
  const people = await membersOf(you, group)
  const payer = personByName(people, input.payer, you)
  const currency = group.baseCurrency.currencyCode as string
  const exponent = group.baseCurrency.currencyExponent as number
  const total = toMinor(input.amount, exponent)
  const shares = equalShares(total, people.length)
  const fresh = await readGroup(payer.token, group.groupId)
  const expenseId = randomUUID()
  await api('/api/mobile/expenses', payer.token, 'POST', {
    groupId: group.groupId,
    operationId: randomUUID(),
    expectedRevision: fresh.revision,
    expenseId,
    description: input.title,
    amount: money(total, currency, exponent),
    currency,
    paidById: payer.id,
    splitType: 'EQUAL',
    splits: people.map((person, index) => ({ id: `${expenseId}-${index}`, userId: person.id, amount: money(shares[index], currency, exponent) })),
    ...(input.category ? { category: input.category } : {}),
    ...(input.notes ? { notes: input.notes } : {}),
  })
  console.log(`+ Expense "${input.title}" ${format(total, currency, exponent)}, paid by ${payer.name}, split ${people.length} ways`)
}

async function addPayment(you: Person, group: Json, input: { from?: string; amount?: string }) {
  const people = await membersOf(you, group)
  const fresh = await readGroup(you.token, group.groupId)
  const memberFor = (person: Person) => (fresh.members as Json[]).find((m) => m.accountId === person.id)?.memberId
  const transfers = fresh.settlementPlan?.transfers as Json[] ?? []
  const payer = input.from ? personByName(people, input.from, you) : undefined
  const transfer = payer ? transfers.find((t) => t.payerMemberId === memberFor(payer)) : transfers[0]
  if (!transfer) throw new Error(payer ? `${payer.name} owes nothing in this group.` : 'Nobody owes anything in this group.')
  const payerPerson = people.find((p) => memberFor(p) === transfer.payerMemberId)!
  const recipient = people.find((p) => memberFor(p) === transfer.recipientMemberId)!
  const { currencyCode, currencyExponent } = transfer.amount
  const owed = BigInt(transfer.amount.minorUnits)
  const amount = input.amount ? toMinor(input.amount, currencyExponent) : owed / 2n || owed
  await api(`/api/groups/${group.groupId}/settlements`, payerPerson.token, 'POST', {
    expectedVersion: fresh.revision,
    planTransferId: transfer.planTransferId,
    payerParticipantId: transfer.payerMemberId,
    recipientParticipantId: transfer.recipientMemberId,
    currencyCode, currencyExponent, minorUnits: amount.toString(), note: 'Test payment',
  }, { 'Idempotency-Key': `dev-pay-${randomUUID()}` })
  console.log(`+ Payment ${format(amount, currencyCode, currencyExponent)} from ${payerPerson.name} to ${recipient.name} (owed ${format(owed, currencyCode, currencyExponent)})`)
}

// ---------- simulator sign-in ----------

function printSignIn(you: Person) {
  const storeId = 'vietnam-test-dev-you'
  console.log('\nSign in to the simulator app (Debug build) as "You":')
  console.log(`  SIMCTL_CHILD_BILLBANDIT_QA_STORE_ID=${storeId} \\`)
  console.log(`  SIMCTL_CHILD_BILLBANDIT_QA_BASE_URL=${devApiBase} \\`)
  console.log(`  SIMCTL_CHILD_BILLBANDIT_QA_TOKEN=${you.token} \\`)
  console.log('  xcrun simctl launch --terminate-running-process booted com.billbandit.app')
  if (flags.launch) {
    const booted = execFileSync('xcrun', ['simctl', 'list', 'devices', 'booted'], { encoding: 'utf8' })
    if (!/\(Booted\)/.test(booted)) throw new Error('No simulator is running. Boot one and install a Debug build of BillBandit first.')
    execFileSync('xcrun', ['simctl', 'launch', '--terminate-running-process', 'booted', 'com.billbandit.app'], {
      env: {
        ...process.env,
        SIMCTL_CHILD_BILLBANDIT_QA_STORE_ID: storeId,
        SIMCTL_CHILD_BILLBANDIT_QA_BASE_URL: devApiBase,
        SIMCTL_CHILD_BILLBANDIT_QA_TOKEN: you.token,
      },
      stdio: 'inherit',
    })
    console.log('Opened BillBandit on the booted simulator, signed in as You.')
  }
}

// ---------- commands ----------

async function main() {
  const you = await ensureYou()

  switch (command) {
    case 'scenario': {
      const friends = []
      for (const name of DEFAULT_FRIENDS) friends.push(await ensureFriend(you, name))
      const group = await createGroup(you, `${pick(TRIP_NAMES)} ${new Date().toISOString().slice(5, 16).replace('T', ' ')}`, flag('currency')?.toUpperCase() ?? 'INR', friends)
      const ideas = [...EXPENSE_IDEAS].sort(() => Math.random() - 0.5).slice(0, 3)
      const payers = [you.name, ...friends.map((f) => f.name)]
      for (const [index, idea] of ideas.entries()) await addExpense(you, group, { ...idea, payer: payers[index % payers.length] })
      await addPayment(you, group, {})
      printSignIn(you)
      break
    }
    case 'friend': {
      if (!positional[0]) throw new Error('Give a name: npm run dev:data -- friend Riya')
      const friend = await ensureFriend(you, positional[0])
      console.log(`+ ${friend.name} is your friend (id=${friend.id})`)
      break
    }
    case 'group': {
      const names = (flag('with') ?? DEFAULT_FRIENDS.join(',')).split(',').map((n) => n.trim()).filter(Boolean)
      const friends = []
      for (const name of names) friends.push(await ensureFriend(you, name))
      await createGroup(you, positional[0] ?? pick(TRIP_NAMES), flag('currency')?.toUpperCase() ?? 'INR', friends)
      break
    }
    case 'expense': {
      const ref = flag('group')
      if (!ref) throw new Error('Say which group: --group "Goa trip"')
      const idea = pick(EXPENSE_IDEAS)
      await addExpense(you, await findGroup(you, ref), {
        title: flag('title') ?? idea.title,
        amount: flag('amount') ?? idea.amount,
        payer: flag('payer'),
        category: flag('category') ?? (flag('title') ? undefined : idea.category),
        notes: flag('notes'),
      })
      break
    }
    case 'payment': {
      const ref = flag('group')
      if (!ref) throw new Error('Say which group: --group "Goa trip"')
      await addPayment(you, await findGroup(you, ref), { from: flag('from'), amount: flag('amount') })
      break
    }
    case 'ui-session': {
      // A brand-new account with no friends and no groups, so each UI run starts clean
      // without deleting anything. The UI flows read this file.
      const stamp = `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`
      const user = await db.user.create({
        data: { id: `dev-ui-${stamp}`, email: `ui-${stamp}@dev.billbandit.local`, name: 'UI Tester', preferredName: 'UI Tester', username: `ui_${stamp}`, defaultCurrency: 'INR' },
      })
      const file = resolve(apiRoot, '../../.scratch/ui-session.json')
      mkdirSync(resolve(file, '..'), { recursive: true })
      writeFileSync(file, JSON.stringify({ baseURL: devApiBase, accountID: user.id, token: await tokenFor(user), createdAt: new Date().toISOString() }, null, 2), { mode: 0o600 })
      console.log(`+ UI test account ${user.id}; wrote ${file}`)
      break
    }
    case 'signin':
      printSignIn(you)
      break
    case 'list': {
      const summary = await api('/api/mobile/ledger?activityLimit=1', you.token)
      const groups = (summary.groups ?? []) as Json[]
      if (groups.length === 0) console.log('You have no groups yet. Run: npm run dev:data')
      for (const group of groups) console.log(`- ${group.name}  id=${group.groupId ?? group.id}`)
      break
    }
    default:
      throw new Error(`Unknown command "${command}". Use: scenario, friend, group, expense, payment, signin, list, ui-session`)
  }
}

main()
  .catch((error) => {
    console.error(`\n${error instanceof Error ? error.message : error}`)
    process.exitCode = 1
  })
  .finally(() => db.$disconnect())
