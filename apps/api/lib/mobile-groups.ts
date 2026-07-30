import { prisma } from '@/lib/prisma'
import { mobileGroup } from '@/lib/mobile-dto'

type ExpenseLike = {
  paidById: string
  splits: { userId: string; amount: number }[]
}

type TransactionLike = {
  senderId: string
  receiverId: string
  amount: number
}

type UserInfo = {
  id: string
  name: string | null
  image: string | null
}

export interface UserBalance {
  userId: string
  name: string | null
  image: string | null
  netAmount: number
}

export interface SimplifiedDebt {
  fromId: string
  toId: string
  amount: number
  fromName: string | null
  toName: string | null
}

function buildNetBalances(expenses: ExpenseLike[], transactions: TransactionLike[]) {
  const net = new Map<string, number>()
  const add = (id: string, delta: number) => net.set(id, (net.get(id) ?? 0) + delta)

  for (const expense of expenses) {
    for (const split of expense.splits) {
      if (split.userId !== expense.paidById) {
        add(expense.paidById, split.amount)
        add(split.userId, -split.amount)
      }
    }
  }

  for (const txn of transactions) {
    add(txn.receiverId, -txn.amount)
    add(txn.senderId, txn.amount)
  }

  return net
}

function simplifyDebts(netBalances: Map<string, number>) {
  const EPS = 0.005
  const balances = new Map<string, number>()
  for (const [id, bal] of netBalances.entries()) {
    const rounded = Math.round(bal * 100) / 100
    if (Math.abs(rounded) > EPS) balances.set(id, rounded)
  }

  const creditors: { id: string; amount: number }[] = []
  const debtors: { id: string; amount: number }[] = []

  for (const [id, bal] of balances.entries()) {
    if (bal > EPS) creditors.push({ id, amount: bal })
    else if (bal < -EPS) debtors.push({ id, amount: -bal })
  }

  creditors.sort((a, b) => b.amount - a.amount)
  debtors.sort((a, b) => b.amount - a.amount)

  const transactions: { fromId: string; toId: string; amount: number }[] = []
  let ci = 0
  let di = 0

  while (ci < creditors.length && di < debtors.length) {
    const creditor = creditors[ci]
    const debtor = debtors[di]
    const transfer = Math.min(creditor.amount, debtor.amount)
    const rounded = Math.round(transfer * 100) / 100

    if (rounded > EPS) {
      transactions.push({ fromId: debtor.id, toId: creditor.id, amount: rounded })
    }

    creditor.amount -= transfer
    debtor.amount -= transfer
    if (creditor.amount < EPS) ci++
    if (debtor.amount < EPS) di++
  }

  return transactions
}

export function getGroupNetBalances(
  expenses: ExpenseLike[],
  transactions: TransactionLike[],
  members: UserInfo[]
): UserBalance[] {
  const net = buildNetBalances(expenses, transactions)
  return members.map((member) => ({
    userId: member.id,
    name: member.name,
    image: member.image,
    netAmount: Math.round((net.get(member.id) ?? 0) * 100) / 100,
  }))
}

export function getSimplifiedDebts(
  expenses: ExpenseLike[],
  transactions: TransactionLike[],
  members: UserInfo[]
): SimplifiedDebt[] {
  const net = buildNetBalances(expenses, transactions)
  const simplified = simplifyDebts(net)
  const userMap = new Map(members.map((member) => [member.id, member]))

  return simplified.map((txn) => ({
    ...txn,
    fromName: userMap.get(txn.fromId)?.name ?? null,
    toName: userMap.get(txn.toId)?.name ?? null,
  }))
}

const userSelect = { id: true, name: true, image: true, email: true } as const

export async function getGroupWithLedger(groupId: string) {
  return prisma.group.findUnique({
    where: { id: groupId },
    include: {
      members: {
        include: { user: { select: userSelect } },
        orderBy: { joinedAt: 'asc' },
      },
      expenses: {
        where: { isDeleted: false },
        include: {
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
        },
        orderBy: { date: 'desc' },
      },
      transactions: {
        include: {
          sender: { select: { id: true, name: true, image: true } },
          receiver: { select: { id: true, name: true, image: true } },
        },
        orderBy: { createdAt: 'desc' },
      },
    },
  })
}

export function buildGroupDetailResponse(
  group: NonNullable<Awaited<ReturnType<typeof getGroupWithLedger>>>
) {
  const members = group.members.map((member) => member.user)
  const netBalances = getGroupNetBalances(group.expenses, group.transactions, members)
  const simplifiedDebts = getSimplifiedDebts(group.expenses, group.transactions, members)

  return {
    group: mobileGroup(group),
    balances: { netBalances, simplifiedDebts },
  }
}
