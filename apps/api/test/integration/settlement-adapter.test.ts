import assert from 'node:assert/strict'
import test from 'node:test'
import type { PrismaClient } from '@prisma/client'
import { executeReversal } from '../../lib/settlement/commands/reverse'
import { executeSettingChange } from '../../lib/settlement/commands/setting'
import { executeSettlement } from '../../lib/settlement/commands/settle'
import { buildPlanTransferId } from '../../lib/settlement/money/transfer-id'

type Row = Record<string, any>

type FakeState = {
  groups: Row[]
  members: Row[]
  participants: Row[]
  expenses: Row[]
  transactions: Row[]
  allocations: Row[]
  reversals: Row[]
  audits: Row[]
  operations: Row[]
  journals: Row[]
  outbox: Row[]
}

function clone<T>(value: T): T {
  return structuredClone(value)
}

function groupRow(state: FakeState, id: string): Row | null {
  return state.groups.find((group) => group.id === id) ?? null
}

function participantRow(state: FakeState, where: Row): Row | null {
  if (where.id) return state.participants.find((participant) => participant.id === where.id) ?? null
  const key = where.groupId_userId
  return state.participants.find(
    (participant) => participant.groupId === key.groupId && participant.userId === key.userId
  ) ?? null
}

function memberRow(state: FakeState, where: Row): Row | null {
  const key = where.groupId_userId
  return state.members.find(
    (member) => member.groupId === key.groupId && member.userId === key.userId
  ) ?? null
}

class FakeTransaction {
  constructor(private readonly state: FakeState) {}

  readonly group = {
    findUnique: async ({ where }: Row) => {
      const row = groupRow(this.state, where.id)
      return row ? clone(row) : null
    },
    updateMany: async ({ where, data }: Row) => {
      const row = groupRow(this.state, where.id)
      if (!row || row.settlementVersion !== where.settlementVersion || row.isArchived !== where.isArchived) {
        return { count: 0 }
      }
      row.settlementVersion += data.settlementVersion.increment
      return { count: 1 }
    },
    update: async ({ where, data }: Row) => {
      const row = groupRow(this.state, where.id)
      if (!row) throw new Error('group not found')
      Object.assign(row, data)
      return clone(row)
    },
  }

  readonly groupMember = {
    findUnique: async ({ where }: Row) => {
      const row = memberRow(this.state, where)
      return row ? clone(row) : null
    },
  }

  readonly groupParticipant = {
    findUnique: async ({ where }: Row) => {
      const row = participantRow(this.state, where)
      return row ? clone(row) : null
    },
    findMany: async ({ where }: Row) =>
      this.state.participants
        .filter((participant) => participant.groupId === where.groupId)
        .map(clone),
  }

  readonly expense = {
    findMany: async ({ where }: Row) =>
      this.state.expenses
        .filter((expense) => expense.groupId === where.groupId && expense.isDeleted === false)
        .map(clone),
  }

  readonly transaction = {
    findUnique: async ({ where }: Row) => {
      const row = this.state.transactions.find((transaction) => transaction.id === where.id)
      return row ? clone(row) : null
    },
    findMany: async ({ where }: Row) =>
      this.state.transactions
        .filter((transaction) => transaction.groupId === where.groupId)
        .sort((left, right) => left.createdAt.getTime() - right.createdAt.getTime())
        .map(clone),
    create: async ({ data }: Row) => {
      const row = {
        ...data,
        createdAt: new Date(),
        allocation: null,
        reversal: null,
      }
      this.state.transactions.push(row)
      return clone(row)
    },
  }

  readonly settlementAllocation = {
    create: async ({ data }: Row) => {
      const paths = (data.paths?.create ?? []).map((path: Row) => ({ ...path }))
      const row = { ...data, paths }
      delete row.paths
      this.state.allocations.push(row)
      const transaction = this.state.transactions.find((entry) => entry.id === data.transactionId)
      if (transaction) transaction.allocation = { paths }
      return clone({ ...row, paths })
    },
  }

  readonly settlementReversal = {
    create: async ({ data }: Row) => {
      const row = { ...data, createdAt: new Date() }
      this.state.reversals.push(row)
      const transaction = this.state.transactions.find((entry) => entry.id === data.transactionId)
      if (transaction) transaction.reversal = row
      return clone(row)
    },
  }

  readonly settlementSettingAudit = {
    create: async ({ data }: Row) => {
      const row = { ...data, createdAt: new Date() }
      this.state.audits.push(row)
      return clone(row)
    },
  }

  readonly ledgerOperation = {
    upsert: async ({ where, create }: Row) => {
      const key = where.accountId_operationKey
      const existing = this.state.operations.find(
        (operation) => operation.accountId === key.accountId && operation.operationKey === key.operationKey
      )
      if (existing) return clone(existing)
      const row = { ...create, createdAt: new Date() }
      this.state.operations.push(row)
      return clone(row)
    },
    update: async ({ where, data }: Row) => {
      const row = this.state.operations.find((operation) => operation.id === where.id)
      if (!row) throw new Error('operation not found')
      Object.assign(row, data)
      return clone(row)
    },
  }

