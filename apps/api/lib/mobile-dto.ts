export function mobileUser(user: {
  id: string
  username?: string | null
  name?: string | null
  email?: string | null
  image?: string | null
  phone?: string | null
  preferredName?: string | null
  upiID?: string | null
}) {
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

export function mobileMember(member: {
  userId: string
  role: string
  joinedAt?: Date
  user: {
    id: string
    name?: string | null
    email?: string | null
    image?: string | null
  }
}) {
  return {
    userId: member.userId,
    role: member.role,
    joinedAt: member.joinedAt?.toISOString() ?? null,
    user: mobileUser(member.user),
  }
}

export function mobileExpense(expense: {
  id: string
  description: string
  amount: number
  currency: string
  date: Date | string
  category: string
  groupId?: string | null
  group?: { id: string; name: string } | null
  paidById: string
  paidBy?: Parameters<typeof mobileUser>[0] | null
  splitType: string
  notes?: string | null
  splits?: Array<{
    userId: string
    amount: number
    percentage?: number | null
    shares?: number | null
    user?: Parameters<typeof mobileUser>[0] | null
  }>
  createdAt?: Date | string | null
  updatedAt?: Date | string | null
}) {
  return {
    id: expense.id,
    description: expense.description,
    amount: expense.amount,
    currency: expense.currency,
    date: expense.date instanceof Date ? expense.date.toISOString() : expense.date,
    category: expense.category,
    groupId: expense.groupId ?? null,
    group: expense.group ? { id: expense.group.id, name: expense.group.name } : null,
    paidById: expense.paidById,
    paidBy: expense.paidBy ? mobileUser(expense.paidBy) : null,
    splitType: expense.splitType,
    notes: expense.notes ?? null,
    splits: (expense.splits ?? []).map((split) => ({
      userId: split.userId,
      amount: split.amount,
      percentage: split.percentage ?? null,
      shares: split.shares ?? null,
      user: split.user ? mobileUser(split.user) : null,
    })),
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

export function mobileGroup(group: {
  id: string
  name: string
  description?: string | null
  image?: string | null
  currency: string
  category: string
  finalizedAt?: Date | string | null
  finalizedById?: string | null
  members?: Array<Parameters<typeof mobileMember>[0]>
  expenses?: Array<Parameters<typeof mobileExpense>[0]>
  _count?: { expenses?: number; members?: number }
  createdAt?: Date | string | null
  updatedAt?: Date | string | null
}) {
  return {
    id: group.id,
    name: group.name,
    description: group.description ?? null,
    image: group.image ?? null,
    currency: group.currency,
    category: group.category,
    status: group.finalizedAt ? 'FINALIZED' : 'ACTIVE',
    finalizedAt:
      group.finalizedAt instanceof Date
        ? group.finalizedAt.toISOString()
        : group.finalizedAt ?? null,
    finalizedById: group.finalizedById ?? null,
    memberCount: group.members?.length ?? group._count?.members ?? 0,
    expenseCount: group._count?.expenses ?? group.expenses?.length ?? 0,
    members: (group.members ?? []).map(mobileMember),
    expenses: group.expenses ? group.expenses.map(mobileExpense) : undefined,
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
