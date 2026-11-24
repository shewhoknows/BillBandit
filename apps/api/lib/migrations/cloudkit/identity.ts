import type { Prisma } from '@prisma/client'
import { normalizedFriendPair } from '../../friends'
import { assertCloudKitLinkTransition } from '../../identity-friends-state'
import { sha256 } from './normalize'
import { CloudKitImportNeedsRepairError, CloudKitImportValidationError } from './types'

/**
 * CloudKit identity links and legacy-person placeholders.
 * State machine and safety argument: docs/state-machines/identity-friends-import.md §6.
 *
 * A link says "CloudKit user record name S belongs to API account A". It is
 * written only for the authenticated caller, from the caller's own device
 * (the owner of a legacy export, or the link endpoint). The server cannot
 * prove S, so a link is trust-on-first-use and kept narrow:
 *   - one subject per account and one account per subject (unique indexes),
 *     refused rather than moved when either side is already taken;
 *   - a link alone never puts an account into someone else's group. A legacy
 *     friend resolves to their account only when that account is also an
 *     accepted server friend of the importer (two consents: the friend's own
 *     link and the friendship). Everyone else becomes a placeholder member.
 */

export const CLOUDKIT_IDENTITY_PROVIDER = 'cloudkit'
export const LEGACY_PERSON_PROVIDER = 'cloudkit-legacy-person'

type DbTransaction = Prisma.TransactionClient

/** Same key space as the import locks in service.ts (`cloudkit-import:<key>`). */
export async function lockCloudKitKey(tx: DbTransaction, key: string): Promise<void> {
  await tx.$queryRaw`SELECT 1 AS "locked" FROM pg_advisory_xact_lock(hashtextextended(${`cloudkit-import:${key}`}, 0))`
}

export function normalizeCloudKitSubject(value: unknown, path = 'cloudKitRecordName'): string {
  if (typeof value !== 'string') {
    throw new CloudKitImportValidationError(
      'invalid_envelope',
      `${path} must be a CloudKit user record name`,
    )
  }
  const subject = value.trim()
  if (subject.length === 0 || subject.length > 255 || /\s/.test(subject)) {
    throw new CloudKitImportValidationError(
      'invalid_envelope',
      `${path} must be a CloudKit user record name`,
    )
  }
  return subject
}

export type CloudKitLinkOutcome = 'linked' | 'already_linked'

/**
 * Link `subject` to `accountId`, or confirm the existing link. Runs inside the
 * caller's transaction; takes the account import lock, then the subject lock
 * (always in that order, so two accounts racing for one subject cannot
 * deadlock and exactly one wins).
 */
export async function linkCloudKitIdentity(
  tx: DbTransaction,
  accountId: string,
  rawSubject: string,
  via: 'cloudkit-import' | 'device',
  now: Date,
): Promise<CloudKitLinkOutcome> {
  const subject = normalizeCloudKitSubject(rawSubject)
  await lockCloudKitKey(tx, accountId)
  await lockCloudKitKey(tx, `identity:${subject}`)
  const bySubject = await tx.externalIdentity.findUnique({
    where: { provider_subject: { provider: CLOUDKIT_IDENTITY_PROVIDER, subject } },
    select: { accountId: true },
  })
  if (bySubject) {
    if (bySubject.accountId === accountId) return 'already_linked'
    throw new CloudKitImportNeedsRepairError(
      'This iCloud account is already linked to another BillBandit account',
      'identity_conflict',
      { conflict: 'subject_linked_elsewhere' },
    )
  }
  const byAccount = await tx.externalIdentity.findUnique({
    where: { accountId_provider: { accountId, provider: CLOUDKIT_IDENTITY_PROVIDER } },
    select: { subject: true },
  })
  if (byAccount) {
    throw new CloudKitImportNeedsRepairError(
      'This BillBandit account is already linked to a different iCloud account',
      'identity_conflict',
      { conflict: 'account_linked_elsewhere' },
    )
  }
  const user = await tx.user.findUnique({ where: { id: accountId }, select: { deletedAt: true } })
  if (!user || user.deletedAt) {
    throw new CloudKitImportNeedsRepairError(
      'the authenticated account does not exist',
      'identity_not_claimed',
    )
  }
  assertCloudKitLinkTransition('unlinked', 'linked')
  await tx.externalIdentity.create({
    data: {
      accountId,
      provider: CLOUDKIT_IDENTITY_PROVIDER,
      subject,
      metadata: { linkedVia: via, linkedAt: now.toISOString() },
    },
  })
  return 'linked'
}

