import { NextRequest, NextResponse } from 'next/server'
import { prisma } from '@/lib/prisma'
import { createExpenseSchema } from '@/lib/validations-mobile-ledger'
import { requireMobileSession } from '@/lib/mobile-auth'
import { mobileExpense } from '@/lib/mobile-dto'
import {
  assertGroupExpenseAccess,
  buildExpenseSplitCreates,
  expenseInclude,
  findAccessibleExpense,
  formatCurrency,
  roundAmount,
  validateExpenseMembers,
  validateSplitTotal,
} from '@/lib/mobile-expenses'
import { dualWriteExpenseAmount, onGroupExpenseMutation } from '@/lib/settlement/version/sources'

export async function GET(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  const { expense, response: expenseResponse } = await findAccessibleExpense(params.id, session.user.id)
  if (!expense) return expenseResponse
  return NextResponse.json({ expense: mobileExpense(expense) })
}

export async function PUT(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  const existing = await prisma.expense.findUnique({
    where: { id: params.id, isDeleted: false },
    select: {
      paidById: true,
      groupId: true,
      group: { select: { finalizedAt: true } },
    },
  })
  if (!existing) return NextResponse.json({ error: 'Not found' }, { status: 404 })
  if (existing.paidById !== session.user.id) {
    return NextResponse.json({ error: 'Only the payer can edit an expense' }, { status: 403 })
  }
  if (existing.group?.finalizedAt) {
    return NextResponse.json({ error: 'Group is finalized' }, { status: 409 })
  }

  try {
    const body = await req.json()
    const parsed = createExpenseSchema.safeParse(body)
    if (!parsed.success) {
      return NextResponse.json({ error: parsed.error.errors[0].message }, { status: 400 })
    }

    const data = parsed.data
    if (data.groupId) {
      const access = await assertGroupExpenseAccess(data.groupId, session.user.id)
      if (!access.ok) return access.response

      const members = await validateExpenseMembers(data.groupId, data)
      if (!members.ok) return members.response
    }

    const splitCheck = validateSplitTotal(data)
    if (!splitCheck.ok) return splitCheck.response

    const canonical = await dualWriteExpenseAmount(roundAmount(data.amount), data.currency)

    await prisma.expenseSplit.deleteMany({ where: { expenseId: params.id } })
    const updated = await prisma.expense.update({
      where: { id: params.id },
      data: {
        description: data.description,
        amount: roundAmount(data.amount),
        amountMinorUnits: canonical?.amountMinorUnits,
        currencyExponent: canonical?.currencyExponent,
        currency: data.currency,
        date: new Date(data.date),
        category: data.category,
        groupId: data.groupId,
        paidById: data.paidById,
        splitType: data.splitType,
        notes: data.notes,
        splits: {
          create: await buildExpenseSplitCreates(data.splits, data.currency),
        },
      },
      include: expenseInclude,
    })

    const groupId = existing.groupId ?? data.groupId
    if (groupId) {
      await onGroupExpenseMutation(groupId, params.id, 'expense_updated')
    }

    await prisma.activityLog.create({
      data: {
        userId: session.user.id,
        type: 'EXPENSE_UPDATED',
        description: `${session.user.name} updated "${data.description}" (${formatCurrency(data.amount, data.currency)})`,
        metadata: { expenseId: params.id },
      },
    })

    return NextResponse.json({ expense: mobileExpense(updated) })
  } catch (error) {
    console.error('[MOBILE PUT /expenses/[id]]', error)
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 })
  }
}

export async function DELETE(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  const expense = await prisma.expense.findUnique({
    where: { id: params.id },
    select: {
      paidById: true,
      description: true,
      groupId: true,
      group: { select: { finalizedAt: true } },
    },
  })
  if (!expense) return NextResponse.json({ error: 'Not found' }, { status: 404 })
  if (expense.paidById !== session.user.id) {
    return NextResponse.json({ error: 'Only the payer can delete an expense' }, { status: 403 })
  }
  if (expense.group?.finalizedAt) {
    return NextResponse.json({ error: 'Group is finalized' }, { status: 409 })
  }

  await prisma.expense.update({ where: { id: params.id }, data: { isDeleted: true } })

  if (expense.groupId) {
    await onGroupExpenseMutation(expense.groupId, params.id, 'expense_deleted')
  }

  await prisma.activityLog.create({
    data: {
      userId: session.user.id,
      type: 'EXPENSE_DELETED',
      description: `${session.user.name} deleted "${expense.description}"`,
      metadata: { expenseId: params.id },
    },
  })

  return NextResponse.json({ success: true })
}
