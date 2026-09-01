import { NextResponse } from 'next/server'
import type { GroupLedgerReadModel, Money } from './ledger-contract'
import { mobileExpense, mobileGroup, legacyAmount } from './mobile-dto'
import { LedgerReadModelError } from './ledger/read-model/types'

function isReadOnly(model: GroupLedgerReadModel): boolean {
  return (
    model.migration.status === 'blocked' ||
    model.migration.status === 'pending' ||
    model.migration.status === 'in_progress'
  )
}

export function canonicalGroupIsReadOnly(model: GroupLedgerReadModel): boolean {
  return isReadOnly(model)
}

function memberMap(model: GroupLedgerReadModel) {
  return new Map(model.members.map((member) => [member.memberId, member]))
}

function accountMap(model: GroupLedgerReadModel) {
  return new Map(model.members.map((member) => [member.accountId, member]))
}

export function accountIdForMember(
  model: GroupLedgerReadModel,
  value: string | null | undefined
): string | null {
  if (!value) return null
  const byMember = memberMap(model).get(value)
  if (byMember) return byMember.accountId
  return accountMap(model).has(value) ? value : null
}

export function memberForAccount(model: GroupLedgerReadModel, accountId: string) {
  return model.members.find((member) => member.accountId === accountId) ?? null
}

function userForMember(model: GroupLedgerReadModel, memberId: string) {
  const member = memberMap(model).get(memberId)
  if (!member) return null
  return {
    id: member.accountId,
    name: member.displayName,
    email: member.email,
    image: null,
  }
}

function mobileCanonicalExpense(model: GroupLedgerReadModel, expenseId: string) {
  const expense = model.expenses.find((entry) => entry.expenseId === expenseId)
  if (!expense) return null
  const payer = memberMap(model).get(expense.paidByMemberId)
  return mobileExpense({
    id: expense.expenseId,
    description: expense.description,
    amount: expense.amount,
    currency: expense.amount.currencyCode,
    date: expense.createdAt,
    category: 'general',
    groupId: model.groupId,
    group: { id: model.groupId, name: model.name },
    paidById: payer?.accountId ?? expense.paidByMemberId,
    paidByMemberId: expense.paidByMemberId,
    paidBy: payer
      ? {
          id: payer.accountId,
          name: payer.displayName,
          email: payer.email,
          image: null,
        }
      : null,
    splitType: expense.splitMethod,
    status: expense.status,
    splits: expense.splits.map((split) => {
      const member = memberMap(model).get(split.memberId)
      return {
        id: split.splitId,
        splitId: split.splitId,
        memberId: split.memberId,
        userId: member?.accountId ?? split.memberId,
        amount: split.amount,
        percentage: split.percentage,
        shares: split.shares,
        user: member
          ? {
              id: member.accountId,
              name: member.displayName,
              email: member.email,
              image: null,
            }
          : null,
      }
    }),
    updatedAt: expense.updatedAt,
  })
}

export function mobileExpenseFromLedger(model: GroupLedgerReadModel, expenseId: string) {
  return mobileCanonicalExpense(model, expenseId)
}

export function mobileGroupFromLedger(model: GroupLedgerReadModel) {
  return mobileGroup({
    groupId: model.groupId,
    name: model.name,
    currency: model.baseCurrency.currencyCode,
    members: model.members.map((member) => ({
      memberId: member.memberId,
      accountId: member.accountId,
      role: member.role,
      displayName: member.displayName,
      email: member.email,
    })),
    expenses: model.expenses.map((expense) => mobileCanonicalExpense(model, expense.expenseId)!).filter(Boolean),
    revision: model.revision,
    readRevision: model.readRevision,
    readOnly: isReadOnly(model),
    migration: model.migration,
    authority: model.authority,
  })
}

function moneyForBaseCurrency(values: Money[], currencyCode: string, currencyExponent: number): Money {
  return (
    values.find((value) => value.currencyCode === currencyCode) ?? {
      minorUnits: '0',
      currencyCode,
      currencyExponent,
    }
  )
}

export function buildGroupDetailResponseFromLedger(model: GroupLedgerReadModel) {
  const members = memberMap(model)
  const netBalances = model.balances.byMember.map((balance) => {
    const member = members.get(balance.memberId)
    const money = moneyForBaseCurrency(
      balance.byCurrency,
      model.baseCurrency.currencyCode,
      model.baseCurrency.currencyExponent
    )
    return {
      userId: member?.accountId ?? balance.memberId,
      memberId: balance.memberId,
      name: member?.displayName ?? null,
      image: null,
      netAmount: legacyAmount(money) ?? 0,
      money,
      byCurrency: balance.byCurrency,
    }
  })

  const simplifiedDebts = model.settlementPlan.transfers.map((transfer) => {
    const from = members.get(transfer.payerMemberId)
    const to = members.get(transfer.recipientMemberId)
    return {
      fromId: from?.accountId ?? transfer.payerMemberId,
      toId: to?.accountId ?? transfer.recipientMemberId,
      fromMemberId: transfer.payerMemberId,
      toMemberId: transfer.recipientMemberId,
      amount: legacyAmount(transfer.amount) ?? 0,
      money: transfer.amount,
      fromName: from?.displayName ?? null,
      toName: to?.displayName ?? null,
    }
  })

  return {
    group: mobileGroupFromLedger(model),
    balances: { netBalances, simplifiedDebts },
    ledger: model,
  }
}

export function findLedgerExpense(model: GroupLedgerReadModel, expenseId: string) {
  return model.expenses.find((expense) => expense.expenseId === expenseId) ?? null
}

export function readModelErrorResponse(error: unknown, groupId?: string) {
  if (!(error instanceof LedgerReadModelError)) return null
  const typed = error as LedgerReadModelError
  if (typed.code === 'GROUP_NOT_FOUND') {
    const forbidden = typed.details?.forbidden === true
    return NextResponse.json(
      { error: forbidden ? 'Forbidden' : 'Group not found' },
      { status: forbidden ? 403 : 404 }
    )
  }
  if (typed.code === 'MONEY_REPRESENTATION_UNAVAILABLE' || typed.code === 'UNSUPPORTED_CURRENCY') {
    return NextResponse.json(
      {
        error: 'MONEY_MIGRATION_REQUIRED',
        ...(groupId ? { groupId } : {}),
        readOnly: true,
        migration: {
          status: 'blocked',
          source: 'cloudkit',
          migrationId: groupId ? `money-migration:${groupId}` : null,
          importedAt: null,
          dualWriteEnabled: false,
          recoveryReadOnly: true,
        },
        details: typed.details ?? {},
      },
      { status: 409 }
    )
  }
  return NextResponse.json(
    {
      error: 'LEDGER_READ_UNAVAILABLE',
      ...(groupId ? { groupId } : {}),
      readOnly: true,
      details: typed.details ?? {},
    },
    { status: 409 }
  )
}
