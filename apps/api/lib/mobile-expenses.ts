import { prisma } from '@/lib/prisma'
import { NextResponse } from 'next/server'
import type { CreateExpenseInput } from '@/lib/validations-mobile-ledger'
import { dualWriteExpenseAmount } from '@/lib/settlement/version/sources'

export function roundAmount(amount: number): number {
  return Math.round(amount * 100) / 100
}

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

const userSelect = { id: true, name: true, image: true, email: true } as const

export const expenseInclude = {
  paidBy: { select: userSelect },
  splits: {
    select: {
      userId: true,
      amount: true,
      percentage: true,
      shares: true,
      user: { select: userSelect },
    },
  },
  group: { select: { id: true, name: true } },
} as const

export async function findAccessibleExpense(id: string, userId: string) {
  const expense = await prisma.expense.findUnique({
    where: { id, isDeleted: false },
    include: {
      paidBy: { select: userSelect },
      splits: { include: { user: { select: userSelect } } },
      group: { select: { id: true, name: true } },
    },
  })
  if (!expense) {
    return { expense: null, response: NextResponse.json({ error: 'Not found' }, { status: 404 }) }
  }

  const hasAccess =
    expense.paidById === userId || expense.splits.some((split) => split.userId === userId)
  if (!hasAccess) {
    return { expense: null, response: NextResponse.json({ error: 'Forbidden' }, { status: 403 }) }
  }
  return { expense, response: null }
}

export async function assertGroupExpenseAccess(
  groupId: string,
  userId: string
): Promise<{ ok: true } | { ok: false; response: NextResponse }> {
  const membership = await prisma.groupMember.findUnique({
    where: { groupId_userId: { groupId, userId } },
    include: { group: { select: { finalizedAt: true } } },
  })
  if (!membership) {
    return { ok: false, response: NextResponse.json({ error: 'Forbidden' }, { status: 403 }) }
  }
  if (membership.group.finalizedAt) {
    return { ok: false, response: NextResponse.json({ error: 'Group is finalized' }, { status: 409 }) }
  }
  return { ok: true }
}

export async function validateExpenseMembers(
  groupId: string,
  data: Pick<CreateExpenseInput, 'paidById' | 'splits'>
): Promise<{ ok: true } | { ok: false; response: NextResponse }> {
  const memberIds = (
    await prisma.groupMember.findMany({
      where: { groupId },
      select: { userId: true },
    })
  ).map((member) => member.userId)

  for (const split of data.splits) {
    if (!memberIds.includes(split.userId)) {
      return {
        ok: false,
        response: NextResponse.json(
          { error: `User ${split.userId} is not a member of this group` },
          { status: 400 }
        ),
      }
    }
  }
  if (!memberIds.includes(data.paidById)) {
    return {
      ok: false,
      response: NextResponse.json({ error: 'Payer is not a member of this group' }, { status: 400 }),
    }
  }
  return { ok: true }
}

export function validateSplitTotal(data: Pick<CreateExpenseInput, 'amount' | 'splits'>):
  | { ok: true }
  | { ok: false; response: NextResponse } {
  const splitTotal = data.splits.reduce((sum, split) => sum + split.amount, 0)
  if (Math.abs(splitTotal - data.amount) > 0.02) {
    return {
      ok: false,
      response: NextResponse.json(
        {
          error: `Split amounts (${splitTotal.toFixed(2)}) don't match expense total (${data.amount.toFixed(2)})`,
        },
        { status: 400 }
      ),
    }
  }
  return { ok: true }
}

export async function buildExpenseSplitCreates(
  splits: CreateExpenseInput['splits'],
  currency: string
) {
  return Promise.all(
    splits.map(async (split) => {
      const splitCanonical = await dualWriteExpenseAmount(roundAmount(split.amount), currency)
      return {
        userId: split.userId,
        amount: roundAmount(split.amount),
        amountMinorUnits: splitCanonical?.amountMinorUnits,
        currencyExponent: splitCanonical?.currencyExponent,
        percentage: split.percentage,
        shares: split.shares,
      }
    })
  )
}
