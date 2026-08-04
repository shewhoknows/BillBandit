import { Prisma } from '@prisma/client'
import type { PrismaClient } from '@prisma/client'
import { prisma } from '../prisma'
import {
  EXTERNAL_IDENTITY_PROVIDERS,
  externalIdentity,
  type ExternalIdentityProvider,
  type ExternalIdentityRef,
  type IdentityResolution,
} from './types'

type IdentityDb = PrismaClient | Prisma.TransactionClient

type StoredExternalIdentity = {
  id: string
  accountId: string
  provider: string
  subject: string
}

export type IdentityLinkOptions = {
  accountId: string
  provider: ExternalIdentityProvider
  subject: string
  metadata?: Prisma.InputJsonValue
  db?: IdentityDb
}

export type ResolvedExternalIdentity = {
  accountId: string
  identityId: string
  identity: ExternalIdentityRef
}

function asIdentity(row: StoredExternalIdentity): ResolvedExternalIdentity {
  return {
    accountId: row.accountId,
    identityId: row.id,
    identity: externalIdentity(row.provider, row.subject),
  }
}

function isUniqueConstraint(error: unknown) {
  return error instanceof Prisma.PrismaClientKnownRequestError && error.code === 'P2002'
}

/**
 * Link one provider subject to one API account without guessing. Both
 * uniqueness constraints are checked before writing, and a conflict is
 * returned as a repair state instead of changing either existing link.
 */
export async function linkExternalIdentity({
  accountId,
  provider,
  subject,
  metadata,
  db = prisma,
}: IdentityLinkOptions): Promise<IdentityResolution> {
  const identity = externalIdentity(provider, subject)
  const [bySubject, byAccount] = await Promise.all([
    db.externalIdentity.findUnique({
      where: {
        provider_subject: {
          provider: identity.provider,
          subject: identity.subject,
        },
      },
      select: { id: true, accountId: true, provider: true, subject: true },
    }),
    db.externalIdentity.findUnique({
      where: {
        accountId_provider: {
          accountId,
          provider: identity.provider,
        },
      },
      select: { id: true, accountId: true, provider: true, subject: true },
    }),
  ])

  if (bySubject && bySubject.accountId !== accountId) {
    return {
      status: 'repair_required',
      identity,
      reason: 'subject_linked_to_different_account',
      existingAccountId: bySubject.accountId,
    }
  }

  if (byAccount && byAccount.subject !== identity.subject) {
    return {
      status: 'repair_required',
      identity,
      reason: 'account_linked_to_different_subject',
      existingAccountId: byAccount.accountId,
      existingSubject: byAccount.subject,
    }
  }

  if (bySubject) {
    return {
      status: 'linked',
      ...asIdentity(bySubject),
    }
  }

  if (byAccount) {
    return {
      status: 'linked',
      ...asIdentity(byAccount),
    }
  }

  try {
    const created = await db.externalIdentity.create({
      data: {
        accountId,
        provider: identity.provider,
        subject: identity.subject,
        metadata,
      },
      select: { id: true, accountId: true, provider: true, subject: true },
    })
    return {
      status: 'created',
      ...asIdentity(created),
    }
  } catch (error) {
    // A concurrent request may have won either unique index after the reads.
    // Re-read and classify the result; never overwrite the winner.
    if (!isUniqueConstraint(error)) throw error

    const [racedBySubject, racedByAccount] = await Promise.all([
      db.externalIdentity.findUnique({
        where: {
          provider_subject: {
            provider: identity.provider,
            subject: identity.subject,
          },
        },
        select: { id: true, accountId: true, provider: true, subject: true },
      }),
      db.externalIdentity.findUnique({
        where: {
          accountId_provider: {
            accountId,
            provider: identity.provider,
          },
        },
        select: { id: true, accountId: true, provider: true, subject: true },
      }),
    ])

    if (racedBySubject?.accountId === accountId) {
      return { status: 'linked', ...asIdentity(racedBySubject) }
    }
    if (racedBySubject) {
      return {
        status: 'repair_required',
        identity,
        reason: 'identity_link_raced',
        existingAccountId: racedBySubject.accountId,
      }
    }
    if (racedByAccount) {
      return {
        status: 'repair_required',
        identity,
        reason: 'identity_link_raced',
        existingAccountId: racedByAccount.accountId,
        existingSubject: racedByAccount.subject,
      }
    }
    throw error
  }
}

export async function resolveExternalIdentity(
  provider: ExternalIdentityProvider,
  subject: string,
  db: IdentityDb = prisma
): Promise<ResolvedExternalIdentity | null> {
  const identity = externalIdentity(provider, subject)
  const row = await db.externalIdentity.findUnique({
    where: {
      provider_subject: {
        provider: identity.provider,
        subject: identity.subject,
      },
    },
    select: { id: true, accountId: true, provider: true, subject: true },
  })
  return row ? asIdentity(row) : null
}

export function linkAppleProviderSubject(
  accountId: string,
  subject: string,
  options: Omit<IdentityLinkOptions, 'accountId' | 'provider' | 'subject'> = {}
) {
  return linkExternalIdentity({
    ...options,
    accountId,
    provider: EXTERNAL_IDENTITY_PROVIDERS.APPLE,
    subject,
  })
}

export function linkCloudKitRecordName(
  accountId: string,
  recordName: string,
  options: Omit<IdentityLinkOptions, 'accountId' | 'provider' | 'subject'> = {}
) {
  return linkExternalIdentity({
    ...options,
    accountId,
    provider: EXTERNAL_IDENTITY_PROVIDERS.CLOUDKIT,
    subject: recordName,
  })
}

export const resolveAppleProviderSubject = (subject: string, db?: IdentityDb) =>
  resolveExternalIdentity(EXTERNAL_IDENTITY_PROVIDERS.APPLE, subject, db)

export const resolveCloudKitRecordName = (recordName: string, db?: IdentityDb) =>
  resolveExternalIdentity(EXTERNAL_IDENTITY_PROVIDERS.CLOUDKIT, recordName, db)

/**
 * Apple sign-in already has an explicit `(provider, providerAccountId)` row
 * in the NextAuth Account table. This helper backfills the T-06 external
 * identity row from that exact subject when needed. It never consults email,
 * name, or any local identifier.
 */
export async function resolveOrBackfillAppleIdentity(
  subject: string,
  db: IdentityDb = prisma
): Promise<ResolvedExternalIdentity | null> {
  const identity = externalIdentity(EXTERNAL_IDENTITY_PROVIDERS.APPLE, subject)
  const existing = await resolveExternalIdentity(identity.provider, identity.subject, db)
  if (existing) return existing

  if (!('account' in db)) return null

  const account = await db.account.findUnique({
    where: {
      provider_providerAccountId: {
        provider: EXTERNAL_IDENTITY_PROVIDERS.APPLE,
        providerAccountId: identity.subject,
      },
    },
    select: { userId: true },
  })
  if (!account) return null

  const linked = await linkExternalIdentity({
    accountId: account.userId,
    provider: identity.provider,
    subject: identity.subject,
    db,
  })
  if (linked.status === 'repair_required') return null
  return {
    accountId: linked.accountId,
    identityId: linked.identityId,
    identity: linked.identity,
  }
}

export async function listExternalIdentities(
  accountId: string,
  db: IdentityDb = prisma
) {
  return db.externalIdentity.findMany({
    where: { accountId },
    select: {
      id: true,
      accountId: true,
      provider: true,
      subject: true,
      metadata: true,
      createdAt: true,
      updatedAt: true,
    },
    orderBy: { createdAt: 'asc' },
  })
}
