import { randomUUID } from 'node:crypto'
import { PrismaClient } from '@prisma/client'
import { createMobileToken, createReviewResetToken } from '../lib/mobile-auth'
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
    username: `${name.toLowerCase()}_bb`,
  })),
]

async function main() {
  const database = process.env.DATABASE_URL
  if (!database) throw new Error('DATABASE_URL is required')
  const parsed = new URL(database)
  if (!['postgres:', 'postgresql:'].includes(parsed.protocol) || !parsed.hostname) throw new Error('DATABASE_URL must identify a PostgreSQL host')
  console.log(`Database host: ${parsed.hostname}`)
  if (!process.argv.slice(2).includes('--confirm')) throw new Error('Pass --confirm to reset the reviewer world')
  const teardown = process.argv.slice(2).includes('--teardown')
  const base = process.env.REVIEW_API_BASE_URL
  if (!teardown && !base) throw new Error('REVIEW_API_BASE_URL is required')
  const apiURL = base ? new URL(base) : null
  if (apiURL && !['http:', 'https:'].includes(apiURL.protocol)) throw new Error('REVIEW_API_BASE_URL must be HTTP or HTTPS')
  if (!teardown && !process.env.MOBILE_JWT_SECRET && !process.env.NEXTAUTH_SECRET) throw new Error('MOBILE_JWT_SECRET or NEXTAUTH_SECRET is required')
  const db = new PrismaClient()
  const ids = definitions.map(({ id }) => id)
  const allowed = new Set(ids)
  try {
    if (!teardown && apiURL) {
      const health = await fetch(new URL('/api/health', apiURL), { signal: AbortSignal.timeout(10000) })
      if (!health.ok) throw new Error(`Review API health check failed with HTTP ${health.status}; reset refused`)
      const current = await db.user.findUnique({ where: { id: REVIEW_ACCOUNT_ID }, select: { deletedAt: true } })
      if (current && !current.deletedAt) {
        const authorization = await fetch(new URL('/api/mobile/auth/me', apiURL), {
          headers: { Authorization: `Bearer ${createReviewResetToken(definitions[0])}` },
          signal: AbortSignal.timeout(10000),
        })
        if (!authorization.ok) throw new Error(`Review API reset authorization failed with HTTP ${authorization.status}; reset refused`)
      }
    }
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
      const sessions = await tx.session.count({ where: { userId: { in: ids } } })
      const imports = await tx.ledgerImport.count({ where: { accountId: { in: ids } } })
      const importRecords = await tx.ledgerImportRecord.count({ where: { accountId: { in: ids } } })
      if (linkedAccounts || identities || sessions || imports || importRecords) throw new Error('A reviewer account has external data; operation refused')
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
        const participantIds = new Set(group.participants.map((participant) => participant.id))
        if (group.transactions.some((transaction) => [transaction.payerParticipantId, transaction.recipientParticipantId]
          .some((id) => id !== null && !participantIds.has(id)))) {
          throw new Error(`Group ${group.id} refers to a participant outside the demo group; operation refused`)
        }
      }
      const stray = await tx.transaction.count({ where: { AND: [{ OR: [{ senderId: { in: ids } }, { receiverId: { in: ids } }, { actorUserId: { in: ids } }] }, { OR: [{ groupId: null }, { groupId: { notIn: groupIds } }] }] } })
      if (stray) throw new Error('A reviewer account has transactions outside the demo groups; reset refused')
      const outside = { OR: [{ groupId: null }, { groupId: { notIn: groupIds } }] }
      const strayExpenses = await tx.expense.count({ where: { AND: [outside, { OR: [
        { paidById: { in: ids } }, { createdById: { in: ids } },
        { splits: { some: { userId: { in: ids } } } }, { comments: { some: { userId: { in: ids } } } },
      ] }] } })
      const strayFinalized = await tx.group.count({ where: { finalizedById: { in: ids }, id: { notIn: groupIds } } })
      const strayOperations = await tx.ledgerOperation.count({ where: { accountId: { in: ids }, ...outside } })
      const strayAudits = await tx.settlementSettingAudit.count({ where: { actorUserId: { in: ids }, groupId: { notIn: groupIds } } })
      const strayReversals = await tx.settlementReversal.count({ where: { actorUserId: { in: ids }, groupId: { notIn: groupIds } } })
      if (strayExpenses || strayFinalized || strayOperations || strayAudits || strayReversals) {
        throw new Error('A reviewer account has data outside the demo groups; operation refused')
      }
      const allocations = await tx.settlementAllocation.findMany({
        where: { groupId: { in: groupIds } },
        include: { transaction: true, paths: true },
      })
      for (const allocation of allocations) {
        const group = groups.find((item) => item.id === allocation.groupId)!
        const participantIds = new Set(group.participants.map((participant) => participant.id))
        if (allocation.transaction.groupId !== group.id || allocation.paths.some((path) =>
          !participantIds.has(path.payerParticipantId) || !participantIds.has(path.recipientParticipantId))) {
          throw new Error(`Group ${group.id} contains an external settlement reference; operation refused`)
        }
      }
      const reversals = await tx.settlementReversal.findMany({
        where: { groupId: { in: groupIds } }, include: { transaction: true },
      })
      if (reversals.some((reversal) => reversal.transaction.groupId !== reversal.groupId)) {
        throw new Error('A demo group contains an external reversal reference; operation refused')
      }
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
      if (teardown) {
        await tx.user.deleteMany({ where: { id: { in: ids } } })
        return
      }
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

    if (teardown) {
      console.log('Reviewer demo teardown complete')
      return
    }
    if (!apiURL) throw new Error('REVIEW_API_BASE_URL is required')
    const resetAPIURL = apiURL
    const people: Person[] = definitions.map((person) => ({
      ...person, token: person.id === REVIEW_ACCOUNT_ID ? createReviewResetToken(person) : createMobileToken(person),
    }))
    const [reviewer, aarav, kabir, ira] = people
    async function api(path: string, person: Person, method = 'GET', body?: unknown, headers: Record<string, string> = {}): Promise<Json> {
      const response = await fetch(new URL(path, resetAPIURL), {
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
    async function pay(id: string, partial: boolean, recipient?: Person) {
      const fresh = await read(id, reviewer)
      const reviewerMember = (fresh.members as Json[]).find((m) => m.accountId === reviewer.id)
      const recipientMember = recipient && (fresh.members as Json[]).find((m) => m.accountId === recipient.id)
      const transfer = recipient
        ? fresh.settlementPlan?.transfers?.find((t: Json) => t.payerMemberId === reviewerMember?.memberId && t.recipientMemberId === recipientMember?.memberId)
        : fresh.settlementPlan?.transfers?.[0]
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
    await expense(goa, 'Beach shack dinner', 1000000n, aarav, people)
    await expense(goa, 'Scooter rental', 240000n, reviewer, people)
    await expense(goa, 'Fuel', 65050n, kabir, people)
    await expense(goa, 'Ferry tickets', 120000n, ira, [reviewer, kabir, ira])
    await pay(goa, true, aarav)
    const flat = await group('Flat 4B', [kabir])
    await expense(flat, 'Groceries', 120000n, reviewer, [reviewer, kabir])
    await expense(flat, 'Internet', 60000n, kabir, [reviewer, kabir])
    await pay(flat, true)
    console.log('Reviewer demo reset complete: Goa Trip and Flat 4B')
  } finally {
    await db.$disconnect()
  }
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : 'Reviewer reset failed')
  process.exitCode = 1
})
