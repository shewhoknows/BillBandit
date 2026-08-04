import { NextRequest, NextResponse } from 'next/server'
import type { GroupLedgerReadModel, Money } from './ledger-contract'
import type { ExpenseMutationInput } from './ledger/mutation'
import { exactMoneySchema } from './validations-mobile-ledger'
import { evaluateLedgerGate, readClientCapabilityHeaders } from './compatibility/ledger-gate'
import { LedgerMutationError } from './ledger/mutation'
import { accountIdForMember } from './mobile-groups'

export function formatCurrency(
  amount: number,
  currency = 'INR',
  locale = 'en-IN'
): string {
  return new Intl.NumberFormat(locale, {
    style: 'currency',
    currency,
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(amount)
}

export type MutationMetadata = {
  operationId: string
  expectedRevision: number
}

type JsonObject = Record<string, unknown>

function jsonObject(value: unknown): JsonObject {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? (value as JsonObject)
    : {}
}

function operationHeader(req: NextRequest): string | null {
  for (const name of ['Idempotency-Key', 'X-Operation-Id', 'X-Idempotency-Key']) {
    const value = req.headers.get(name)?.trim()
    if (value) return value
  }
  return null
}

function revisionValue(value: unknown): number | null {
  if (typeof value === 'number') {
    return Number.isSafeInteger(value) && value >= 0 ? value : null
  }
  if (typeof value !== 'string' || !/^\d+$/.test(value.trim())) return null
  const parsed = Number(value)
  return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : null
}

/** Read operation metadata from either the v2 body or its standard headers. */
export function readMutationMetadata(
  req: NextRequest,
  body: unknown
): { metadata: MutationMetadata } | { response: NextResponse } {
  const record = jsonObject(body)
  const bodyOperationId = typeof record.operationId === 'string' ? record.operationId.trim() : null
  const headerOperationId = operationHeader(req)
  const operationId = headerOperationId ?? bodyOperationId
  if (!operationId || operationId.length > 200 || /\s/.test(operationId)) {
    return {
      response: NextResponse.json(
        { error: 'operationId is required and must not contain whitespace' },
        { status: 400 }
      ),
    }
  }
  if (bodyOperationId && headerOperationId && bodyOperationId !== headerOperationId) {
    return {
      response: NextResponse.json(
        { error: 'operationId and Idempotency-Key must identify the same operation' },
        { status: 400 }
      ),
    }
  }

  const headerRevision = req.headers.get('Expected-Revision') ?? req.headers.get('X-Expected-Revision')
  const bodyRevision = record.expectedRevision
  const expectedRevision = revisionValue(headerRevision ?? bodyRevision)
  if (expectedRevision === null) {
    return {
      response: NextResponse.json(
        { error: 'expectedRevision is required and must be a non-negative integer' },
        { status: 400 }
      ),
    }
  }
  if (headerRevision !== null && bodyRevision !== undefined) {
    const parsedBodyRevision = revisionValue(bodyRevision)
    if (parsedBodyRevision !== expectedRevision) {
      return {
        response: NextResponse.json(
          { error: 'expectedRevision and Expected-Revision must agree' },
          { status: 400 }
        ),
      }
    }
  }

  return { metadata: { operationId, expectedRevision } }
}

export function hasExactMoney(value: unknown): value is Money {
  return exactMoneySchema.safeParse(value).success
}

export function legacySharedLedgerWriteResponse(req: NextRequest, reason = 'ledger-v2 is required') {
  const gate = evaluateLedgerGate(readClientCapabilityHeaders(req.headers))
  return NextResponse.json(
    {
      error: 'LEDGER_V2_REQUIRED',
      message: reason,
      readOnly: true,
      upgrade: {
        required: true,
        contract: 'ledger-v2',
        fields: ['operationId', 'expectedRevision', 'amount.minorUnits'],
      },
      gate: {
        outcome: gate.outcome,
        reasonCode: gate.reasonCode,
        allowed: gate.allowed,
        enforcementEnabled: gate.enforcementEnabled,
      },
    },
    { status: 409 }
  )
}

export function migrationReadOnlyResponse(model: GroupLedgerReadModel) {
  return NextResponse.json(
    {
      error: 'MONEY_MIGRATION_REQUIRED',
      groupId: model.groupId,
      readOnly: true,
      migration: model.migration,
    },
    { status: 409 }
  )
}

export function mutationErrorResponse(error: unknown, label: string) {
  if (error instanceof LedgerMutationError) {
    return NextResponse.json(
      {
        error: error.code,
        message: error.message,
        ...(error.details ? { details: error.details } : {}),
      },
      { status: error.status }
    )
  }
  console.error(label, error)
  return NextResponse.json({ error: 'Internal server error' }, { status: 500 })
}

function stringValue(value: unknown): string | null {
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null
}

function exactMoney(value: unknown): Money {
  if (!hasExactMoney(value)) {
    throw new LedgerMutationError('INVALID_MONEY', 400, 'Exact money is required')
  }
  return value
}

/** Translate the v2 member-keyed body into the kernel's account-keyed payload. */
export function toKernelExpensePayload(
  body: unknown,
  model: GroupLedgerReadModel,
  kind: 'expense.create' | 'expense.edit'
) {
  const record = jsonObject(body)
  const amount = exactMoney(record.amount)
  const paidByKey = stringValue(record.paidByMemberId) ?? stringValue(record.paidById) ?? stringValue(record.accountId)
  const paidById = accountIdForMember(model, paidByKey)
  if (!paidById) throw new LedgerMutationError('INVALID_MEMBERSHIP', 400, 'Payer is not a group member')

  const rawSplits = Array.isArray(record.splits) ? record.splits : []
  const splits: NonNullable<ExpenseMutationInput['splits']>[number][] = rawSplits.map((entry) => {
    const split = jsonObject(entry)
    const memberKey = stringValue(split.memberId) ?? stringValue(split.userId) ?? stringValue(split.accountId)
    const userId = accountIdForMember(model, memberKey)
    if (!userId) throw new LedgerMutationError('INVALID_MEMBERSHIP', 400, 'Split user is not a group member')
    const splitAmount = exactMoney(split.amount)
    const percentage =
      typeof split.percentage === 'number' || split.percentage === null
        ? split.percentage
        : undefined
    const shares = typeof split.shares === 'number' || split.shares === null ? split.shares : undefined
    const isPaid = typeof split.isPaid === 'boolean' ? split.isPaid : undefined
    const splitId = stringValue(split.splitId) ?? stringValue(split.id)
    return {
      ...(splitId ? { id: splitId } : {}),
      userId,
      amount: splitAmount,
      ...(percentage !== undefined ? { percentage } : {}),
      ...(shares !== undefined ? { shares } : {}),
      ...(isPaid !== undefined ? { isPaid } : {}),
    }
  })

  const expenseId = stringValue(record.expenseId) ?? stringValue(record.id)
  const date = record.date instanceof Date || typeof record.date === 'string' ? record.date : undefined
  const recurringEndDate =
    record.recurringEndDate instanceof Date || typeof record.recurringEndDate === 'string' || record.recurringEndDate === null
      ? record.recurringEndDate
      : undefined

  const splitTypeValue = record.splitType ?? record.splitMethod
  const splitType =
    splitTypeValue === 'EQUAL' ||
    splitTypeValue === 'EXACT' ||
    splitTypeValue === 'PERCENTAGE' ||
    splitTypeValue === 'SHARES'
      ? splitTypeValue
      : 'EQUAL'
  const recurringInterval =
    record.recurringInterval === 'DAILY' ||
    record.recurringInterval === 'WEEKLY' ||
    record.recurringInterval === 'MONTHLY' ||
    record.recurringInterval === 'YEARLY'
      ? record.recurringInterval
      : null
  const payload: ExpenseMutationInput = {
    ...(kind === 'expense.edit' || expenseId ? { expenseId: expenseId ?? undefined } : {}),
    description: typeof record.description === 'string' ? record.description : '',
    amount,
    currency: typeof record.currency === 'string' ? record.currency : amount.currencyCode,
    date,
    category: typeof record.category === 'string' ? record.category : 'general',
    groupId: model.groupId,
    paidById,
    splitType,
    splits,
    notes: record.notes === null || typeof record.notes === 'string' ? record.notes : null,
    receiptUrl: record.receiptUrl === null || typeof record.receiptUrl === 'string' ? record.receiptUrl : null,
    isRecurring: typeof record.isRecurring === 'boolean' ? record.isRecurring : false,
    recurringInterval,
    recurringEndDate,
  }
  return payload
}

export function toKernelExpenseDeletePayload(expenseId: string) {
  return { expenseId }
}
