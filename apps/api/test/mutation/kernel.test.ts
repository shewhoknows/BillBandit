import assert from 'node:assert/strict'
import test from 'node:test'
import {
  executeMutation,
  MutationConflictError,
  type LedgerMutationRequest,
} from '../../lib/ledger/mutation'

type FakeState = {
  groups: Array<Record<string, unknown>>
  members: Array<Record<string, unknown>>
  users: Array<Record<string, unknown>>
  participants: Array<Record<string, unknown>>
  expenses: Array<Record<string, unknown>>
  splits: Array<Record<string, unknown>>
  operations: Array<Record<string, unknown>>
  journals: Array<Record<string, unknown>>
  outbox: Array<Record<string, unknown>>
}

function clone<T>(value: T): T {
  return structuredClone(value)
}

function selected<T extends Record<string, unknown>>(value: T, select?: Record<string, boolean>): T {
  if (!select) return clone(value)
  return Object.fromEntries(
    Object.entries(select)
      .filter(([, included]) => included)
      .map(([key]) => [key, value[key]])
  ) as T
}

class FakeTransaction {
  readonly group
  readonly groupMember
  readonly user
  readonly groupParticipant
  readonly expense
  readonly ledgerOperation
  readonly settlementVersionJournal
  readonly settlementOutbox

  constructor(public readonly state: FakeState) {
    this.group = {
      findUnique: async ({ where, select }: { where: { id: string }; select?: Record<string, boolean> }) => {
        const row = state.groups.find((entry) => entry.id === where.id)
        return row ? selected(row, select) : null
      },
      updateMany: async ({ where, data }: { where: Record<string, unknown>; data: Record<string, unknown> }) => {
        const row = state.groups.find(
          (entry) =>
            entry.id === where.id &&
            entry.settlementVersion === where.settlementVersion &&
            entry.isArchived === where.isArchived
        )
        if (!row) return { count: 0 }
        const increment = (data.settlementVersion as { increment: number }).increment
        row.settlementVersion = Number(row.settlementVersion) + increment
        return { count: 1 }
      },
    }

    this.groupMember = {
      findUnique: async ({ where, select }: { where: Record<string, unknown>; select?: Record<string, boolean> }) => {
        const compound = where.groupId_userId as { groupId: string; userId: string } | undefined
        const row = compound
          ? state.members.find(
              (entry) => entry.groupId === compound.groupId && entry.userId === compound.userId
            )
          : state.members.find((entry) => entry.id === where.id)
        return row ? selected(row, select) : null
      },
      findMany: async ({ where, select }: { where: { groupId: string }; select?: Record<string, boolean> }) =>
        state.members
          .filter((entry) => entry.groupId === where.groupId)
          .map((entry) => selected(entry, select)),
      create: async ({ data }: { data: Record<string, unknown> }) => {
        const row = { ...data }
        state.members.push(row)
        return clone(row)
      },
    }

    this.user = {
      findUnique: async ({ where, select }: { where: { id: string }; select?: Record<string, boolean> }) => {
        const row = state.users.find((entry) => entry.id === where.id)
        return row ? selected(row, select) : null
      },
    }

    this.groupParticipant = {
      findUnique: async ({ where }: { where: { id?: string; groupId_userId?: { groupId: string; userId: string } } }) => {
        const row = where.id
          ? state.participants.find((entry) => entry.id === where.id)
          : state.participants.find(
              (entry) =>
                entry.groupId === where.groupId_userId?.groupId &&
                entry.userId === where.groupId_userId?.userId
            )
        return row ? clone(row) : null
      },
      create: async ({ data }: { data: Record<string, unknown> }) => {
        const row = { ...data }
        state.participants.push(row)
        return clone(row)
      },
      update: async ({ where, data }: { where: { id: string }; data: Record<string, unknown> }) => {
        const row = state.participants.find((entry) => entry.id === where.id)
        if (!row) throw new Error('participant not found')
        Object.assign(row, data)
        return clone(row)
      },
    }

    this.expense = {
      findUnique: async ({ where, select }: { where: { id: string }; select?: Record<string, boolean> }) => {
        const row = state.expenses.find((entry) => entry.id === where.id)
        return row ? selected(row, select) : null
      },
      create: async ({ data }: { data: Record<string, unknown> }) => {
        const { splits, ...expenseData } = data
        const row = { ...expenseData }
        state.expenses.push(row)
        if (splits && typeof splits === 'object') {
          const create = (splits as { create?: Array<Record<string, unknown>> }).create ?? []
          for (const split of create) state.splits.push({ ...split, expenseId: row.id })
        }
        return clone(row)
      },
      update: async ({ where, data }: { where: { id: string }; data: Record<string, unknown> }) => {
        const row = state.expenses.find((entry) => entry.id === where.id)
        if (!row) throw new Error('expense not found')
        Object.assign(row, data)
        return clone(row)
      },
    }

    this.ledgerOperation = {
      upsert: async ({ where, create }: { where: { accountId_operationKey: { accountId: string; operationKey: string } }; create: Record<string, unknown> }) => {
        const key = where.accountId_operationKey
        const existing = state.operations.find(
          (entry) => entry.accountId === key.accountId && entry.operationKey === key.operationKey
        )
        if (existing) return clone(existing)
        const row = { ...create, createdAt: new Date() }
        state.operations.push(row)
        return clone(row)
      },
      update: async ({ where, data }: { where: { id: string }; data: Record<string, unknown> }) => {
        const row = state.operations.find((entry) => entry.id === where.id)
        if (!row) throw new Error('operation not found')
        Object.assign(row, data)
        return clone(row)
      },
    }

    this.settlementVersionJournal = {
      create: async ({ data }: { data: Record<string, unknown> }) => {
        state.journals.push({ ...data })
        return clone(data)
      },
    }
    this.settlementOutbox = {
      create: async ({ data }: { data: Record<string, unknown> }) => {
        state.outbox.push({ ...data })
        return clone(data)
      },
    }
  }
}

