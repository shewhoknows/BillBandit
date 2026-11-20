import { randomUUID } from 'node:crypto'
import { PrismaClient } from '@prisma/client'
import { createMobileToken } from '../lib/mobile-auth'
import { executeMutation } from '../lib/ledger/mutation/kernel'
import { REVIEW_ACCOUNT_EMAIL, REVIEW_ACCOUNT_ID, REVIEW_ACCOUNT_USERNAME } from '../lib/review-account'

type Json = Record<string, any>
type Person = { id: string; email: string; name: string; username: string; token: string }

const definitions = [
  { id: REVIEW_ACCOUNT_ID, email: REVIEW_ACCOUNT_EMAIL, name: 'App Reviewer', username: REVIEW_ACCOUNT_USERNAME },
  ...['Aarav', 'Kabir', 'Ira'].map((name) => ({
    id: `billbandit-review-${name.toLowerCase()}-v1`,
    email: `${name.toLowerCase()}@review.billbandit.invalid`,
    name,
    username: `review_${name.toLowerCase()}`,
  })),
]

async function main() {
  const database = process.env.DATABASE_URL
  if (!database) throw new Error('DATABASE_URL is required')
  const parsed = new URL(database)
  if (!['postgres:', 'postgresql:'].includes(parsed.protocol) || !parsed.hostname) throw new Error('DATABASE_URL must identify a PostgreSQL host')
  console.log(`Database host: ${parsed.hostname}`)
  if (!process.argv.slice(2).includes('--confirm')) throw new Error('Pass --confirm to reset the reviewer world')
  const base = process.env.REVIEW_API_BASE_URL
  if (!base) throw new Error('REVIEW_API_BASE_URL is required')
  const apiURL = new URL(base)
  if (!['http:', 'https:'].includes(apiURL.protocol)) throw new Error('REVIEW_API_BASE_URL must be HTTP or HTTPS')
  if (!process.env.MOBILE_JWT_SECRET && !process.env.NEXTAUTH_SECRET) throw new Error('MOBILE_JWT_SECRET or NEXTAUTH_SECRET is required')
  const db = new PrismaClient()
  const ids = definitions.map(({ id }) => id)
  const allowed = new Set(ids)
  try {
    await db.$transaction(async (tx) => {
      const existing = await tx.user.findMany({ where: { OR: [{ id: { in: ids } }, { email: { in: definitions.map((d) => d.email) } }, { username: { in: definitions.map((d) => d.username) } }] } })
      for (const user of existing) {
        const definition = definitions.find((d) => d.id === user.id)
        const deletedEmail = `deleted+${user.id}@deleted.billbandit.invalid`
        if (!definition || (user.email !== definition.email && !(user.deletedAt && user.email === deletedEmail))) {
          throw new Error('A reserved reviewer identity belongs to another account; reset refused')
        }
      }
      const linkedAccounts = await tx.account.count({ where: { userId: { in: ids } } })
      const identities = await tx.externalIdentity.count({ where: { accountId: { in: ids } } })
      if (linkedAccounts || identities) throw new Error('A reviewer account has an external identity; reset refused')
      const friendships = await tx.friendship.findMany({ where: { OR: [{ fromId: { in: ids } }, { toId: { in: ids } }] } })
      if (friendships.some((f) => !allowed.has(f.fromId) || !allowed.has(f.toId))) throw new Error('A reviewer account has a non-demo friendship; reset refused')
      const groups = await tx.group.findMany({
        where: { OR: [{ members: { some: { userId: { in: ids } } } }, { participants: { some: { userId: { in: ids } } } }] },
        include: {
          members: true, participants: true, expenses: { include: { splits: true, comments: true } },
          transactions: true, settlementSettingAudits: true, settlementReversals: true, ledgerOperations: true,
        },
      })
      const groupIds = groups.map((g) => g.id)
      for (const group of groups) {
        const people = [
          group.finalizedById, ...group.members.map((m) => m.userId), ...group.participants.map((p) => p.userId),
          ...group.expenses.flatMap((e) => [e.paidById, e.createdById, ...e.splits.map((s) => s.userId), ...e.comments.map((c) => c.userId)]),
          ...group.transactions.flatMap((t) => [t.senderId, t.receiverId, t.actorUserId]),
          ...group.settlementSettingAudits.map((a) => a.actorUserId), ...group.settlementReversals.map((r) => r.actorUserId),
          ...group.ledgerOperations.map((o) => o.accountId),
        ].filter((id): id is string => id !== null)
        if (people.some((id) => !allowed.has(id))) throw new Error(`Group ${group.id} contains non-demo data; reset refused`)
      }
      const stray = await tx.transaction.count({ where: { OR: [{ senderId: { in: ids } }, { receiverId: { in: ids } }, { actorUserId: { in: ids } }], NOT: { groupId: { in: groupIds } } } })
      if (stray) throw new Error('A reviewer account has transactions outside the demo groups; reset refused')
      const allocations = await tx.settlementAllocation.findMany({ where: { groupId: { in: groupIds } }, select: { id: true } })
      await tx.settlementAllocationPath.deleteMany({ where: { allocationId: { in: allocations.map((a) => a.id) } } })
      await tx.settlementReversal.deleteMany({ where: { groupId: { in: groupIds } } })
      await tx.settlementAllocation.deleteMany({ where: { groupId: { in: groupIds } } })
      await tx.transaction.deleteMany({ where: { groupId: { in: groupIds } } })
      await tx.settlementSettingAudit.deleteMany({ where: { groupId: { in: groupIds } } })
      await tx.settlementVersionJournal.deleteMany({ where: { groupId: { in: groupIds } } })
      await tx.settlementOutbox.deleteMany({ where: { groupId: { in: groupIds } } })
      await tx.idempotentOperation.deleteMany({ where: { groupId: { in: groupIds } } })
      await tx.ledgerOperation.deleteMany({ where: { groupId: { in: groupIds } } })
      await tx.groupParticipant.deleteMany({ where: { groupId: { in: groupIds } } })
      await tx.group.deleteMany({ where: { id: { in: groupIds } } })
      await tx.friendship.deleteMany({ where: { OR: [{ fromId: { in: ids } }, { toId: { in: ids } }] } })
      await tx.friendInvitation.deleteMany({ where: { inviterId: { in: ids } } })
      await tx.friendClaimRateLimit.deleteMany({ where: { accountId: { in: ids } } })
      await tx.activityLog.deleteMany({ where: { userId: { in: ids } } })
      for (const person of definitions) {
        await tx.user.upsert({
          where: { id: person.id },
          create: { ...person, preferredName: person.name, defaultCurrency: 'INR' },
          update: { email: person.email, username: person.username, name: person.name, preferredName: person.name, defaultCurrency: 'INR', emailVerified: null, image: null, phone: null, upiID: null, password: null, deletedAt: null },
        })
      }
      for (const friend of definitions.slice(1)) {
        const [fromId, toId] = [REVIEW_ACCOUNT_ID, friend.id].sort()
        await tx.friendship.create({ data: { fromId, toId, status: 'ACCEPTED' } })
      }
    }, { isolationLevel: 'Serializable', timeout: 30000 })

    const people: Person[] = definitions.map((person) => ({ ...person, token: createMobileToken(person) }))
    const [reviewer, aarav, kabir, ira] = people
    async function api(path: string, person: Person, method = 'GET', body?: unknown, headers: Record<string, string> = {}): Promise<Json> {
      const response = await fetch(new URL(path, apiURL), {
        method, headers: { Authorization: `Bearer ${person.token}`, 'Content-Type': 'application/json', ...headers },
        body: body === undefined ? undefined : JSON.stringify(body),
      })
      if (!response.ok) throw new Error(`${method} ${path} failed with HTTP ${response.status}`)
      return response.json() as Promise<Json>
    }
    async function group(name: string, friends: Person[]): Promise<string> {
      const result = await api('/api/mobile/groups', reviewer, 'POST', {
        name, currency: 'INR', category: name === 'Goa Trip' ? 'TRIP' : 'HOME', memberAccountIds: friends.map((f) => f.id),
      }, { 'Idempotency-Key': randomUUID() })
      return result.group.id as string
    }
    const money = (minor: bigint) => ({ minorUnits: minor.toString(), currencyCode: 'INR', currencyExponent: 2 })
    async function read(id: string, person: Person): Promise<Json> {
      return (await api(`/api/mobile/ledger/groups/${id}`, person)).data.group
    }
    async function expense(id: string, title: string, minor: bigint, payer: Person, participants: Person[]) {
      const fresh = await read(id, payer)
      const expenseId = randomUUID()
      const count = BigInt(participants.length)
      await api('/api/mobile/expenses', payer, 'POST', {
        groupId: id, operationId: randomUUID(), expectedRevision: fresh.revision, expenseId,
        description: title, amount: money(minor), currency: 'INR', paidById: payer.id, splitType: 'EQUAL',
        splits: participants.map((p, i) => ({ id: `${expenseId}-${i}`, userId: p.id, amount: money(minor / count + (BigInt(i) < minor % count ? 1n : 0n)) })),
      })
    }
    async function pay(id: string, partial: boolean) {
      const fresh = await read(id, reviewer)
      const transfer = fresh.settlementPlan?.transfers?.[0]
      if (!transfer) throw new Error(`No settlement transfer in ${id}`)
      const member = (fresh.members as Json[]).find((m) => m.memberId === transfer.payerMemberId)
      const payer = people.find((p) => p.id === member?.accountId)
      if (!payer) throw new Error('Settlement payer is not a demo account')
      const total = BigInt(transfer.amount.minorUnits)
      const amount = partial ? total / 2n : total
      await api(`/api/groups/${id}/settlements`, payer, 'POST', {
        expectedVersion: fresh.revision, planTransferId: transfer.planTransferId,
        payerParticipantId: transfer.payerMemberId, recipientParticipantId: transfer.recipientMemberId,
        currencyCode: 'INR', currencyExponent: 2, minorUnits: amount.toString(), note: 'Review demo payment',
      }, { 'Idempotency-Key': randomUUID() })
    }
    const goa = await group('Goa Trip', [aarav, kabir, ira])
    const initialGoa = await read(goa, reviewer)
    await executeMutation({
      groupId: goa, operationId: randomUUID(), kind: 'settings.update',
      expectedRevision: initialGoa.revision, actorUserId: reviewer.id, payload: { simplifyDebts: false },
    }, { db })
    await expense(goa, 'Beach shack dinner', 324000n, aarav, people)
    await expense(goa, 'Scooter rental', 180000n, reviewer, people)
    await expense(goa, 'Fuel', 65050n, kabir, people)
    await expense(goa, 'Ferry tickets', 120000n, ira, [reviewer, kabir, ira])
    await pay(goa, true)
    const flat = await group('Flat 4B', [kabir])
    await expense(flat, 'Groceries', 120000n, reviewer, [reviewer, kabir])
    await expense(flat, 'Internet', 60000n, kabir, [reviewer, kabir])
    await pay(flat, false)
    console.log('Reviewer demo reset complete: Goa Trip and Flat 4B')
  } finally {
    await db.$disconnect()
  }
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : 'Reviewer reset failed')
  process.exitCode = 1
})
