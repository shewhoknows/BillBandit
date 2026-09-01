export const EXTERNAL_IDENTITY_PROVIDERS = {
  APPLE: 'apple',
  CLOUDKIT: 'cloudkit',
} as const

export type ExternalIdentityProvider =
  (typeof EXTERNAL_IDENTITY_PROVIDERS)[keyof typeof EXTERNAL_IDENTITY_PROVIDERS]

export type ExternalIdentityRef = {
  provider: ExternalIdentityProvider
  subject: string
}

export type IdentityConflictReason =
  | 'subject_linked_to_different_account'
  | 'account_linked_to_different_subject'
  | 'identity_link_raced'

export type IdentityResolution =
  | {
      status: 'linked'
      accountId: string
      identityId: string
      identity: ExternalIdentityRef
    }
  | {
      status: 'created'
      accountId: string
      identityId: string
      identity: ExternalIdentityRef
    }
  | {
      status: 'repair_required'
      identity: ExternalIdentityRef
      reason: IdentityConflictReason
      existingAccountId?: string
      existingSubject?: string
    }

export class IdentityInputError extends Error {
  readonly code = 'invalid_external_identity'

  constructor(message: string) {
    super(message)
    this.name = 'IdentityInputError'
  }
}

export class IdentityRepairRequiredError extends Error {
  readonly code = 'identity_repair_required'
  readonly reason: IdentityConflictReason
  readonly existingAccountId?: string
  readonly existingSubject?: string

  constructor(
    reason: IdentityConflictReason,
    message: string,
    details: { existingAccountId?: string; existingSubject?: string } = {}
  ) {
    super(message)
    this.name = 'IdentityRepairRequiredError'
    this.reason = reason
    this.existingAccountId = details.existingAccountId
    this.existingSubject = details.existingSubject
  }
}

export function normalizeExternalIdentityProvider(value: unknown): ExternalIdentityProvider {
  if (typeof value !== 'string') {
    throw new IdentityInputError('External identity provider is required.')
  }

  const provider = value.trim().toLowerCase()
  if (
    provider !== EXTERNAL_IDENTITY_PROVIDERS.APPLE &&
    provider !== EXTERNAL_IDENTITY_PROVIDERS.CLOUDKIT
  ) {
    throw new IdentityInputError('Only Apple and CloudKit identities can be linked.')
  }
  return provider
}

export function normalizeExternalIdentitySubject(value: unknown): string {
  if (typeof value !== 'string') {
    throw new IdentityInputError('External identity subject is required.')
  }

  const subject = value.trim()
  if (!subject) {
    throw new IdentityInputError('External identity subject is required.')
  }
  if (subject.length > 512) {
    throw new IdentityInputError('External identity subject is too long.')
  }
  return subject
}

export function appleIdentity(subject: unknown): ExternalIdentityRef {
  return {
    provider: EXTERNAL_IDENTITY_PROVIDERS.APPLE,
    subject: normalizeExternalIdentitySubject(subject),
  }
}

export function cloudKitIdentity(recordName: unknown): ExternalIdentityRef {
  return {
    provider: EXTERNAL_IDENTITY_PROVIDERS.CLOUDKIT,
    subject: normalizeExternalIdentitySubject(recordName),
  }
}

export function externalIdentity(provider: unknown, subject: unknown): ExternalIdentityRef {
  return {
    provider: normalizeExternalIdentityProvider(provider),
    subject: normalizeExternalIdentitySubject(subject),
  }
}

/**
 * Identity input is deliberately narrow. Display names, email addresses, and
 * local UUIDs are not accepted as identity references and therefore cannot be
 * used as an accidental merge key.
 */
export function externalIdentityFromInput(input: unknown): ExternalIdentityRef {
  if (!input || typeof input !== 'object') {
    throw new IdentityInputError('An explicit external identity is required.')
  }

  const value = input as Record<string, unknown>
  if ('email' in value || 'name' in value || 'displayName' in value || 'localUUID' in value) {
    throw new IdentityInputError(
      'Display names, email addresses, and local UUIDs cannot identify a shared member.'
    )
  }

  return externalIdentity(value.provider, value.subject ?? value.recordName)
}
