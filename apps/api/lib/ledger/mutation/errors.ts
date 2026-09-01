import type { MutationConflictDetails, MutationReadModelHint } from './types'

export type MutationErrorCode =
  | 'INVALID_MUTATION'
  | 'INVALID_MONEY'
  | 'GROUP_NOT_FOUND'
  | 'GROUP_ARCHIVED'
  | 'GROUP_FINALIZED'
  | 'FORBIDDEN'
  | 'NOT_FOUND'
  | 'MEMBER_NOT_FOUND'
  | 'ALREADY_MEMBER'
  | 'INVALID_MEMBERSHIP'
  | 'INVALID_SETTLEMENT'
  | 'SETTLEMENT_NOT_FOUND'
  | 'ALREADY_REVERSED'
  | 'TRANSFER_NOT_FOUND'
  | 'TRANSFER_MISMATCH'
  | 'REVISION_CONFLICT'
  | 'IDEMPOTENCY_KEY_REUSED'
  | 'MUTATION_IN_PROGRESS'
  | 'MUTATION_FAILED'

export class LedgerMutationError extends Error {
  public readonly status: number
  public readonly details?: Record<string, unknown>

  constructor(
    public readonly code: MutationErrorCode | string,
    status: number,
    message = code,
    details?: Record<string, unknown>
  ) {
    super(message)
    this.name = 'LedgerMutationError'
    this.status = status
    this.details = details
  }
}

export class MutationConflictError extends LedgerMutationError {
  constructor(
    code: 'REVISION_CONFLICT' | 'IDEMPOTENCY_KEY_REUSED',
    details: MutationConflictDetails,
    message = code === 'REVISION_CONFLICT'
      ? 'The shared ledger changed; refresh before retrying this operation.'
      : 'The operation ID is already bound to a different request.'
  ) {
    super(code, 409, message, details)
  }
}

export function isMutationConflict(error: unknown): error is MutationConflictError {
  return error instanceof MutationConflictError
}

export function conflictReadModel(input: {
  groupId: string
  revision: number
  simplifyDebts?: boolean | null
  isArchived?: boolean | null
  finalizedAt?: Date | string | null
}): MutationReadModelHint {
  return {
    kind: 'shared-ledger',
    groupId: input.groupId,
    revision: input.revision,
    readRevision: input.revision,
    simplifyDebts: input.simplifyDebts ?? null,
    isArchived: input.isArchived ?? null,
    finalizedAt:
      input.finalizedAt instanceof Date
        ? input.finalizedAt.toISOString()
        : input.finalizedAt ?? null,
  }
}

export const MutationCommandError = LedgerMutationError
