import type { Money } from './ledger-contract'

export type MobileMoney = Money

type UserInput = {
  id: string
  username?: string | null
  name?: string | null
  email?: string | null
  image?: string | null
  phone?: string | null
  preferredName?: string | null
  upiID?: string | null
}

type MemberInput = {
  id?: string
  memberId?: string
  accountId?: string
  userId?: string
  role: string
  joinedAt?: Date | string | null
  user?: UserInput | null
  displayName?: string | null
  email?: string | null
}

type ExpenseSplitInput = {
  id?: string | null
  splitId?: string | null
  memberId?: string | null
  userId?: string
  accountId?: string
  amount: number | MobileMoney | null
  money?: MobileMoney | null
  amountMinorUnits?: string | bigint | null
  currencyExponent?: number | null
  percentage?: number | string | null
  shares?: number | null
  user?: UserInput | null
}

type ExpenseInput = {
  id?: string
  expenseId?: string
  description: string
  amount: number | MobileMoney | null
  money?: MobileMoney | null
  amountMinorUnits?: string | bigint | null
  currencyExponent?: number | null
  currency?: string
  date?: Date | string | null
  category?: string | null
  groupId?: string | null
  group?: { id: string; name: string } | null
  paidById?: string
  paidByMemberId?: string | null
  paidBy?: UserInput | null
  splitType?: string
  splitMethod?: string
  notes?: string | null
  splits?: ExpenseSplitInput[]
  createdAt?: Date | string | null
  updatedAt?: Date | string | null
  status?: string
}

function isMoney(value: unknown): value is MobileMoney {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false
  const candidate = value as Record<string, unknown>
  return (
    typeof candidate.minorUnits === 'string' &&
    typeof candidate.currencyCode === 'string' &&
    typeof candidate.currencyExponent === 'number'
  )
}

function moneyFromFields(input: {
  amount: number | MobileMoney | null
  money?: MobileMoney | null
  amountMinorUnits?: string | bigint | null
  currencyExponent?: number | null
  currency?: string
}): MobileMoney | null {
  if (isMoney(input.money)) return input.money
  if (isMoney(input.amount)) return input.amount
  if (input.amountMinorUnits === null || input.amountMinorUnits === undefined) return null
  if (input.currencyExponent === null || input.currencyExponent === undefined) return null
  if (!input.currency) return null
  return {
    minorUnits: input.amountMinorUnits.toString(),
    currencyCode: input.currency.toUpperCase(),
    currencyExponent: input.currencyExponent,
  }
}

/** Convert exact money only for the bounded legacy response field. */
export function legacyAmount(value: MobileMoney | number | null | undefined): number | null {
  if (typeof value === 'number') return Number.isFinite(value) ? value : null
  if (!isMoney(value)) return null
  const result = Number(value.minorUnits) / 10 ** value.currencyExponent
  return Number.isFinite(result) ? result : null
}

export function mobileUser(user: UserInput) {
  return {
    id: user.id,
    username: user.username ?? null,
    name: user.name ?? null,
    email: user.email ?? null,
    image: user.image ?? null,
    phone: user.phone ?? null,
    preferredName: user.preferredName ?? null,
    upiID: user.upiID ?? null,
    hasUsername: Boolean(user.username),
    isProfileComplete: Boolean((user.name ?? user.preferredName) && user.upiID),
  }
}

export function mobileMember(member: MemberInput) {
  const canonical = Boolean(member.memberId && member.accountId)
  const memberId = member.memberId ?? member.id ?? null
  const accountId = member.accountId ?? member.userId ?? member.user?.id ?? ''
  const user = member.user ?? {
    id: accountId,
    name: member.displayName ?? null,
    email: member.email ?? null,
    image: null,
  }
  const role = canonical
    ? member.role === 'owner'
      ? 'ADMIN'
      : 'MEMBER'
    : member.role

  return {
    userId: accountId,
    memberId,
    role,
    joinedAt:
      member.joinedAt instanceof Date
        ? member.joinedAt.toISOString()
        : member.joinedAt ?? null,
    user: mobileUser(user),
  }
}

