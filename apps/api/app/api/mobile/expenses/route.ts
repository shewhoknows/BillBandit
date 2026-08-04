import { NextRequest, NextResponse } from 'next/server'
import { prisma } from '@/lib/prisma'
import { requireMobileSession } from '@/lib/mobile-auth'
import { loadAccountReadModel, loadGroupReadModel } from '@/lib/ledger/read-model/loader'
import { executeMutation } from '@/lib/ledger/mutation'
import { mobileExpenseV2Schema } from '@/lib/validations-mobile-ledger'
import {
  canonicalGroupIsReadOnly,
  findLedgerExpense,
  mobileExpenseFromLedger,
  readModelErrorResponse,
} from '@/lib/mobile-groups'
import { legacyAmount } from '@/lib/mobile-dto'
import {
  formatCurrency,
  legacySharedLedgerWriteResponse,
  migrationReadOnlyResponse,
  mutationErrorResponse,
  readMutationMetadata,
  toKernelExpensePayload,
} from '@/lib/mobile-expenses'

function finiteLimit(value: string | null): number {
  const parsed = Number.parseInt(value ?? '50', 10)
  return Number.isFinite(parsed) ? Math.min(Math.max(parsed, 1), 100) : 50
}

export async function GET(req: NextRequest) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  const { searchParams } = new URL(req.url)
  const groupId = searchParams.get('groupId')
  const limit = finiteLimit(searchParams.get('limit'))

  try {
    const models = groupId
      ? [(await loadGroupReadModel(groupId, session.user.id)).group]
      : (await loadAccountReadModel(session.user.id)).groups.map((projection) => projection.model)

    const expenses = models.flatMap((model) => {
      const currentMember = model.members.find((member) => member.accountId === session.user.id)
      return model.expenses
        .filter((expense) => {
          if (groupId) return expense.status === 'active'
          if (expense.status !== 'active') return false
          return (
            expense.paidByMemberId === currentMember?.memberId ||
            expense.splits.some((split) => split.memberId === currentMember?.memberId)
          )
        })
        .map((expense) => mobileExpenseFromLedger(model, expense.expenseId)!)
    })

    const sorted = expenses
      .sort((left, right) => String(right.date).localeCompare(String(left.date)) || left.id.localeCompare(right.id))
      .slice(0, limit)
    return NextResponse.json(
      {
        expenses: sorted,
        readRevision: models.reduce((max, model) => Math.max(max, model.readRevision), 0),
        readOnly: models.some(canonicalGroupIsReadOnly),
      },
      { headers: { 'Cache-Control': 'no-store' } }
    )
  } catch (error) {
    const errorResponse = readModelErrorResponse(error, groupId ?? undefined)
    if (errorResponse) return errorResponse
    console.error('[MOBILE GET /expenses]', error)
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 })
  }
}

export async function POST(req: NextRequest) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  let body: unknown
  try {
    body = await req.json()
  } catch {
    return legacySharedLedgerWriteResponse(req, 'A canonical v2 expense body is required')
  }
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    return NextResponse.json({ error: 'A JSON object is required' }, { status: 400 })
  }
  const record = body as Record<string, unknown>
  if (!record.groupId || typeof record.amount !== 'object' || Array.isArray(record.amount)) {
    return legacySharedLedgerWriteResponse(req, 'Shared-ledger expenses require exact-money v2 fields')
  }

  const parsed = mobileExpenseV2Schema.safeParse(record)
  if (!parsed.success) {
    return NextResponse.json({ error: parsed.error.errors[0].message }, { status: 400 })
  }
  const metadataResult = readMutationMetadata(req, record)
  if ('response' in metadataResult) return metadataResult.response

  try {
    const groupRead = await loadGroupReadModel(parsed.data.groupId, session.user.id)
    if (canonicalGroupIsReadOnly(groupRead.group)) return migrationReadOnlyResponse(groupRead.group)

    const payload = toKernelExpensePayload(parsed.data, groupRead.group, 'expense.create')
    const result = await executeMutation({
      groupId: parsed.data.groupId,
      operationId: metadataResult.metadata.operationId,
      expectedRevision: metadataResult.metadata.expectedRevision,
      kind: 'expense.create',
      accountId: session.user.id,
      actorUserId: session.user.id,
      payload,
    })

    if (result.outcome === 'applied') {
      const amount = legacyAmount(parsed.data.amount) ?? 0
      await prisma.activityLog.create({
        data: {
          userId: session.user.id,
          type: 'EXPENSE_CREATED',
          description: `${session.user.name ?? 'Someone'} added "${parsed.data.description}" (${formatCurrency(amount, parsed.data.amount.currencyCode)})`,
          metadata: {
            expenseId: result.recordId,
            groupId: parsed.data.groupId,
            operationId: result.operationId,
          },
        },
      })
    }

    const after = await loadGroupReadModel(parsed.data.groupId, session.user.id)
    const expense = findLedgerExpense(after.group, result.recordId)
    return NextResponse.json(
      {
        expense: expense ? mobileExpenseFromLedger(after.group, expense.expenseId) : null,
        mutation: result,
        revision: result.revision,
        readModel: after.envelope,
      },
      { status: result.replayed ? 200 : 201 }
    )
  } catch (error) {
    const errorResponse = readModelErrorResponse(error, parsed.data.groupId)
    if (errorResponse) return errorResponse
    return mutationErrorResponse(error, '[MOBILE POST /expenses]')
  }
}