export async function linkedCloudKitAccount(
  tx: DbTransaction,
  subject: string,
): Promise<string | null> {
  const row = await tx.externalIdentity.findUnique({
    where: { provider_subject: { provider: CLOUDKIT_IDENTITY_PROVIDER, subject } },
    select: { accountId: true },
  })
  return row?.accountId ?? null
}

/**
 * The account a legacy friend resolves to, or null for a placeholder: the
 * friend linked this CloudKit identity from their own device, the account is
 * live, and the importer and the friend are accepted server friends.
 */
export async function resolveLegacyFriendAccount(
  tx: DbTransaction,
  importerAccountId: string,
  subject: string,
): Promise<string | null> {
  const friendAccountId = await linkedCloudKitAccount(tx, subject)
  if (!friendAccountId || friendAccountId === importerAccountId) return null
  const friend = await tx.user.findUnique({
    where: { id: friendAccountId },
    select: { deletedAt: true },
  })
  if (!friend || friend.deletedAt) return null
  const friendship = await tx.friendship.findUnique({
    where: { fromId_toId: normalizedFriendPair(importerAccountId, friendAccountId) },
    select: { status: true },
  })
  return friendship?.status === 'ACCEPTED' ? friendAccountId : null
}

/**
 * One placeholder per legacy person per importer. A connected friend (has a
 * CloudKit identity) is keyed by that identity, so the same friend in several
 * legacy groups is one member; a name-only person is keyed by its person id.
 */
export function legacyPersonKey(
  importerAccountId: string,
  cloudKitRecordName: string | null,
  personSourceId: string,
): string {
  return cloudKitRecordName
    ? `${importerAccountId}:ck:${cloudKitRecordName}`
    : `${importerAccountId}:person:${personSourceId}`
}

export function legacyPersonAccountId(key: string): string {
  return `cloudkit-person-${sha256(key).slice(0, 32)}`
}

/**
 * Create (or find) the placeholder account for a legacy person. It has no
 * Apple account, password, phone or username, so nobody can sign in as it;
 * it exists so expenses, splits and payments keep an exact owner.
 */
export async function ensureLegacyPersonAccount(
  tx: DbTransaction,
  input: {
    key: string
    importerAccountId: string
    importId: string
    personSourceId: string
    cloudKitRecordName: string | null
    displayName: string
  },
): Promise<string> {
  const id = legacyPersonAccountId(input.key)
  await tx.user.upsert({
    where: { id },
    create: {
      id,
      email: `${id}@legacy-import.billbandit.invalid`,
      name: input.displayName,
      preferredName: input.displayName,
    },
    update: {},
  })
  const marker = await tx.externalIdentity.upsert({
    where: { provider_subject: { provider: LEGACY_PERSON_PROVIDER, subject: input.key } },
    create: {
      accountId: id,
      provider: LEGACY_PERSON_PROVIDER,
      subject: input.key,
      metadata: {
        importerAccountId: input.importerAccountId,
        importId: input.importId,
        personSourceId: input.personSourceId,
        cloudKitRecordName: input.cloudKitRecordName,
      },
    },
    update: {},
    select: { accountId: true },
  })
  if (marker.accountId !== id) {
    throw new CloudKitImportNeedsRepairError(
      'legacy person placeholder belongs to another account',
      'identity_conflict',
    )
  }
  return id
}
