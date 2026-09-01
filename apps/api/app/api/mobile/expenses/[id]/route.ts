import { NextRequest, NextResponse } from 'next/server'
import { prisma } from '@/lib/prisma'
import { requireMobileSession } from '@/lib/mobile-auth'
import { loadAccountReadModel, loadGroupReadModel } from '@/lib/ledger/read-model/loader'
import { executeMutation } from '@/lib/ledger/mutation'
import {
  mobileExpenseDeleteV2Schema,
  mobileExpenseV2Schema,
} from '@/lib/validations-mobile-ledger'
import {
  canonicalGroupIsReadOnly,
  findLedgerExpense,
  mobileExpenseFromLedger,
  readModelErrorResponse,
} from '@/lib/mobile-groups'
import { legacyAmount } from '@/lib/mobile-dto'
import {
  formatCurrency,
  hasExactMoney,
  legacySharedLedgerWriteResponse,
  migrationReadOnlyResponse,
  mutationErrorResponse,
  readMutationMetadata,
  toKernelExpenseDeletePayload,
  toKernelExpensePayload,
} from '@/lib/mobile-expenses'

async function findExpenseGroup(accountId: string, expenseId: string) {
  const account = await loadAccountReadModel(accountId)
  for (const projection of account.groups) {
    const expense = findLedgerExpense(projection.model, expenseId)
    if (expense && expense.status === 'active') {
      return { model: projection.model, expense }
    }
  }
  return null
}

function objectBody(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null
}

export async function GET(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  try {
    const found = await findExpenseGroup(session.user.id, params.id)
    if (!found) return NextResponse.json({ error: 'Not found' }, { status: 404 })
    return NextResponse.json(
      { expense: mobileExpenseFromLedger(found.model, found.expense.expenseId), revision: found.model.readRevision },
      { headers: { 'Cache-Control': 'no-store' } }
    )
  } catch (error) {
    const errorResponse = readModelErrorResponse(error)
    if (errorResponse) return errorResponse
    console.error('[MOBILE GET /expenses/:id]', error)
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 })
  }
}

export async function PUT(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  let rawBody: unknown
  try {
    rawBody = await req.json()
  } catch {
    return legacySharedLedgerWriteResponse(req, 'A canonical exact-money expense body is required')
  }
  const initialBody = objectBody(rawBody)
  if (!initialBody || !hasExactMoney(initialBody.amount)) {
    return legacySharedLedgerWriteResponse(req, 'Shared-ledger expense edits require exact-money v2 fields')
  }

  try {
    const found = await findExpenseGroup(session.user.id, params.id)
    if (!found) return NextResponse.json({ error: 'Not found' }, { status: 404 })
    const body = {
      ...initialBody,
      groupId: initialBody.groupId ?? found.model.groupId,
      expenseId: params.id,
    }
    if (body.groupId !== found.model.groupId) {
      return NextResponse.json({ error: 'Expense groupId cannot change' }, { status: 400 })
    }
    const parsed = mobileExpenseV2Schema.safeParse(body)
    if (!parsed.success) {
      return NextResponse.json({ error: parsed.error.errors[0].message }, { status: 400 })
    }
    const metadataResult = readMutationMetadata(req, body)
    if ('response' in metadataResult) return metadataResult.response

    const groupRead = await loadGroupReadModel(found.model.groupId, session.user.id)
    if (canonicalGroupIsReadOnly(groupRead.group)) return migrationReadOnlyResponse(groupRead.group)
    const payload = toKernelExpensePayload(parsed.data, groupRead.group, 'expense.edit')
    const result = await executeMutation({
      groupId: groupRead.group.groupId,
      operationId: metadataResult.metadata.operationId,
      expectedRevision: metadataResult.metadata.expectedRevision,
      kind: 'expense.edit',
      accountId: session.user.id,
      actorUserId: session.user.id,
      payload,
    })

    if (result.outcome === 'applied') {
      const amount = legacyAmount(parsed.data.amount) ?? 0
      await prisma.activityLog.create({
        data: {
          userId: session.user.id,
          type: 'EXPENSE_UPDATED',
          description: `${session.user.name ?? 'Someone'} updated "${parsed.data.description}" (${formatCurrency(amount, parsed.data.amount.currencyCode)})`,
          metadata: { expenseId: params.id, operationId: result.operationId },
        },
      })
    }

    const after = await loadGroupReadModel(groupRead.group.groupId, session.user.id)
    const expense = findLedgerExpense(after.group, params.id)
    return NextResponse.json(
      {
        expense: expense ? mobileExpenseFromLedger(after.group, params.id) : null,
        mutation: result,
        revision: result.revision,
        readModel: after.envelope,
      },
      { status: 200 }
    )
  } catch (error) {
    const errorResponse = readModelErrorResponse(error)
    if (errorResponse) return errorResponse
    return mutationErrorResponse(error, '[MOBILE PUT /expenses/:id]')
  }
}

export async function DELETE(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  let rawBody: unknown = {}
  try {
    rawBody = await req.json()
  } catch {
    // The metadata check below turns an empty-body legacy delete into a
    // bounded upgrade response.
  }
  const body = objectBody(rawBody)
  if (!body) return legacySharedLedgerWriteResponse(req, 'A canonical v2 delete body is required')
  if (
    !body.operationId &&
    !req.headers.get('Idempotency-Key') &&
    !req.headers.get('X-Operation-Id') &&
    body.expectedRevision === undefined &&
    !req.headers.get('Expected-Revision')
  ) {
    return legacySharedLedgerWriteResponse(req, 'Shared-ledger deletes require operationId and expectedRevision')
  }

  const parsed = mobileExpenseDeleteV2Schema.safeParse(body)
  if (!parsed.success) {
    return NextResponse.json({ error: parsed.error.errors[0].message }, { status: 400 })
  }
  const metadataResult = readMutationMetadata(req, body)
  if ('response' in metadataResult) return metadataResult.response

  try {
    const found = await findExpenseGroup(session.user.id, params.id)
    if (!found) return NextResponse.json({ error: 'Not found' }, { status: 404 })
    if (canonicalGroupIsReadOnly(found.model)) return migrationReadOnlyResponse(found.model)
    const groupRead = await loadGroupReadModel(found.model.groupId, session.user.id)
    if (canonicalGroupIsReadOnly(groupRead.group)) return migrationReadOnlyResponse(groupRead.group)

    const result = await executeMutation({
      groupId: groupRead.group.groupId,
      operationId: metadataResult.metadata.operationId,
      expectedRevision: metadataResult.metadata.expectedRevision,
      kind: 'expense.delete',
      accountId: session.user.id,
      actorUserId: session.user.id,
      payload: toKernelExpenseDeletePayload(params.id),
    })

    if (result.outcome === 'applied') {
      await prisma.activityLog.create({
        data: {
          userId: session.user.id,
          type: 'EXPENSE_DELETED',
          description: `${session.user.name ?? 'Someone'} deleted "${found.expense.description}"`,
          metadata: { expenseId: params.id, operationId: result.operationId },
        },
      })
    }

    const after = await loadGroupReadModel(groupRead.group.groupId, session.user.id)
    return NextResponse.json({
      success: true,
      expenseId: params.id,
      mutation: result,
      revision: result.revision,
      readModel: after.envelope,
    })
  } catch (error) {
    const errorResponse = readModelErrorResponse(error)
    if (errorResponse) return errorResponse
    return mutationErrorResponse(error, '[MOBILE DELETE /expenses/:id]')
  }
}
