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

  // A peer avatar must invalidate the viewer's group catalog. The catalog
  // must carry the persisted marker for an authenticated group member.
  await db.user.update({
    where: { id: accountIds.bob },
    data: { image: 'billbandit-avatar:bandana' },
  })
  const afterPeerAvatarAlice = await buildMobileSyncToken(accountIds.alice, db)
  const afterPeerAvatarBob = await buildMobileSyncToken(accountIds.bob, db)
  assert.notEqual(afterPeerAvatarAlice, afterGroupRenameAlice)
  assert.notEqual(afterPeerAvatarBob, afterGroupRenameBob)
  const { GET: getMobileGroups } = await import('../../app/api/mobile/groups/route')
  const peerCatalog = await getMobileGroups(new NextRequest('http://localhost/api/mobile/groups', {
    headers: { Authorization: 'Bearer ' + createMobileToken({
      id: accountIds.alice, email: 'sync-token-alice@example.test', name: 'Sync Alice',
    }) },
  }))
  assert.equal(peerCatalog.status, 200)
  const peerBody = await peerCatalog.json()
  const sharedGroup = peerBody.groups.find((entry: { id: string }) => entry.id === groupId)
  assert.ok(sharedGroup)
  assert.equal(sharedGroup.members.find((member: { userId: string }) => member.userId === accountIds.bob)?.user.image,
    'billbandit-avatar:bandana')
  const { GET: getGroupDetail } = await import('../../app/api/mobile/groups/[id]/route')
  const detail = await getGroupDetail(new NextRequest(`http://localhost/api/mobile/groups/${groupId}`, {
    headers: { Authorization: 'Bearer ' + createMobileToken({
      id: accountIds.alice, email: 'sync-token-alice@example.test', name: 'Sync Alice',
    }) },
  }), { params: { id: groupId } })
  assert.equal(detail.status, 200)
  const detailBody = await detail.json()
  assert.equal(detailBody.group.members.find((member: { userId: string }) =>
    member.userId === accountIds.bob)?.user.image, 'billbandit-avatar:bandana')

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

  const { DELETE: removeSharedGroup } = await import('../../app/api/mobile/groups/[id]/route')
  await db.groupMember.update({
    where: { groupId_userId: { groupId, userId: accountIds.bob } },
    data: { role: 'MEMBER' },
  })
  const ownerAuthorization = { Authorization: 'Bearer ' + createMobileToken({
    id: accountIds.alice, email: 'sync-token-alice@example.test', name: 'Sync Alice',
  }) }
  const memberAuthorization = { Authorization: 'Bearer ' + createMobileToken({
    id: accountIds.bob, email: 'sync-token-bob@example.test', name: 'Renamed Sync Bob',
  }) }
  const groupRequest = (headers: { Authorization: string }, id: string) =>
    new NextRequest(`http://localhost/api/mobile/groups/${id}`, { method: 'DELETE', headers })
  const deniedMember = await removeSharedGroup(groupRequest(memberAuthorization, groupId), { params: { id: groupId } })
  const deniedMemberBody = await deniedMember.json()
  assert.equal(deniedMember.status, 403, JSON.stringify(deniedMemberBody))
  assert.equal(deniedMemberBody.code, 'NOT_GROUP_OWNER')
  const deniedDebt = await removeSharedGroup(groupRequest(ownerAuthorization, groupId), { params: { id: groupId } })
  assert.equal(deniedDebt.status, 409)
  assert.equal((await deniedDebt.json()).code, 'GROUP_UNSETTLED')
  assert.equal((await db.group.findUniqueOrThrow({ where: { id: groupId } })).isArchived, false)

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
  // Bob's pending write must block Alice's archive even though Alice's read
  // model only contains Alice's operations. A failed retry is not pending.
  await db.ledgerOperation.create({ data: {
    id: 'sync-bob-pending', accountId: accountIds.bob, groupId: scratch.group.id,
    operationKey: 'sync-bob-pending', requestHash: 'pending', state: 'PENDING',
  } })
  const blockedPending = await removeSharedGroup(groupRequest(ownerAuthorization, scratch.group.id), {
    params: { id: scratch.group.id },
  })
  assert.equal(blockedPending.status, 409)
  assert.equal((await blockedPending.json()).code, 'GROUP_STATE_STALE')
  assert.equal((await db.group.findUniqueOrThrow({ where: { id: scratch.group.id } })).isArchived, false)
  await db.ledgerOperation.update({ where: { id: 'sync-bob-pending' }, data: { state: 'FAILED' } })

  process.env.MOBILE_INVITATION_SECRET = 'sync-token-integration-invite-secret'
  await db.externalIdentity.create({ data: {
    accountId: accountIds.bob, provider: 'cloudkit', subject: 'sync-bob-cloudkit',
  } })
  const { createGroupInvitation, claimGroupInvitation, InvitationFlowError } =
    await import('../../lib/identity/invitations')
  const inviteInput = {
    groupId: scratch.group.id, issuerAccountId: accountIds.alice,
    identity: { provider: 'cloudkit' as const, subject: 'sync-bob-cloudkit' }, db,
  }
  const groupInvitation = await createGroupInvitation(inviteInput)
  const archived = await removeSharedGroup(groupRequest(ownerAuthorization, scratch.group.id), {
    params: { id: scratch.group.id },
  })
  assert.equal(archived.status, 200)
  assert.deepEqual(await archived.json(), { code: 'GROUP_ARCHIVED', archived: true })
  assert.equal((await db.group.findUniqueOrThrow({ where: { id: scratch.group.id } })).isArchived, true)
  assert.equal((await db.ledgerOperation.findUniqueOrThrow({ where: { id: groupInvitation.invitation.id } })).state, 'FAILED')
  await assert.rejects(
    () => claimGroupInvitation({ token: groupInvitation.token, acceptingAccountId: accountIds.bob, db }),
    (error: unknown) => error instanceof InvitationFlowError && error.code === 'group_finalized'
  )
  await assert.rejects(
    () => createGroupInvitation(inviteInput),
    (error: unknown) => error instanceof InvitationFlowError && error.code === 'group_finalized'
  )
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

  const restoredFriendInvite = await createFriendInvitation(accountIds.alice, { db })
  await claimFriendInvitation(accountIds.bob, restoredFriendInvite.code, { db })
  const otherAdminGroup = await createGroupWithFriends({
    accountId: accountIds.alice, actorName: 'Sync Alice', name: 'Other admin archive',
    currency: 'INR', category: 'OTHER', memberAccountIds: [accountIds.bob],
  }, db)
  const escalation = {
    groupId: otherAdminGroup.group.id, operationId: 'sync-escalation', expectedRevision: 0,
    accountId: accountIds.bob, actorUserId: accountIds.bob,
    kind: 'membership.update' as const,
    payload: { userId: accountIds.bob, role: 'ADMIN' as const },
  }
  await assert.rejects(
    () => executeMutation(escalation, { db }),
    (error: unknown) => error instanceof Error && 'code' in error && error.code === 'FORBIDDEN'
  )
  assert.equal((await db.groupMember.findUniqueOrThrow({ where: {
    groupId_userId: { groupId: otherAdminGroup.group.id, userId: accountIds.bob },
  } })).role, 'MEMBER')
  await executeMutation({ ...escalation, accountId: accountIds.alice,
    actorUserId: accountIds.alice, operationId: 'sync-admin-authorized' }, { db })
  const otherAdminArchive = await removeSharedGroup(
    groupRequest(memberAuthorization, otherAdminGroup.group.id),
    { params: { id: otherAdminGroup.group.id } }
  )
  assert.equal(otherAdminArchive.status, 200)
  assert.equal((await db.group.findUniqueOrThrow({ where: { id: otherAdminGroup.group.id } })).isArchived, true)
})


