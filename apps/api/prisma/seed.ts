import { PrismaClient, FriendshipStatus, GroupCategory, GroupRole, SplitType } from '@prisma/client'
import bcrypt from 'bcryptjs'
import fixtures from '../../../packages/contracts/fixtures/parity-fixtures.json'

const prisma = new PrismaClient()

type FixtureUser = (typeof fixtures.users)[number]
type FixtureGroup = (typeof fixtures.groups)[number]
type FixtureExpense = (typeof fixtures.expenses)[number]

async function clearDatabase() {
  await prisma.activityLog.deleteMany()
  await prisma.comment.deleteMany()
  await prisma.transaction.deleteMany()
  await prisma.expenseSplit.deleteMany()
  await prisma.expense.deleteMany()
  await prisma.groupMember.deleteMany()
  await prisma.group.deleteMany()
  await prisma.friendship.deleteMany()
  await prisma.session.deleteMany()
  await prisma.account.deleteMany()
  await prisma.user.deleteMany()
}

async function createUsers(users: FixtureUser[]) {
  for (const user of users) {
    await prisma.user.create({
      data: {
        id: user.id,
        name: user.name,
        email: user.email,
        password: bcrypt.hashSync(user.password, 10),
        image: user.image,
      },
    })
  }
}

async function createFriendships() {
  await prisma.friendship.createMany({
    data: [
      { fromId: 'user-alice', toId: 'user-bob', status: FriendshipStatus.ACCEPTED },
      { fromId: 'user-alice', toId: 'user-carol', status: FriendshipStatus.ACCEPTED },
      { fromId: 'user-alice', toId: 'user-dave', status: FriendshipStatus.ACCEPTED },
      { fromId: 'user-bob', toId: 'user-carol', status: FriendshipStatus.ACCEPTED },
    ],
  })
}

async function createGroups(groups: FixtureGroup[]) {
  for (const group of groups) {
    await prisma.group.create({
      data: {
        id: group.id,
        name: group.name,
        description: group.description,
        currency: group.currency,
        category: group.category as GroupCategory,
        members: {
          create: group.members.map((member) => ({
            userId: member.userId,
            role: member.role as GroupRole,
            joinedAt: new Date(member.joinedAt),
          })),
        },
      },
    })
  }
}

async function createExpenses(expenses: FixtureExpense[]) {
  for (const expense of expenses) {
    await prisma.expense.create({
      data: {
        id: expense.id,
        description: expense.description,
        amount: expense.amount,
        currency: expense.currency,
        date: new Date(expense.date),
        category: expense.category,
        groupId: expense.groupId,
        paidById: expense.paidById,
        splitType: expense.splitType as SplitType,
        notes: expense.notes,
        splits: {
          create: expense.splits.map((split) => ({
            userId: split.userId,
            amount: split.amount,
            percentage: split.percentage,
            shares: split.shares,
          })),
        },
      },
    })
  }
}

async function createNarrativeData() {
  await prisma.comment.create({
    data: {
      content: 'Great deal on the hotel.',
      expenseId: 'expense-hotel',
      userId: 'user-bob',
    },
  })

  await prisma.activityLog.createMany({
    data: [
      {
        userId: 'user-alice',
        type: 'GROUP_CREATED',
        description: 'Alice created the group NYC Trip',
        metadata: { groupId: 'group-nyc' },
      },
      {
        userId: 'user-alice',
        type: 'EXPENSE_CREATED',
        description: 'Alice added "Hotel - 3 nights" ($450.00)',
        metadata: { expenseId: 'expense-hotel' },
      },
      {
        userId: 'user-bob',
        type: 'EXPENSE_CREATED',
        description: 'Bob added "Dinner at Carbone" ($180.00)',
        metadata: { expenseId: 'expense-dinner' },
      },
    ],
  })
}

async function main() {
  console.log('Seeding database from shared parity fixtures...')
  await clearDatabase()
  await createUsers(fixtures.users)
  await createFriendships()
  await createGroups(fixtures.groups)
  await createExpenses(fixtures.expenses)
  await createNarrativeData()

  console.log('Seed complete. Login with:')
  for (const user of fixtures.users) {
    console.log(`  ${user.email} / ${user.password}`)
  }
}

main()
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
  .finally(async () => {
    await prisma.$disconnect()
  })
