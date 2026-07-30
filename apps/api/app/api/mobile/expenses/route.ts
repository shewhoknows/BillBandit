import { NextRequest, NextResponse } from 'next/server'
import { prisma } from '@/lib/prisma'
import { createExpenseSchema } from '@/lib/validations-mobile-ledger'
import { requireMobileSession } from '@/lib/mobile-auth'
import { mobileExpense } from '@/lib/mobile-dto'
import {
  assertGroupExpenseAccess,
  buildExpenseSplitCreates,
  expenseInclude,
  formatCurrency,
  roundAmount,
  validateExpenseMembers,
  validateSplitTotal,
} from '@/lib/mobile-expenses'
import { dualWriteExpenseAmount, onGroupExpenseMutation } from '@/lib/settlement/version/sources'

export async function GET(req: NextRequest) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  const { searchParams } = new URL(req.url)
  const groupId = searchParams.get('groupId')
  const limit = parseInt(searchParams.get('limit') ?? '50')

  const where: {
    isDeleted: boolean
    OR?: Array<
      | { paidById: string }
      | { splits: { some: { userId: string } } }
    >
    groupId?: string
  } = {
    isDeleted: false,
    OR: [
      { paidById: session.user.id },
      { splits: { some: { userId: session.user.id } } },
    ],
  }

  if (groupId) {
    const membership = await prisma.groupMember.findUnique({
      where: { groupId_userId: { groupId, userId: session.user.id } },
    })
    if (!membership) return NextResponse.json({ error: 'Forbidden' }, { status: 403 })
    where.groupId = groupId
    delete where.OR
  }

  const expenses = await prisma.expense.findMany({
    where,
    include: expenseInclude,
    orderBy: { date: 'desc' },
    take: Number.isFinite(limit) ? Math.min(Math.max(limit, 1), 100) : 50,
  })

  return NextResponse.json({ expenses: expenses.map(mobileExpense) })
}

export async function POST(req: NextRequest) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

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

    const expense = await prisma.expense.create({
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
        isRecurring: data.isRecurring,
        recurringInterval: data.recurringInterval,
        splits: {
          create: await buildExpenseSplitCreates(data.splits, data.currency),
        },
      },
      include: expenseInclude,
    })

    if (data.groupId) {
      await onGroupExpenseMutation(data.groupId, expense.id, 'expense_created')
    }

    await prisma.activityLog.create({
      data: {
        userId: session.user.id,
        type: 'EXPENSE_CREATED',
        description: `${session.user.name} added "${data.description}" (${formatCurrency(data.amount, data.currency)})`,
        metadata: { expenseId: expense.id, groupId: data.groupId },
      },
    })

    return NextResponse.json({ expense: mobileExpense(expense) }, { status: 201 })
  } catch (error) {
    console.error('[MOBILE POST /expenses]', error)
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 })
  }
}