test('claim commit then archive then post-claim hook cannot change archived ledger', async () => {
  assert.ok(database)
  process.env.MOBILE_INVITATION_SECRET = 'claim-archive-race-disposable-secret'
  const ownerId = 'race-owner'
  const inviteeId = 'race-invitee'
  await db.user.createMany({ data: [
    { id: ownerId, username: 'race_owner', name: 'Race Owner', email: 'race-owner@example.test' },
    { id: inviteeId, username: 'race_invitee', name: 'Race Invitee', email: 'race-invitee@example.test' },
  ] })
  await db.externalIdentity.create({ data: {
    accountId: inviteeId, provider: 'cloudkit', subject: 'race-invitee-cloudkit',
  } })
  const { createGroupInvitation, claimGroupInvitation, InvitationFlowError } =
    await import('../../lib/identity/invitations')
  const { afterMembershipClaim, identityErrorResponse } =
    await import('../../lib/identity/mobile-routes')
  const { DELETE: archiveGroup } = await import('../../app/api/mobile/groups/[id]/route')
  const ownerAuth = { Authorization: 'Bearer ' + createMobileToken({
    id: ownerId, email: 'race-owner@example.test', name: 'Race Owner',
  }) }
  const newGroup = (name: string) => createGroupWithFriends({
    accountId: ownerId, actorName: 'Race Owner', name, currency: 'USD',
    category: 'OTHER', memberAccountIds: [],
  }, db)
  const invite = (groupId: string) => createGroupInvitation({
    groupId, issuerAccountId: ownerId,
    identity: { provider: 'cloudkit', subject: 'race-invitee-cloudkit' }, db,
  })
  const archivedGroup = (await newGroup('Archive wins after claim commit')).group
  const invitation = await invite(archivedGroup.id)
  const claim = await claimGroupInvitation({
    token: invitation.token, acceptingAccountId: inviteeId, db,
  })
  assert.equal(claim.created, true)
  assert.equal((await db.ledgerOperation.findUniqueOrThrow({
    where: { id: invitation.invitation.id },
  })).state, 'COMMITTED')
  assert.ok(await db.groupMember.findUnique({
    where: { groupId_userId: { groupId: archivedGroup.id, userId: inviteeId } },
  }))
  assert.equal(await db.groupParticipant.count({
    where: { groupId: archivedGroup.id, userId: inviteeId },
  }), 0)
  const archived = await archiveGroup(new NextRequest(
    `http://localhost/api/mobile/groups/${archivedGroup.id}`,
    { method: 'DELETE', headers: ownerAuth },
  ), { params: { id: archivedGroup.id } })
  assert.equal(archived.status, 200, JSON.stringify(await archived.json()))
  const before = {
    group: await db.group.findUniqueOrThrow({ where: { id: archivedGroup.id } }),
    participants: await db.groupParticipant.count({ where: { groupId: archivedGroup.id } }),
    journals: await db.settlementVersionJournal.count({ where: { groupId: archivedGroup.id } }),
    outbox: await db.settlementOutbox.count({ where: { groupId: archivedGroup.id } }),
    activity: await db.activityLog.count({
      where: { userId: inviteeId, type: 'GROUP_JOINED' },
    }),
  }
  assert.equal(before.group.isArchived, true)
  const failure = await afterMembershipClaim(claim, inviteeId, db).then(
    () => null, (error: unknown) => error
  )
  assert.ok(failure instanceof InvitationFlowError)
  assert.equal(failure.code, 'group_finalized')
  const response = identityErrorResponse(failure)
  assert.equal(response.status, 409)
  assert.deepEqual(await response.json(), {
    code: 'group_finalized', error: 'Group closed after the invitation was claimed.',
    membershipCommitted: true,
  })
  const after = await db.group.findUniqueOrThrow({ where: { id: archivedGroup.id } })
  assert.equal(after.settlementVersion, before.group.settlementVersion)
  assert.equal(await db.groupParticipant.count({ where: { groupId: archivedGroup.id } }), before.participants)
  assert.equal(await db.groupParticipant.count({ where: { groupId: archivedGroup.id, userId: inviteeId } }), 0)
  assert.equal(await db.settlementVersionJournal.count({ where: { groupId: archivedGroup.id } }), before.journals)
  assert.equal(await db.settlementOutbox.count({ where: { groupId: archivedGroup.id } }), before.outbox)
  assert.equal(await db.activityLog.count({ where: { userId: inviteeId, type: 'GROUP_JOINED' } }), before.activity)
  assert.equal((await db.ledgerOperation.findUniqueOrThrow({
    where: { id: invitation.invitation.id },
  })).state, 'COMMITTED')

  // A still-open group follows the same hook and gets exactly one participant,
  // one membership version, and one activity record. A no-op replay does not write.
  const openGroup = (await newGroup('Claim hook wins')).group
  const openInvite = await invite(openGroup.id)
  const openClaim = await claimGroupInvitation({
    token: openInvite.token, acceptingAccountId: inviteeId, db,
  })
  const priorVersion = (await db.group.findUniqueOrThrow({ where: { id: openGroup.id } })).settlementVersion
  await afterMembershipClaim(openClaim, inviteeId, db)
  assert.equal((await db.group.findUniqueOrThrow({ where: { id: openGroup.id } })).settlementVersion, priorVersion + 1)
  assert.equal(await db.groupParticipant.count({ where: { groupId: openGroup.id, userId: inviteeId } }), 1)
  assert.equal(await db.settlementVersionJournal.count({ where: { groupId: openGroup.id } }), 1)
  const openActivity = await db.activityLog.count({ where: { userId: inviteeId, type: 'GROUP_JOINED' } })
  assert.equal(openActivity, before.activity + 1)
  await afterMembershipClaim({ ...openClaim, created: false }, inviteeId, db)
  assert.equal((await db.group.findUniqueOrThrow({ where: { id: openGroup.id } })).settlementVersion, priorVersion + 1)
  assert.equal(await db.activityLog.count({ where: { userId: inviteeId, type: 'GROUP_JOINED' } }), openActivity)
})