  readonly settlementVersionJournal = {
    create: async ({ data }: Row) => {
      this.state.journals.push({ ...data, createdAt: new Date() })
      return clone(data)
    },
  }

  readonly settlementOutbox = {
    create: async ({ data }: Row) => {
      this.state.outbox.push({ ...data, createdAt: new Date() })
      return clone(data)
    },
  }
}

class FakeDatabase {
  constructor(public state: FakeState) {}

  readonly settlementAllocation = {
    findUnique: async ({ where }: Row) => {
      const row = this.state.allocations.find((allocation) => allocation.transactionId === where.transactionId)
      return row ? { id: row.id } : null
    },
  }

  async $transaction<T>(callback: (tx: FakeTransaction) => Promise<T>): Promise<T> {
    const next = clone(this.state)
    const result = await callback(new FakeTransaction(next))
    this.state = next
    return result
  }
}

function database(): FakeDatabase {
  return new FakeDatabase({
    groups: [{
      id: 'group-1',
      settlementVersion: 0,
      simplifyDebts: true,
      isArchived: false,
      finalizedAt: null,
      currency: 'USD',
    }],
    members: [
      { id: 'member-alice', groupId: 'group-1', userId: 'alice', role: 'ADMIN' },
      { id: 'member-bob', groupId: 'group-1', userId: 'bob', role: 'MEMBER' },
    ],
    participants: [
      { id: 'participant-alice', groupId: 'group-1', userId: 'alice', displayName: 'Alice', status: 'ACTIVE' },
      { id: 'participant-bob', groupId: 'group-1', userId: 'bob', displayName: 'Bob', status: 'ACTIVE' },
    ],
    expenses: [{
      id: 'expense-1',
      groupId: 'group-1',
      paidById: 'alice',
      currency: 'USD',
      amountMinorUnits: 1000n,
      currencyExponent: 2,
      isDeleted: false,
      splits: [{
        id: 'split-1',
        userId: 'bob',
        amountMinorUnits: 1000n,
        currencyExponent: 2,
      }],
    }],
    transactions: [],
    allocations: [],
    reversals: [],
    audits: [],
    operations: [],
    journals: [],
    outbox: [],
  })
}

test('settlement adapter delegates writes and replays without duplicate records', async () => {
  const db = database()
  const client = db as unknown as PrismaClient
  const transferId = buildPlanTransferId({
    groupId: 'group-1',
    settlementVersion: 0,
    mode: 'SIMPLIFIED',
    amount: { currencyCode: 'USD', currencyExponent: 2, minorUnits: 1000n },
    payerParticipantId: 'participant-bob',
    recipientParticipantId: 'participant-alice',
  })

  const settlementInput = {
    groupId: 'group-1',
    userId: 'bob',
    idempotencyKey: 'settlement-key',
    expectedVersion: 0,
    planTransferId: transferId,
    payerParticipantId: 'participant-bob',
    recipientParticipantId: 'participant-alice',
    currencyCode: 'USD',
    currencyExponent: 2,
    minorUnits: '1000',
    note: 'paid',
    db: client,
  } as const

  const firstSettlement = await executeSettlement(settlementInput)
  const replayedSettlement = await executeSettlement(settlementInput)

  assert.equal(firstSettlement.recordId, replayedSettlement.recordId)
  assert.equal(firstSettlement.version, 1)
  assert.equal(replayedSettlement.version, 1)
  assert.equal(db.state.transactions.length, 1)
  assert.equal(db.state.allocations.length, 1)
  assert.equal(db.state.transactions[0].amountMinorUnits, 1000n)
  assert.equal(db.state.transactions[0].amount, 10)
  assert.equal(db.state.journals.length, 1)
  assert.equal(db.state.outbox.length, 1)

  const reversalInput = {
    groupId: 'group-1',
    userId: 'bob',
    settlementId: firstSettlement.recordId,
    idempotencyKey: 'reversal-key',
    expectedVersion: 1,
    db: client,
  } as const
  const firstReversal = await executeReversal(reversalInput)
  const replayedReversal = await executeReversal(reversalInput)

  assert.equal(firstReversal.recordId, replayedReversal.recordId)
  assert.equal(firstReversal.version, 2)
  assert.equal(db.state.reversals.length, 1)
  assert.equal(db.state.journals.length, 2)
  assert.equal(db.state.outbox.length, 2)

  const settingInput = {
    groupId: 'group-1',
    userId: 'alice',
    idempotencyKey: 'setting-key',
    expectedVersion: 2,
    simplifyDebts: false,
    db: client,
  } as const
  const firstSetting = await executeSettingChange(settingInput)
  const replayedSetting = await executeSettingChange(settingInput)

  assert.equal(firstSetting.recordId, replayedSetting.recordId)
  assert.equal(firstSetting.version, 3)
  assert.equal(db.state.audits.length, 1)
  assert.equal(db.state.groups[0].simplifyDebts, false)
  assert.equal(db.state.journals.length, 3)
  assert.equal(db.state.outbox.length, 3)
})
