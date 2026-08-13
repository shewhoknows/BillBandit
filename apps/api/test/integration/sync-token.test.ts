import assert from 'node:assert/strict'
import test from 'node:test'
import type { PrismaClient } from '@prisma/client'
import { NextRequest } from 'next/server'
import { createLedgerTestDatabase } from './ledger-harness'

let database: Awaited<ReturnType<typeof createLedgerTestDatabase>> | undefined
let db!: PrismaClient
let globalPrisma!: PrismaClient
let buildMobileSyncToken!: (typeof import('../../lib/mobile-sync-token'))['buildMobileSyncToken']
let createFriendInvitation!: (typeof import('../../lib/friends'))['createFriendInvitation']
let claimFriendInvitation!: (typeof import('../../lib/friends'))['claimFriendInvitation']
let removeFriend!: (typeof import('../../lib/friends'))['removeFriend']
let createGroupWithFriends!: (typeof import('../../lib/mobile-group-creation'))['createGroupWithFriends']
let executeMutation!: (typeof import('../../lib/ledger/mutation'))['executeMutation']
let createMobileToken!: (typeof import('../../lib/mobile-auth'))['createMobileToken']
let getSyncToken!: (typeof import('../../app/api/mobile/sync-token/route'))['GET']

test.before(async () => {
  database = await createLedgerTestDatabase()
  db = database.db
  process.env.MOBILE_JWT_SECRET = 'sync-token-integration-secret'

  const sync = await import('../../lib/mobile-sync-token')
  const friends = await import('../../lib/friends')
  const groups = await import('../../lib/mobile-group-creation')
  const mutations = await import('../../lib/ledger/mutation')
  const auth = await import('../../lib/mobile-auth')
  const route = await import('../../app/api/mobile/sync-token/route')
  const databaseModule = await import('../../lib/prisma')

  buildMobileSyncToken = sync.buildMobileSyncToken
  createFriendInvitation = friends.createFriendInvitation
  claimFriendInvitation = friends.claimFriendInvitation
  removeFriend = friends.removeFriend
  createGroupWithFriends = groups.createGroupWithFriends
  executeMutation = mutations.executeMutation
  createMobileToken = auth.createMobileToken
  getSyncToken = route.GET
  globalPrisma = databaseModule.prisma
})

test.after(async () => {
  await globalPrisma?.$disconnect()
  await database?.close()
})

