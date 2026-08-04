import type { Prisma, PrismaClient } from '@prisma/client'

export const CLOUDKIT_IMPORT_SOURCE = 'cloudkit' as const

export const CLOUDKIT_RECORD_TYPES = {
  PERSON: 'person',
  GROUP: 'group',
  EXPENSE: 'expense',
  SPLIT: 'split',
  SETTLEMENT: 'settlement',
  ACTIVITY: 'activity',
} as const

export type CloudKitRecordType =
  (typeof CLOUDKIT_RECORD_TYPES)[keyof typeof CLOUDKIT_RECORD_TYPES]

export type JsonObject = { [key: string]: JsonValue }
export type JsonValue = string | number | boolean | null | JsonObject | JsonValue[]

export type ExactMoney = {
  minorUnits: bigint
  currencyCode: string
  currencyExponent: number
}

export type CloudKitMemberClaim = {
  personRecordName: string
  cloudKitRecordName: string | null
  accountId: string | null
}

export type CloudKitSourceRecord = {
  database: string
  zoneName: string
  zoneOwnerName: string
  recordType: CloudKitRecordType
  recordName: string
  sourceId: string
  checksum: string
  logicalKey: string
  fields: JsonObject
}

export type NormalizedCloudKitExport = {
  source: typeof CLOUDKIT_IMPORT_SOURCE
  sourceKey: string
  sourceChecksum: string
  ownerCloudKitRecordName: string
  defaultCurrencyCode: string | null
  defaultCurrencyExponent: number | null
  claims: CloudKitMemberClaim[]
  records: CloudKitSourceRecord[]
  duplicateRecordCount: number
}

export type CloudKitImportStatus = 'pending' | 'running' | 'completed' | 'needs-repair'

export type CloudKitImportCounts = {
  people: number
  groups: number
  expenses: number
  splits: number
  settlements: number
  activity: number
  importedRecords: number
  duplicateRecords: number
}

export type CloudKitMigrationMarker = {
  source: typeof CLOUDKIT_IMPORT_SOURCE
  migrationId: string
  status: 'complete'
  dualWriteEnabled: false
  recoveryReadOnly: true
  importedAt: string
  serverGroupId: string
  sourceGroupRecordName: string
}

export type CloudKitImportResult = {
  importId: string
  source: typeof CLOUDKIT_IMPORT_SOURCE
  sourceKey: string
  sourceChecksum: string | null
  status: CloudKitImportStatus
  counts: CloudKitImportCounts
  serverGroupIds: string[]
  serverGroupId: string | null
  migration: {
    status: 'pending' | 'in_progress' | 'complete' | 'blocked'
    source: typeof CLOUDKIT_IMPORT_SOURCE
    migrationId: string
    importedAt: string | null
    dualWriteEnabled: false
    recoveryReadOnly: boolean
  }
  migrationMarkers: CloudKitMigrationMarker[]
  startedAt: string | null
  completedAt: string | null
  needsRepairReason: string | null
}

export type CloudKitImportDb = PrismaClient | Prisma.TransactionClient

export type CloudKitImportRequest = {
  accountId: string
  export: unknown
  db?: CloudKitImportDb
  now?: Date
}

export type CloudKitImportLookup = {
  accountId: string
  importId: string
  db?: CloudKitImportDb
}

export type CloudKitValidationErrorCode =
  | 'invalid_envelope'
  | 'invalid_record'
  | 'unsupported_record_type'
  | 'duplicate_source_record_conflict'
  | 'missing_source_owner'
  | 'missing_member_claim'
  | 'identity_not_claimed'
  | 'money_not_exact'
  | 'money_not_representable'
  | 'dependency_missing'
  | 'source_checksum_conflict'
  | 'completed_import_frozen'
  | 'import_not_found'

export class CloudKitImportValidationError extends Error {
  readonly name = 'CloudKitImportValidationError'

  constructor(
    public readonly code: CloudKitValidationErrorCode,
    message: string,
    public readonly details: Record<string, unknown> = {}
  ) {
    super(message)
  }
}

export class CloudKitImportNeedsRepairError extends Error {
  readonly name = 'CloudKitImportNeedsRepairError'

  constructor(
    message: string,
    public readonly code: CloudKitValidationErrorCode = 'dependency_missing',
    public readonly details: Record<string, unknown> = {}
  ) {
    super(message)
  }
}
