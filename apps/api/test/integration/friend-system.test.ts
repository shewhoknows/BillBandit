import assert from 'node:assert/strict'
import test from 'node:test'
import {
  claimFriendInvitation,
  createFriendInvitation,
  FRIEND_CLAIM_FAILURE_LIMIT,
  FRIEND_CLAIM_WINDOW_SECONDS,
  FriendServiceError,
  listAcceptedFriends,
  normalizedFriendPair,
  removeFriend,
} from '../../lib/friends'
import { executeMutation } from '../../lib/ledger/mutation'
import { loadAccountReadModel } from '../../lib/ledger/read-model/loader'
import {
  createGroupWithFriends,
  GroupCreationError,
  GroupCreationIdempotencyError,
} from '../../lib/mobile-group-creation'
import { createLedgerTestDatabase } from './ledger-harness'

let database: Awaited<ReturnType<typeof createLedgerTestDatabase>> | undefined

test.before(async () => {
  database = await createLedgerTestDatabase()
})

test.after(async () => database?.close())

test('friend invitations are reusable, bidirectional, normalized, and removable', async () => {
  assert.ok(database)
  const { db } = database
  const now = new Date('2026-08-12T00:00:00.000Z')
  const accounts = {
    alice: 'friends-alice',
    bob: 'friends-bob',
    carol: 'friends-carol',
    dave: 'friends-dave',
    erin: 'friends-erin',
  }

  await db.user.createMany({
    data: [
      {
        id: accounts.alice,
        username: 'friends_alice',
        name: 'Alice Account',
        preferredName: 'Alice',
        email: 'friends-alice@example.test',
        image: 'https://example.test/alice.png',
      },
      {
        id: accounts.bob,
        username: 'friends_bob',
        name: 'Bob Account',
        preferredName: 'Bob',
        email: 'friends-bob@example.test',
        image: 'https://example.test/bob.png',
      },
      {
        id: accounts.carol,
        username: 'friends_carol',
        name: 'Carol Account',
        preferredName: 'Carol',
        email: 'friends-carol@example.test',
      },
      {
        id: accounts.dave,
        username: 'friends_dave',
        name: 'Dave Account',
        email: 'friends-dave@example.test',
      },
      {
        id: accounts.erin,
        username: 'friends_erin',
        name: 'Erin Account',
        email: 'friends-erin@example.test',
      },
    ],
  })

  const invitation = await createFriendInvitation(accounts.alice, {
    db,
    now,
    expiresInSeconds: 60,
    codeGenerator: () => 'AL2CE',
  })
  assert.deepEqual(invitation, {
    code: 'AL2CE',
    createdAt: now,
    expiresAt: new Date('2026-08-12T00:01:00.000Z'),
    status: 'active',
  })

  const reusedInvitation = await createFriendInvitation(accounts.alice, {
    db,
    now: new Date('2026-08-12T00:00:30.000Z'),
    codeGenerator: () => 'NEW7X',
  })
  assert.equal(reusedInvitation.code, 'AL2CE')

  await assert.rejects(
    () => claimFriendInvitation(accounts.alice, 'AL2CE', { db, now }),
    (error: unknown) =>
      error instanceof FriendServiceError && error.code === 'friend_invitation_own_code'
  )

  const bobClaim = await claimFriendInvitation(accounts.bob, 'al-2ce', { db, now })
  assert.equal(bobClaim.created, true)
  assert.deepEqual(bobClaim.friend, {
    id: accounts.alice,
    username: 'friends_alice',
    name: 'Alice Account',
    preferredName: 'Alice',
    image: 'https://example.test/alice.png',
  })

  const replay = await claimFriendInvitation(accounts.bob, 'AL2CE', { db, now })
  assert.equal(replay.created, false)
  assert.equal(await db.friendClaimRateLimit.count({ where: { accountId: accounts.bob } }), 0)
  assert.equal(
    await db.friendship.count({
      where: normalizedFriendPair(accounts.alice, accounts.bob),
    }),
    1
  )

  await assert.rejects(
    () => claimFriendInvitation(accounts.carol, 'ZZZZZ', { db, now }),
    (error: unknown) =>
      error instanceof FriendServiceError && error.code === 'friend_invitation_not_found'
  )
  assert.equal(
    await db.friendClaimRateLimit
      .findUniqueOrThrow({ where: { accountId: accounts.carol } })
      .then((rateLimit) => rateLimit.failureCount),
    1
  )
  const carolClaim = await claimFriendInvitation(accounts.carol, 'AL2CE', { db, now })
  assert.equal(carolClaim.created, true)
  assert.equal(await db.friendClaimRateLimit.count({ where: { accountId: accounts.carol } }), 0)

  assert.deepEqual(
    await listAcceptedFriends(accounts.alice, db),
    [
      {
        id: accounts.bob,
        username: 'friends_bob',
        name: 'Bob Account',
        preferredName: 'Bob',
        image: 'https://example.test/bob.png',
      },
      {
        id: accounts.carol,
        username: 'friends_carol',
        name: 'Carol Account',
        preferredName: 'Carol',
        image: null,
      },
    ]
  )
  assert.deepEqual(await listAcceptedFriends(accounts.bob, db), [bobClaim.friend])

  const storedPair = await db.friendship.findUniqueOrThrow({
    where: { fromId_toId: normalizedFriendPair(accounts.alice, accounts.bob) },
  })
  assert.deepEqual(
    { fromId: storedPair.fromId, toId: storedPair.toId, status: storedPair.status },
    {
      fromId: normalizedFriendPair(accounts.alice, accounts.bob).fromId,
      toId: normalizedFriendPair(accounts.alice, accounts.bob).toId,
      status: 'ACCEPTED',
    }
  )

  const groupsBeforeRejectedCreate = await db.group.count()
  await assert.rejects(
    () =>
      createGroupWithFriends(
        {
          accountId: accounts.alice,
          actorName: 'Alice Account',
          name: 'Rejected group',
          currency: 'INR',
          category: 'OTHER',
          memberAccountIds: [accounts.dave],
        },
        db
      ),
    (error: unknown) =>
      error instanceof GroupCreationError &&
      error.invalidAccountIds.length === 1 &&
      error.invalidAccountIds[0] === accounts.dave
  )
  assert.equal(await db.group.count(), groupsBeforeRejectedCreate)

  const createdGroup = await createGroupWithFriends(
    {
      accountId: accounts.alice,
      actorName: 'Alice Account',
      name: 'Friends trip',
      currency: 'INR',
      category: 'TRIP',
      memberAccountIds: [accounts.bob, accounts.alice, accounts.bob],
      idempotencyKey: 'friends-trip-create-1',
    },
    db
  )
  assert.equal(createdGroup.replayed, false)
  const group = createdGroup.group
  assert.equal(group.members.length, 2)
  assert.deepEqual(
    group.members
      .map((member) => ({ userId: member.userId, role: member.role }))
      .sort((left, right) => left.userId.localeCompare(right.userId)),
    [
      { userId: accounts.alice, role: 'ADMIN' },
      { userId: accounts.bob, role: 'MEMBER' },
    ]
  )
  assert.equal(await db.groupParticipant.count({ where: { groupId: group.id } }), 2)

  const replayedGroup = await createGroupWithFriends(
    {
      accountId: accounts.alice,
      actorName: 'Alice Account',
      name: 'Friends trip',
      currency: 'INR',
      category: 'TRIP',
      memberAccountIds: [accounts.bob],
      idempotencyKey: 'friends-trip-create-1',
    },
    db
  )
  assert.equal(replayedGroup.replayed, true)
  assert.equal(replayedGroup.group.id, group.id)
  assert.equal(await db.group.count({ where: { name: 'Friends trip' } }), 1)

  await assert.rejects(
    () =>
      createGroupWithFriends(
        {
          accountId: accounts.alice,
          actorName: 'Alice Account',
          name: 'Different group request',
          currency: 'INR',
          category: 'TRIP',
          memberAccountIds: [accounts.bob],
          idempotencyKey: 'friends-trip-create-1',
        },
        db
      ),
    (error: unknown) =>
      error instanceof GroupCreationIdempotencyError &&
      error.code === 'idempotency_key_reused'
  )
  assert.equal(await db.group.count({ where: { name: 'Different group request' } }), 0)

  const expenseMutation = await executeMutation(
    {
      groupId: group.id,
      operationId: 'friends-trip-expense-1',
      expectedRevision: 0,
      accountId: accounts.alice,
      actorUserId: accounts.alice,
      kind: 'expense.create',
      payload: {
        expenseId: 'friends-trip-train-tickets',
        description: 'Train tickets',
        amount: { minorUnits: '2000', currencyCode: 'INR', currencyExponent: 2 },
        paidById: accounts.alice,
        splitType: 'EXACT',
        splits: [
          {
            userId: accounts.alice,
            amount: { minorUnits: '0', currencyCode: 'INR', currencyExponent: 2 },
          },
          {
            userId: accounts.bob,
            amount: { minorUnits: '2000', currencyCode: 'INR', currencyExponent: 2 },
          },
        ],
      },
    },
    { db }
  )
  assert.equal(expenseMutation.outcome, 'applied')

  const readOptions = { observedAt: '2026-08-12T00:00:00.000Z' }
  const [aliceRead, bobRead] = await Promise.all([
    loadAccountReadModel(accounts.alice, readOptions, db),
    loadAccountReadModel(accounts.bob, readOptions, db),
  ])
  assert.equal(aliceRead.groups.length, 1)
  assert.equal(bobRead.groups.length, 1)
  assert.equal(aliceRead.groups[0].model.groupId, group.id)
  assert.equal(bobRead.groups[0].model.groupId, group.id)
  assert.deepEqual(aliceRead.groups[0].model.expenses, bobRead.groups[0].model.expenses)
  assert.deepEqual(aliceRead.groups[0].model.expenses[0].amount, {
    minorUnits: '2000',
    currencyCode: 'INR',
    currencyExponent: 2,
  })
  assert.deepEqual(aliceRead.summary.balanceByCurrency, [
    { minorUnits: '2000', currencyCode: 'INR', currencyExponent: 2 },
  ])
  assert.deepEqual(bobRead.summary.balanceByCurrency, [
    { minorUnits: '-2000', currencyCode: 'INR', currencyExponent: 2 },
  ])

  assert.equal(await removeFriend(accounts.alice, accounts.bob, db), true)
  assert.deepEqual(
    (await listAcceptedFriends(accounts.alice, db)).map((friend) => friend.id),
    [accounts.carol]
  )
  assert.deepEqual(await listAcceptedFriends(accounts.bob, db), [])
  assert.equal(await removeFriend(accounts.bob, accounts.alice, db), true)
  assert.equal(await db.groupMember.count({ where: { groupId: group.id } }), 2)
  assert.equal(await db.groupParticipant.count({ where: { groupId: group.id } }), 2)
  assert.equal(await db.expense.count({ where: { id: expenseMutation.recordId } }), 1)
  assert.equal(await db.expenseSplit.count({ where: { expenseId: expenseMutation.recordId } }), 2)
  const [aliceAfterRemoval, bobAfterRemoval] = await Promise.all([
    loadAccountReadModel(accounts.alice, readOptions, db),
    loadAccountReadModel(accounts.bob, readOptions, db),
  ])
  assert.equal(aliceAfterRemoval.groups[0].model.groupId, group.id)
  assert.equal(bobAfterRemoval.groups[0].model.groupId, group.id)
  assert.deepEqual(
    aliceAfterRemoval.groups[0].model.expenses,
    aliceRead.groups[0].model.expenses
  )
  assert.deepEqual(
    bobAfterRemoval.groups[0].model.expenses,
    bobRead.groups[0].model.expenses
  )
  assert.deepEqual(aliceAfterRemoval.summary.balanceByCurrency, aliceRead.summary.balanceByCurrency)
  assert.deepEqual(bobAfterRemoval.summary.balanceByCurrency, bobRead.summary.balanceByCurrency)

  await createFriendInvitation(accounts.dave, {
    db,
    now,
    expiresInSeconds: 10,
    codeGenerator: () => 'DAVE7',
  })
  await assert.rejects(
    () =>
      claimFriendInvitation(accounts.erin, 'DAVE7', {
        db,
        now: new Date('2026-08-12T00:00:10.000Z'),
      }),
    (error: unknown) =>
      error instanceof FriendServiceError && error.code === 'friend_invitation_expired'
  )
})

