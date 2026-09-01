import assert from 'node:assert/strict'
import test from 'node:test'
import {
  appleIdentity,
  cloudKitIdentity,
  externalIdentityFromInput,
  IdentityInputError,
} from '../../lib/identity/types'
import {
  createInvitationToken,
  invitationBelongsToAccount,
  invitationIdentity,
  invitationTokenHash,
  verifyInvitationToken,
} from '../../lib/identity/invitation-token'
import {
  claimGroupInvitation,
  createGroupInvitation,
  InvitationFlowError,
} from '../../lib/identity/invitations'
import { linkExternalIdentity } from '../../lib/identity/external-identities'

process.env.MOBILE_INVITATION_SECRET = 'identity-test-secret'

test('provider subjects and CloudKit record names are explicit identity keys', () => {
  assert.deepEqual(appleIdentity(' apple-subject '), {
    provider: 'apple',
    subject: 'apple-subject',
  })
  assert.deepEqual(cloudKitIdentity('cloud-record-name'), {
    provider: 'cloudkit',
    subject: 'cloud-record-name',
  })
  assert.throws(
    () => externalIdentityFromInput({ name: 'Maya', provider: 'apple', subject: 'apple-1' }),
    (error: unknown) => error instanceof IdentityInputError
  )
  assert.throws(
    () => externalIdentityFromInput({ email: 'maya@example.com' }),
    (error: unknown) => error instanceof IdentityInputError
  )
  assert.throws(
    () => externalIdentityFromInput({ localUUID: 'local-1', provider: 'cloudkit', subject: 'ck-1' }),
    (error: unknown) => error instanceof IdentityInputError
  )
})

test('invitation tokens are signed, account-bound, and expire', () => {
  const token = createInvitationToken({
    jti: 'invite-1',
    groupId: 'group-1',
    issuerAccountId: 'account-owner',
    targetAccountId: 'account-maya',
    identity: appleIdentity('apple-maya'),
    now: 1_000,
    expiresInSeconds: 60,
  })
  const verified = verifyInvitationToken(token, 1_010)
  assert.equal(verified.valid, true)
  if (!verified.valid) return

  assert.equal(verified.payload.targetAccountId, 'account-maya')
  assert.equal(invitationBelongsToAccount(verified.payload, 'account-maya'), true)
  assert.equal(invitationBelongsToAccount(verified.payload, 'account-other'), false)
  assert.deepEqual(invitationIdentity(verified.payload), appleIdentity('apple-maya'))
  assert.equal(invitationTokenHash(token).length, 64)
  assert.equal(verifyInvitationToken(token, 1_060).valid, false)
  assert.equal(verifyInvitationToken(`${token}tampered`, 1_010).valid, false)
})