test('sync token tracks friend discovery, shared ledger changes, and group discovery', async () => {
  assert.ok(database)
  const accountIds = {
    alice: 'sync-token-alice',
    bob: 'sync-token-bob',
  }
  await db.user.createMany({
    data: [
      {
        id: accountIds.alice,
        username: 'sync_alice',
        name: 'Sync Alice',
        email: 'sync-token-alice@example.test',
      },
      {
        id: accountIds.bob,
        username: 'sync_bob',
        name: 'Sync Bob',
        email: 'sync-token-bob@example.test',
      },
    ],
  })

  const initialAlice = await buildMobileSyncToken(accountIds.alice, db)
  const initialBob = await buildMobileSyncToken(accountIds.bob, db)
  assert.match(initialAlice, /^[a-f0-9]{64}$/)
  assert.match(initialBob, /^[a-f0-9]{64}$/)
  assert.equal(await buildMobileSyncToken(accountIds.alice, db), initialAlice)
  assert.equal(await buildMobileSyncToken(accountIds.bob, db), initialBob)

  const invitation = await createFriendInvitation(accountIds.alice, {
    db,
    now: new Date('2026-08-12T00:00:00.000Z'),
    codeGenerator: () => 'SYNC7',
  })
  assert.equal(await buildMobileSyncToken(accountIds.alice, db), initialAlice)
  assert.equal(await buildMobileSyncToken(accountIds.bob, db), initialBob)

  await claimFriendInvitation(accountIds.bob, invitation.code, {
    db,
    now: new Date('2026-08-12T00:00:01.000Z'),
  })
  const afterClaimAlice = await buildMobileSyncToken(accountIds.alice, db)
  const afterClaimBob = await buildMobileSyncToken(accountIds.bob, db)
  assert.notEqual(afterClaimAlice, initialAlice)
  assert.notEqual(afterClaimBob, initialBob)
  assert.equal(await buildMobileSyncToken(accountIds.alice, db), afterClaimAlice)

  await db.user.update({
    where: { id: accountIds.bob },
    data: { name: 'Renamed Sync Bob', preferredName: 'Bobby' },
  })
  const afterProfileRenameAlice = await buildMobileSyncToken(accountIds.alice, db)
  assert.notEqual(afterProfileRenameAlice, afterClaimAlice)
  assert.equal(await buildMobileSyncToken(accountIds.alice, db), afterProfileRenameAlice)

  const created = await createGroupWithFriends(
    {
      accountId: accountIds.alice,
      actorName: 'Sync Alice',
      name: 'Sync group',
      currency: 'INR',
      category: 'TRIP',
      memberAccountIds: [accountIds.bob],
      idempotencyKey: 'sync-token-group-create',
    },
    db
  )
  const groupId = created.group.id
  const afterGroupAlice = await buildMobileSyncToken(accountIds.alice, db)
  const afterGroupBob = await buildMobileSyncToken(accountIds.bob, db)
  assert.notEqual(afterGroupAlice, afterProfileRenameAlice)
  assert.notEqual(afterGroupBob, afterClaimBob)

  await db.group.update({ where: { id: groupId }, data: { name: 'Renamed sync group' } })
  const afterGroupRenameAlice = await buildMobileSyncToken(accountIds.alice, db)
  const afterGroupRenameBob = await buildMobileSyncToken(accountIds.bob, db)
  assert.notEqual(afterGroupRenameAlice, afterGroupAlice)
  assert.notEqual(afterGroupRenameBob, afterGroupBob)

  await db.groupMember.update({
    where: { groupId_userId: { groupId, userId: accountIds.bob } },
    data: { role: 'ADMIN' },
  })
  const afterMemberChangeAlice = await buildMobileSyncToken(accountIds.alice, db)
  const afterMemberChangeBob = await buildMobileSyncToken(accountIds.bob, db)
  assert.notEqual(afterMemberChangeAlice, afterGroupRenameAlice)
  assert.notEqual(afterMemberChangeBob, afterGroupRenameBob)

  await executeMutation(
    {
      groupId,
      operationId: 'sync-token-expense-create',
      expectedRevision: 0,
      accountId: accountIds.alice,
      actorUserId: accountIds.alice,
      kind: 'expense.create',
      payload: {
        expenseId: 'sync-token-expense',
        description: 'Sync dinner',
        amount: { minorUnits: '1800', currencyCode: 'INR', currencyExponent: 2 },
        paidById: accountIds.alice,
        splitType: 'EXACT',
        splits: [
          {
            userId: accountIds.alice,
            amount: { minorUnits: '0', currencyCode: 'INR', currencyExponent: 2 },
          },
          {
            userId: accountIds.bob,
            amount: { minorUnits: '1800', currencyCode: 'INR', currencyExponent: 2 },
          },
        ],
      },
    },
    { db }
  )
  const afterExpenseAlice = await buildMobileSyncToken(accountIds.alice, db)
  const afterExpenseBob = await buildMobileSyncToken(accountIds.bob, db)
  assert.notEqual(afterExpenseAlice, afterMemberChangeAlice)
  assert.notEqual(afterExpenseBob, afterMemberChangeBob)

  await removeFriend(accountIds.alice, accountIds.bob, db)
  const afterRemovalAlice = await buildMobileSyncToken(accountIds.alice, db)
  const afterRemovalBob = await buildMobileSyncToken(accountIds.bob, db)
  assert.notEqual(afterRemovalAlice, afterExpenseAlice)
  assert.notEqual(afterRemovalBob, afterExpenseBob)
  assert.equal(await buildMobileSyncToken(accountIds.alice, db), afterRemovalAlice)
  assert.equal(await buildMobileSyncToken(accountIds.bob, db), afterRemovalBob)

  const scratch = await createGroupWithFriends(
    {
      accountId: accountIds.alice,
      actorName: 'Sync Alice',
      name: 'Scratch discovery group',
      currency: 'INR',
      category: 'OTHER',
      memberAccountIds: [],
    },
    db
  )
  const afterDiscovery = await buildMobileSyncToken(accountIds.alice, db)
  assert.notEqual(afterDiscovery, afterRemovalAlice)
  await db.groupMember.delete({
    where: {
      groupId_userId: {
        groupId: scratch.group.id,
        userId: accountIds.alice,
      },
    },
  })
  const afterGroupRemoval = await buildMobileSyncToken(accountIds.alice, db)
  assert.notEqual(afterGroupRemoval, afterDiscovery)
  assert.equal(await buildMobileSyncToken(accountIds.alice, db), afterGroupRemoval)

  const bearer = createMobileToken({
    id: accountIds.alice,
    email: 'sync-token-alice@example.test',
    name: 'Sync Alice',
  })
  const response = await getSyncToken(
    new NextRequest('http://localhost/api/mobile/sync-token', {
      headers: { Authorization: `Bearer ${bearer}` },
    })
  )
  assert.equal(response.status, 200)
  assert.equal(response.headers.get('cache-control'), 'no-store')
  assert.deepEqual(await response.json(), { token: afterGroupRemoval })
})
