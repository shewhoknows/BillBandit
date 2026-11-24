/**
 * The identity, friend, and CloudKit-import state machines in one place.
 * Full tables, guards, and invariants: docs/state-machines/identity-friends-import.md.
 * TLA+ models: specs/tla/identity-friends-import/.
 *
 * The database stores these states implicitly (nullable timestamps, counters,
 * row presence). The derive functions name them; the transition tables list
 * every allowed move. A move outside the table is a bug, so it throws.
 */

export class IllegalTransitionError extends Error {
  constructor(machine: string, from: string, to: string) {
    super(`${machine}: illegal transition ${from} -> ${to}`)
    this.name = 'IllegalTransitionError'
  }
}

function assertIn<S extends string>(machine: string, table: Record<S, readonly S[]>, from: S, to: S) {
  if (!table[from].includes(to)) throw new IllegalTransitionError(machine, from, to)
}

// ── Account ────────────────────────────────────────────────────────────────
// active --delete--> deleted (terminal). A later Sign in with Apple creates a
// new active account; the deleted row is never reactivated.
export type AccountState = 'active' | 'deleted'
export const ACCOUNT_TRANSITIONS: Record<AccountState, readonly AccountState[]> = {
  active: ['deleted'],
  deleted: [],
}
export function deriveAccountState(user: { deletedAt: Date | null }): AccountState {
  return user.deletedAt ? 'deleted' : 'active'
}
export function assertAccountTransition(from: AccountState, to: AccountState) {
  assertIn('account', ACCOUNT_TRANSITIONS, from, to)
}

// ── Friend invitation (one reusable code per inviter) ──────────────────────
// none --create--> active --time--> expired --rotate--> active (new code)
// active|expired --inviter deleted--> none
export type InvitationState = 'none' | 'active' | 'expired'
export const INVITATION_TRANSITIONS: Record<InvitationState, readonly InvitationState[]> = {
  none: ['active'],
  active: ['expired', 'none'],
  expired: ['active', 'none'],
}
export function deriveInvitationState(
  invitation: { expiresAt: Date } | null,
  now: Date
): InvitationState {
  if (!invitation) return 'none'
  return invitation.expiresAt > now ? 'active' : 'expired'
}

// ── Friendship (one row per unordered pair, stored sorted) ─────────────────
// none --claim--> accepted --claim--> accepted (no-op)
// accepted --unfriend | account deleted--> none
// PENDING and REJECTED exist in the Prisma enum but no code path writes them.
export type FriendshipState = 'none' | 'accepted'
export const FRIENDSHIP_TRANSITIONS: Record<FriendshipState, readonly FriendshipState[]> = {
  none: ['accepted'],
  accepted: ['accepted', 'none'],
}
export function deriveFriendshipState(row: { status: string } | null): FriendshipState {
  return row?.status === 'ACCEPTED' ? 'accepted' : 'none'
}
export function assertFriendshipTransition(from: FriendshipState, to: FriendshipState) {
  assertIn('friendship', FRIENDSHIP_TRANSITIONS, from, to)
}

// ── Friend-code failure limit (per claiming account) ──────────────────────
// open (no row / window over) --wrong code--> counting(n) --nth wrong code,
// n = limit--> blocked --window over--> open. A successful claim does not
// change this state: resetting on success let one known-good code reopen the
// window forever.
export type ClaimLimitState = 'open' | 'counting' | 'blocked'
export function deriveClaimLimitState(
  row: { windowStartedAt: Date; failureCount: number; blockedUntil: Date | null } | null,
  now: Date,
  windowSeconds: number
): ClaimLimitState {
  if (!row) return 'open'
  if (row.blockedUntil && row.blockedUntil > now) return 'blocked'
  if (row.windowStartedAt.getTime() <= now.getTime() - windowSeconds * 1000) return 'open'
  return row.failureCount > 0 ? 'counting' : 'open'
}

// ── CloudKit ledger import (LedgerImport.state) ────────────────────────────
// PENDING --prepare ok--> RUNNING --all records done--> COMPLETED (terminal)
// PENDING|RUNNING --validation / record failure / checksum change--> FAILED
// FAILED --same checksum, validation ok--> RUNNING (repair retry)
// RUNNING --re-run or resume after a crash--> RUNNING
export type ImportState = 'PENDING' | 'RUNNING' | 'COMPLETED' | 'FAILED'
export const IMPORT_TRANSITIONS: Record<ImportState, readonly ImportState[]> = {
  PENDING: ['RUNNING', 'FAILED'],
  RUNNING: ['RUNNING', 'COMPLETED', 'FAILED'],
  FAILED: ['RUNNING', 'FAILED'],
  COMPLETED: [],
}
export function assertImportTransition(from: string, to: ImportState) {
  assertIn('cloudkit import', IMPORT_TRANSITIONS, from as ImportState, to)
}

// LedgerImportRecord.state: PENDING --processed--> IMPORTED (terminal)
// PENDING --failed--> QUARANTINED --retry--> PENDING. A quarantined row that
// belongs to an older import of the same account is processed in place
// (QUARANTINED --processed--> IMPORTED). Metadata rows are SKIPPED.
export type ImportRecordState = 'PENDING' | 'IMPORTED' | 'QUARANTINED' | 'SKIPPED'
export const IMPORT_RECORD_TRANSITIONS: Record<ImportRecordState, readonly ImportRecordState[]> = {
  PENDING: ['PENDING', 'IMPORTED', 'QUARANTINED'],
  QUARANTINED: ['PENDING', 'QUARANTINED', 'IMPORTED'],
  IMPORTED: [],
  SKIPPED: [],
}
export function assertImportRecordTransition(from: string, to: ImportRecordState) {
  assertIn('cloudkit import record', IMPORT_RECORD_TRANSITIONS, from as ImportRecordState, to)
}

// ── CloudKit identity link (ExternalIdentity provider 'cloudkit') ──────────
// unlinked --owner's import prepare | device link--> linked(subject)
// linked --same account, same subject--> linked (no-op)
// linked --account deleted--> unlinked (row deleted with the account)
// A request for a subject linked to another account, or a second subject for
// a linked account, is refused with identity_conflict: a link never moves.
export type CloudKitLinkState = 'unlinked' | 'linked'
export const CLOUDKIT_LINK_TRANSITIONS: Record<CloudKitLinkState, readonly CloudKitLinkState[]> = {
  unlinked: ['linked'],
  linked: ['linked', 'unlinked'],
}
export function assertCloudKitLinkTransition(from: CloudKitLinkState, to: CloudKitLinkState) {
  assertIn('cloudkit link', CLOUDKIT_LINK_TRANSITIONS, from, to)
}

// ── Legacy person resolution (person LedgerImportRecord.targetId) ─────────
// unresolved --phase 1 commit (all people of the import in one
// transaction)--> owner | friend | placeholder. Terminal: later runs read the
// frozen answer and never re-decide, even if a link or friendship appears.
export type LegacyPersonResolution = 'unresolved' | 'owner' | 'friend' | 'placeholder'
export const LEGACY_PERSON_TRANSITIONS: Record<
  LegacyPersonResolution,
  readonly LegacyPersonResolution[]
> = {
  unresolved: ['owner', 'friend', 'placeholder'],
  owner: [],
  friend: [],
  placeholder: [],
}