function fakeIdentityInvitationDb() {
  const state = {
    identities: [] as Array<{
      id: string
      accountId: string
      provider: string
      subject: string
    }>,
    operations: [] as Array<Record<string, unknown>>,
    members: [] as Array<Record<string, unknown>>,
    users: {
      owner: { id: 'owner', name: 'Owner', email: 'owner@example.com', image: null },
      invitee: { id: 'invitee', name: 'Invitee', email: 'invitee@example.com', image: null },
    },
  }

  const db = {
    externalIdentity: {
      findUnique: async (args: any) => {
        const where = args.where
        const row = 'provider_subject' in where
          ? state.identities.find(
              (identity) =>
                identity.provider === where.provider_subject.provider &&
                identity.subject === where.provider_subject.subject
            )
          : state.identities.find(
              (identity) =>
                identity.accountId === where.accountId_provider.accountId &&
                identity.provider === where.accountId_provider.provider
            )
        return row ? { ...row } : null
      },
      create: async (args: any) => {
        const row = {
          id: `identity-${state.identities.length + 1}`,
          accountId: args.data.accountId,
          provider: args.data.provider,
          subject: args.data.subject,
        }
        state.identities.push(row)
        return { ...row }
      },
      findMany: async () => state.identities,
    },
    groupMember: {
      findUnique: async (args: any) => {
        const key = args.where.groupId_userId
        if (args.select?.group) return { group: { id: key.groupId, finalizedAt: null } }
        const member = state.members.find(
          (entry) => entry.groupId === key.groupId && entry.userId === key.userId
        )
        if (member) {
          return {
            ...member,
            user: state.users[member.userId as 'owner' | 'invitee'],
          }
        }
        return null
      },
      findUniqueOrThrow: async (args: any) => {
        const member = await db.groupMember.findUnique(args)
        if (!member) throw new Error('member not found')
        return member
      },
      create: async (args: any) => {
        const member = {
          id: `member-${state.members.length + 1}`,
          groupId: args.data.groupId,
          userId: args.data.userId,
          role: args.data.role,
          joinedAt: new Date(1_000),
        }
        state.members.push(member)
        return {
          ...member,
          user: state.users[member.userId as 'owner' | 'invitee'],
        }
      },
    },
    group: {
      findUnique: async () => ({ id: 'group-1', finalizedAt: null }),
    },
    ledgerOperation: {
      create: async (args: any) => {
        const operation = { ...args.data }
        state.operations.push(operation)
        return operation
      },
      findUnique: async (args: any) =>
        state.operations.find((operation) => operation.id === args.where.id) ?? null,
      updateMany: async (args: any) => {
        const operation = state.operations.find(
          (candidate) =>
            candidate.id === args.where.id && candidate.state === args.where.state &&
            candidate.requestHash === args.where.requestHash
        )
        if (!operation) return { count: 0 }
        Object.assign(operation, args.data)
        return { count: 1 }
      },
      update: async (args: any) => {
        const operation = state.operations.find((candidate) => candidate.id === args.where.id)
        if (!operation) throw new Error('operation not found')
        Object.assign(operation, args.data)
        return operation
      },
    },
  }

  return { db, state }
}

test('identity conflicts stay repairable and claims use the accepting API account', async () => {
  const { db, state } = fakeIdentityInvitationDb()
  const owner = await linkExternalIdentity({
    accountId: 'owner',
    provider: 'apple',
    subject: 'apple-owner',
    db: db as any,
  })
  assert.equal(owner.status, 'created')

  const invitee = await linkExternalIdentity({
    accountId: 'invitee',
    provider: 'apple',
    subject: 'apple-invitee',
    db: db as any,
  })
  assert.equal(invitee.status, 'created')

  const conflictingSubject = await linkExternalIdentity({
    accountId: 'owner',
    provider: 'apple',
    subject: 'apple-invitee',
    db: db as any,
  })
  assert.equal(conflictingSubject.status, 'repair_required')
  assert.equal(state.identities.length, 2)

  state.members.push({
    id: 'member-owner',
    groupId: 'group-1',
    userId: 'owner',
    role: 'ADMIN',
    joinedAt: new Date(1_000),
  })
  const issued = await createGroupInvitation({
    groupId: 'group-1',
    issuerAccountId: 'owner',
    identity: { provider: 'apple', subject: 'apple-invitee' },
    now: 1_000,
    expiresInSeconds: 60,
    db: db as any,
  })

  await assert.rejects(
    () => claimGroupInvitation({ token: issued.token, acceptingAccountId: 'owner', now: 1_001, db: db as any }),
    (error: unknown) => error instanceof InvitationFlowError && error.code === 'invitation_wrong_account'
  )

  const claimed = await claimGroupInvitation({
    token: issued.token,
    acceptingAccountId: 'invitee',
    now: 1_001,
    db: db as any,
  })
  assert.equal(claimed.created, true)
  assert.equal(claimed.member.userId, 'invitee')
  assert.equal(state.members.filter((member) => member.userId === 'invitee').length, 1)

  await assert.rejects(
    () => claimGroupInvitation({ token: issued.token, acceptingAccountId: 'invitee', now: 1_002, db: db as any }),
    (error: unknown) => error instanceof InvitationFlowError && error.code === 'invitation_already_used'
  )

  const secondInvite = await createGroupInvitation({
    groupId: 'group-1',
    issuerAccountId: 'owner',
    identity: { provider: 'apple', subject: 'apple-invitee' },
    now: 2_000,
    expiresInSeconds: 60,
    db: db as any,
  })
  const idempotent = await claimGroupInvitation({
    token: secondInvite.token,
    acceptingAccountId: 'invitee',
    now: 2_001,
    db: db as any,
  })
  assert.equal(idempotent.created, false)
  assert.equal(state.members.filter((member) => member.userId === 'invitee').length, 1)
})