test('invitation allocation retries collisions and concurrent expiry rotation has one winner', async () => {
  assert.ok(database)
  const { db } = database
  const firstNow = new Date('2026-08-12T01:00:00.000Z')
  const rotationNow = new Date('2026-08-12T01:00:11.000Z')
  const secondRotationNow = new Date('2026-08-12T01:00:22.000Z')
  const ownerA = 'invite-race-owner-a'
  const ownerB = 'invite-race-owner-b'

  await db.user.createMany({
    data: [
      { id: ownerA, email: 'invite-race-owner-a@example.test', name: 'Race A' },
      { id: ownerB, email: 'invite-race-owner-b@example.test', name: 'Race B' },
    ],
  })
  await createFriendInvitation(ownerA, {
    db,
    now: firstNow,
    expiresInSeconds: 10,
    codeGenerator: () => 'QAD7X',
  })
  await createFriendInvitation(ownerB, {
    db,
    now: firstNow,
    expiresInSeconds: 100,
    codeGenerator: () => 'SAME7',
  })

  const collisionCandidates = ['SAME7', 'NEW7X']
  const collisionRetry = await createFriendInvitation(ownerA, {
    db,
    now: rotationNow,
    expiresInSeconds: 10,
    codeGenerator: () => collisionCandidates.shift() ?? 'NEW7X',
  })
  assert.equal(collisionRetry.code, 'NEW7X')
  assert.deepEqual(collisionCandidates, [])

  const [leftRotation, rightRotation] = await Promise.all([
    createFriendInvitation(ownerA, {
      db,
      now: secondRotationNow,
      expiresInSeconds: 10,
      codeGenerator: () => 'RACE2',
    }),
    createFriendInvitation(ownerA, {
      db,
      now: secondRotationNow,
      expiresInSeconds: 10,
      codeGenerator: () => 'RACE3',
    }),
  ])
  assert.equal(leftRotation.code, rightRotation.code)
  assert.ok(leftRotation.code === 'RACE2' || leftRotation.code === 'RACE3')
  assert.equal(
    await db.friendInvitation
      .findUniqueOrThrow({ where: { inviterId: ownerA } })
      .then((invitation) => invitation.code),
    leftRotation.code
  )
})