class FakeDatabase {
  private queue: Promise<unknown> = Promise.resolve()
  private failAfterCommit = false

  constructor(public state: FakeState) {}

  failNextAfterCommit(): void {
    this.failAfterCommit = true
  }

  $transaction<T>(callback: (transaction: FakeTransaction) => Promise<T>): Promise<T> {
    const run = this.queue.then(async () => {
      const transactionState = clone(this.state)
      const result = await callback(new FakeTransaction(transactionState))
      this.state = transactionState
      if (this.failAfterCommit) {
        this.failAfterCommit = false
        throw Object.assign(new Error('serialization failure after commit'), { code: 'P2034' })
      }
      return result
    })
    this.queue = run.catch(() => undefined)
    return run
  }
}

function database(): FakeDatabase {
  return new FakeDatabase({
    groups: [
      {
        id: 'group-1',
        settlementVersion: 0,
        simplifyDebts: true,
        isArchived: false,
        finalizedAt: null,
        currency: 'USD',
      },
    ],
    members: [{ id: 'member-actor', groupId: 'group-1', userId: 'actor-1', role: 'ADMIN' }],
    users: [{ id: 'actor-1', name: 'Actor' }],
    participants: [],
    expenses: [],
    splits: [],
    operations: [],
    journals: [],
    outbox: [],
  })
}

function request(operationId: string, amount = '125'): LedgerMutationRequest {
  return {
    accountId: 'actor-1',
    actorUserId: 'actor-1',
    groupId: 'group-1',
    operationId,
    expectedRevision: 0,
    kind: 'expense.create',
    payload: {
      expenseId: `expense-${operationId}`,
      description: 'Lunch',
      amount: { minorUnits: amount, currencyCode: 'USD', currencyExponent: 2 },
      paidById: 'actor-1',
      splitType: 'EXACT',
      splits: [
        {
          userId: 'actor-1',
          amount: { minorUnits: amount, currencyCode: 'USD', currencyExponent: 2 },
        },
      ],
    },
  }
}

test('one transaction applies an exact-money expense and journals invalidation', async () => {
  const db = database()
  const result = await executeMutation(request('op-1'), {
    db: db as never,
    now: () => new Date('2026-08-04T00:00:00.000Z'),
  })

  assert.equal(result.outcome, 'applied')
  assert.equal(result.revision, 1)
  assert.equal(result.authority.moneyAuthority, 'minor_units')
  assert.equal(db.state.groups[0].settlementVersion, 1)
  assert.equal(db.state.expenses.filter((row) => row.id === 'expense-op-1').length, 1)
  assert.equal(db.state.expenses[0].amountMinorUnits, 125n)
  assert.equal(db.state.journals.length, 1)
  assert.equal(db.state.outbox.length, 1)
})

test('identical retry replays without a second financial record', async () => {
  const db = database()
  const first = await executeMutation(request('op-replay'), { db: db as never })
  const second = await executeMutation(request('op-replay'), { db: db as never })

  assert.equal(first.outcome, 'applied')
  assert.equal(second.outcome, 'replayed')
  assert.equal(second.recordId, first.recordId)
  assert.equal(second.revision, first.revision)
  assert.equal(db.state.expenses.filter((row) => row.id === 'expense-op-replay').length, 1)
  assert.equal(db.state.groups[0].settlementVersion, 1)
  assert.equal(db.state.journals.length, 1)
})

test('same operation ID with a different canonical request is rejected with read-model hints', async () => {
  const db = database()
  await executeMutation(request('op-conflict'), { db: db as never })

  await assert.rejects(
    executeMutation(request('op-conflict', '126'), { db: db as never }),
    (error: unknown) => {
      assert.ok(error instanceof MutationConflictError)
      assert.equal(error.code, 'IDEMPOTENCY_KEY_REUSED')
      assert.equal(error.details?.currentRevision, 1)
      assert.equal((error.details?.readModel as { revision: number }).revision, 1)
      return true
    }
  )
})

test('a stale concurrent mutation loses at the revision reservation', async () => {
  const db = database()
  const results = await Promise.allSettled([
    executeMutation(request('op-a'), { db: db as never }),
    executeMutation(request('op-b'), { db: db as never }),
  ])
  assert.equal(results.filter((result) => result.status === 'fulfilled').length, 1)
  const rejected = results.find((result) => result.status === 'rejected')
  assert.ok(rejected && rejected.status === 'rejected')
  assert.ok(rejected.reason instanceof MutationConflictError)
  assert.equal(rejected.reason.code, 'REVISION_CONFLICT')
  assert.equal(rejected.reason.details?.currentRevision, 1)
  assert.equal(db.state.expenses.length, 1)
  assert.equal(db.state.journals.length, 1)
})

test('a timeout after commit retries by replaying the committed operation', async () => {
  const db = database()
  db.failNextAfterCommit()
  const result = await executeMutation(request('op-timeout'), {
    db: db as never,
    maxRetries: 1,
  })
  assert.equal(result.outcome, 'replayed')
  assert.equal(db.state.expenses.filter((row) => row.id === 'expense-op-timeout').length, 1)
  assert.equal(db.state.groups[0].settlementVersion, 1)
  assert.equal(db.state.journals.length, 1)
})