export function mobileExpense(expense: ExpenseInput) {
  const id = expense.id ?? expense.expenseId ?? ''
  const money = moneyFromFields(expense)
  const currency = money?.currencyCode ?? expense.currency ?? 'INR'
  const paidById = expense.paidById ?? expense.paidByMemberId ?? ''
  const splitType = expense.splitType ?? expense.splitMethod ?? 'EQUAL'

  return {
    id,
    description: expense.description,
    // This number is a compatibility projection. `money` is authoritative.
    amount: legacyAmount(money ?? expense.amount),
    money,
    amountMinorUnits: money?.minorUnits ?? null,
    currencyExponent: money?.currencyExponent ?? null,
    currency,
    date:
      expense.date instanceof Date
        ? expense.date.toISOString()
        : expense.date ?? null,
    category: expense.category ?? 'general',
    groupId: expense.groupId ?? null,
    group: expense.group ? { id: expense.group.id, name: expense.group.name } : null,
    paidById,
    paidByMemberId: expense.paidByMemberId ?? null,
    paidBy: expense.paidBy ? mobileUser(expense.paidBy) : null,
    splitType,
    notes: expense.notes ?? null,
    status: expense.status ?? 'active',
    splits: (expense.splits ?? []).map((split) => {
      const splitMoney = moneyFromFields({
        amount: split.amount,
        money: split.money,
        amountMinorUnits: split.amountMinorUnits,
        currencyExponent: split.currencyExponent,
        currency,
      })
      return {
        id: split.id ?? split.splitId ?? null,
        splitId: split.splitId ?? split.id ?? null,
        memberId: split.memberId ?? null,
        userId: split.userId ?? split.accountId ?? split.memberId ?? '',
        amount: legacyAmount(splitMoney ?? split.amount),
        money: splitMoney,
        amountMinorUnits: splitMoney?.minorUnits ?? null,
        currencyExponent: splitMoney?.currencyExponent ?? null,
        percentage:
          typeof split.percentage === 'string'
            ? Number(split.percentage)
            : split.percentage ?? null,
        shares: split.shares ?? null,
        user: split.user ? mobileUser(split.user) : null,
      }
    }),
    createdAt:
      expense.createdAt instanceof Date
        ? expense.createdAt.toISOString()
        : expense.createdAt ?? null,
    updatedAt:
      expense.updatedAt instanceof Date
        ? expense.updatedAt.toISOString()
        : expense.updatedAt ?? null,
  }
}

type GroupInput = {
  id?: string
  groupId?: string
  name: string
  description?: string | null
  image?: string | null
  currency?: string
  baseCurrency?: { currencyCode: string; currencyExponent: number }
  category?: string | null
  finalizedAt?: Date | string | null
  finalizedById?: string | null
  members?: MemberInput[]
  expenses?: ExpenseInput[]
  _count?: { expenses?: number; members?: number }
  revision?: number
  readRevision?: number
  readOnly?: boolean
  migration?: unknown
  authority?: unknown
  createdAt?: Date | string | null
  updatedAt?: Date | string | null
}

export function mobileGroup(group: GroupInput) {
  const id = group.id ?? group.groupId ?? ''
  const currency = group.baseCurrency?.currencyCode ?? group.currency ?? 'INR'
  const members = group.members ?? []
  const expenses = group.expenses

  return {
    id,
    name: group.name,
    description: group.description ?? null,
    image: group.image ?? null,
    currency,
    category: group.category ?? 'OTHER',
    status: group.finalizedAt ? 'FINALIZED' : 'ACTIVE',
    finalizedAt:
      group.finalizedAt instanceof Date
        ? group.finalizedAt.toISOString()
        : group.finalizedAt ?? null,
    finalizedById: group.finalizedById ?? null,
    memberCount: members.length || group._count?.members || 0,
    expenseCount: group._count?.expenses ?? expenses?.length ?? 0,
    revision: group.revision ?? null,
    readRevision: group.readRevision ?? group.revision ?? null,
    readOnly: group.readOnly ?? false,
    migration: group.migration ?? null,
    authority: group.authority ?? null,
    members: members.map(mobileMember),
    expenses: expenses ? expenses.map(mobileExpense) : undefined,
    createdAt:
      group.createdAt instanceof Date
        ? group.createdAt.toISOString()
        : group.createdAt ?? null,
    updatedAt:
      group.updatedAt instanceof Date
        ? group.updatedAt.toISOString()
        : group.updatedAt ?? null,
  }
}