test('failed friend claims use a durable account rate limit and valid claims reset it', async () => {
  assert.ok(database)
  const { db } = database
  const now = new Date('2026-08-12T02:00:00.000Z')
  const inviterId = 'rate-limit-inviter'
  const resetAccountId = 'rate-limit-reset-account'
  const blockedAccountId = 'rate-limit-blocked-account'

  await db.user.createMany({
    data: [
      { id: inviterId, email: 'rate-limit-inviter@example.test', name: 'Inviter' },
      { id: resetAccountId, email: 'rate-limit-reset@example.test', name: 'Reset Claimant' },
      { id: blockedAccountId, email: 'rate-limit-blocked@example.test', name: 'Blocked Claimant' },
    ],
  })
  await createFriendInvitation(inviterId, {
    db,
    now,
    expiresInSeconds: FRIEND_CLAIM_WINDOW_SECONDS * 2,
    codeGenerator: () => 'G3DD7',
  })

  for (let attempt = 0; attempt < 3; attempt += 1) {
    await assert.rejects(
      () => claimFriendInvitation(resetAccountId, 'ZZZZZ', { db, now }),
      (error: unknown) =>
        error instanceof FriendServiceError && error.code === 'friend_invitation_not_found'
    )
  }
  assert.equal(
    await db.friendClaimRateLimit
      .findUniqueOrThrow({ where: { accountId: resetAccountId } })
      .then((rateLimit) => rateLimit.failureCount),
    3
  )
  assert.equal(
    (await claimFriendInvitation(resetAccountId, 'G3DD7', { db, now })).created,
    true
  )
  assert.equal(await db.friendClaimRateLimit.count({ where: { accountId: resetAccountId } }), 0)
  assert.equal(
    (await claimFriendInvitation(resetAccountId, 'G3DD7', { db, now })).created,
    false
  )

  for (let attempt = 1; attempt < FRIEND_CLAIM_FAILURE_LIMIT; attempt += 1) {
    await assert.rejects(
      () => claimFriendInvitation(blockedAccountId, 'ZZZZZ', { db, now }),
      (error: unknown) =>
        error instanceof FriendServiceError && error.code === 'friend_invitation_not_found'
    )
  }
  await assert.rejects(
    () => claimFriendInvitation(blockedAccountId, 'ZZZZZ', { db, now }),
    (error: unknown) =>
      error instanceof FriendServiceError &&
      error.code === 'friend_claim_rate_limited' &&
      error.status === 429 &&
      error.retryAfterSeconds === FRIEND_CLAIM_WINDOW_SECONDS
  )
  const persistedLimit = await db.friendClaimRateLimit.findUniqueOrThrow({
    where: { accountId: blockedAccountId },
  })
  assert.equal(persistedLimit.failureCount, FRIEND_CLAIM_FAILURE_LIMIT)
  assert.equal(
    persistedLimit.blockedUntil?.toISOString(),
    new Date(now.getTime() + FRIEND_CLAIM_WINDOW_SECONDS * 1000).toISOString()
  )

  await assert.rejects(
    () => claimFriendInvitation(blockedAccountId, 'G3DD7', { db, now }),
    (error: unknown) =>
      error instanceof FriendServiceError && error.code === 'friend_claim_rate_limited'
  )
  const afterWindow = new Date(now.getTime() + FRIEND_CLAIM_WINDOW_SECONDS * 1000)
  assert.equal(
    (await claimFriendInvitation(blockedAccountId, 'G3DD7', { db, now: afterWindow })).created,
    true
  )
  assert.equal(await db.friendClaimRateLimit.count({ where: { accountId: blockedAccountId } }), 0)
})
