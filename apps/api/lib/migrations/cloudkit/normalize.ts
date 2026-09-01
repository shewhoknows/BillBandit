import { createHash } from 'node:crypto'
import { getCurrencyExponent, normalizeCurrencyCode } from '../../settlement/money/registry'
import { parseDecimalToMinorUnits } from '../../settlement/money/canonical'
import {
  CLOUDKIT_IMPORT_SOURCE,
  CLOUDKIT_RECORD_TYPES,
  type CloudKitMemberClaim,
  type CloudKitRecordType,
  type CloudKitSourceRecord,
  CloudKitImportValidationError,
  type ExactMoney,
  type JsonObject,
  type JsonValue,
  type NormalizedCloudKitExport,
} from './types'

type RawObject = Record<string, unknown>

type SourceKeyInput = Pick<
  CloudKitSourceRecord,
  'database' | 'zoneName' | 'zoneOwnerName' | 'recordType' | 'recordName'
> & { checksum?: string }

export type MoneyContext = {
  currencyCode?: string | null
  currencyExponent?: number | null
}

const recordTypeAliases: Record<string, CloudKitRecordType> = {
  bbperson: CLOUDKIT_RECORD_TYPES.PERSON,
  person: CLOUDKIT_RECORD_TYPES.PERSON,
  bbgroup: CLOUDKIT_RECORD_TYPES.GROUP,
  group: CLOUDKIT_RECORD_TYPES.GROUP,
  bbexpense: CLOUDKIT_RECORD_TYPES.EXPENSE,
  expense: CLOUDKIT_RECORD_TYPES.EXPENSE,
  bbsplit: CLOUDKIT_RECORD_TYPES.SPLIT,
  bbexpensesplit: CLOUDKIT_RECORD_TYPES.SPLIT,
  split: CLOUDKIT_RECORD_TYPES.SPLIT,
  settlement: CLOUDKIT_RECORD_TYPES.SETTLEMENT,
  bbsettlement: CLOUDKIT_RECORD_TYPES.SETTLEMENT,
  activity: CLOUDKIT_RECORD_TYPES.ACTIVITY,
  bbactivity: CLOUDKIT_RECORD_TYPES.ACTIVITY,
}

function object(value: unknown, path: string): RawObject {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new CloudKitImportValidationError('invalid_envelope', `${path} must be an object`)
  }
  return value as RawObject
}

function optionalObject(value: unknown, path: string): RawObject | null {
  if (value === undefined || value === null) return null
  return object(value, path)
}

function requiredString(value: unknown, path: string): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new CloudKitImportValidationError('invalid_envelope', `${path} must be a non-empty string`)
  }
  return value.trim()
}

function optionalString(value: unknown, path: string): string | null {
  if (value === undefined || value === null) return null
  return requiredString(value, path)
}

function jsonValue(value: unknown, path: string): JsonValue {
  if (value === null) return null
  if (typeof value === 'string' || typeof value === 'boolean') return value
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) {
      throw new CloudKitImportValidationError('invalid_record', `${path} contains a non-finite number`)
    }
    return value
  }
  if (Array.isArray(value)) return value.map((entry, index) => jsonValue(entry, `${path}[${index}]`))
  if (typeof value === 'object') {
    const result: JsonObject = {}
    for (const [key, entry] of Object.entries(value as RawObject)) {
      if (entry === undefined) continue
      result[key] = jsonValue(entry, `${path}.${key}`)
    }
    return result
  }
  throw new CloudKitImportValidationError('invalid_record', `${path} is not JSON data`)
}

function jsonObject(value: unknown, path: string): JsonObject {
  const normalized = jsonValue(value, path)
  if (normalized === null || Array.isArray(normalized) || typeof normalized !== 'object') {
    throw new CloudKitImportValidationError('invalid_record', `${path} must be an object`)
  }
  return normalized
}

function canonicalJson(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonicalJson)
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value as RawObject)
        .filter(([, entry]) => entry !== undefined)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, entry]) => [key, canonicalJson(entry)])
    )
  }
  return value
}

export function stableStringify(value: unknown): string {
  return JSON.stringify(canonicalJson(value))
}

export function sha256(value: string): string {
  return createHash('sha256').update(value).digest('hex')
}

function sourceKeyParts(input: SourceKeyInput, includeChecksum: boolean) {
  return {
    database: input.database,
    zoneOwnerName: input.zoneOwnerName,
    zoneName: input.zoneName,
    recordType: input.recordType,
    recordName: input.recordName,
    ...(includeChecksum ? { checksum: input.checksum ?? '' } : {}),
  }
}

export function sourceRecordLogicalKey(input: SourceKeyInput): string {
  return sha256(stableStringify(sourceKeyParts(input, false)))
}

/**
 * The complete source fingerprint includes the checksum. The persisted
 * logical key omits it so a changed CloudKit record can be detected as a
 * conflict rather than imported as a second target row.
 */
export function sourceRecordKey(input: SourceKeyInput): string {
  return sha256(stableStringify(sourceKeyParts(input, true)))
}

function normalizeRecordType(value: unknown, path: string): CloudKitRecordType {
  const raw = requiredString(value, path).toLowerCase()
  const recordType = recordTypeAliases[raw]
  if (!recordType) {
    throw new CloudKitImportValidationError(
      'unsupported_record_type',
      `${path} ${raw} is not an importable CloudKit ledger record type`
    )
  }
  return recordType
}

function zoneDetails(value: unknown, path: string): { zoneName: string; zoneOwnerName: string } {
  if (typeof value === 'string') {
    return { zoneName: requiredString(value, path), zoneOwnerName: '__defaultOwner__' }
  }
  const zone = object(value, path)
  const nestedZoneValue = zone.zoneID ?? zone.zoneId
  const nestedZone = nestedZoneValue !== undefined && nestedZoneValue !== null && typeof nestedZoneValue === 'object'
    ? optionalObject(nestedZoneValue, `${path}.zoneID`)
    : null
  return {
    zoneName: requiredString(zone.name ?? zone.zoneName ?? nestedZone?.name ?? nestedZone?.zoneName, `${path}.name`),
    zoneOwnerName: optionalString(
      zone.ownerName ?? zone.zoneOwnerName ?? nestedZone?.ownerName ?? nestedZone?.zoneOwnerName,
      `${path}.ownerName`
    ) ?? '__defaultOwner__',
  }
}

function recordFields(raw: RawObject, path: string): JsonObject {
  if (raw.fields !== undefined) return jsonObject(raw.fields, `${path}.fields`)
  if (raw.payload !== undefined) {
    const payload = optionalObject(raw.payload, `${path}.payload`)
    if (payload?.fields !== undefined) return jsonObject(payload.fields, `${path}.payload.fields`)
    if (payload) return jsonObject(payload, `${path}.payload`)
  }
  if (raw.record !== undefined) {
    const record = object(raw.record, `${path}.record`)
    if (record.fields !== undefined) return jsonObject(record.fields, `${path}.record.fields`)
    return jsonObject(record, `${path}.record`)
  }
  throw new CloudKitImportValidationError('invalid_record', `${path}.fields is required`)
}

function recordId(fields: JsonObject, raw: RawObject, path: string): string {
  return requiredString(fields.id ?? raw.id ?? raw.recordName ?? raw.name, `${path}.id`)
}

function checksumForRecord(input: {
  database: string
  zoneName: string
  zoneOwnerName: string
  recordType: CloudKitRecordType
  recordName: string
  fields: JsonObject
  rawChecksum: unknown
  path: string
}): string {
  const supplied = optionalString(input.rawChecksum, `${input.path}.checksum`)
  return supplied ?? sha256(stableStringify({
    database: input.database,
    zoneName: input.zoneName,
    zoneOwnerName: input.zoneOwnerName,
    recordType: input.recordType,
    recordName: input.recordName,
    fields: input.fields,
  }))
}

function normalizeClaims(value: unknown): CloudKitMemberClaim[] {
  if (value === undefined || value === null) return []
  const claims: CloudKitMemberClaim[] = []
  if (Array.isArray(value)) {
    value.forEach((entry, index) => {
      const claim = object(entry, `claims[${index}]`)
      const personRecordName = requiredString(
        claim.personRecordName ?? claim.sourcePersonRecordName ?? claim.personId ?? claim.sourcePersonId ?? claim.recordName,
        `claims[${index}].personRecordName`
      )
      claims.push({
        personRecordName,
        cloudKitRecordName: optionalString(
          claim.cloudKitRecordName ?? claim.cloudkitRecordName ?? claim.cloudUserRecordName ?? claim.subject,
          `claims[${index}].cloudKitRecordName`
        ),
        accountId: optionalString(claim.accountId ?? claim.userId, `claims[${index}].accountId`),
      })
    })
  } else {
    const mapping = object(value, 'claims')
    for (const [personRecordName, rawClaim] of Object.entries(mapping)) {
      if (typeof rawClaim === 'string') {
        claims.push({ personRecordName: requiredString(personRecordName, 'claims key'), cloudKitRecordName: null, accountId: requiredString(rawClaim, `claims.${personRecordName}`) })
        continue
      }
      const claim = object(rawClaim, `claims.${personRecordName}`)
      claims.push({
        personRecordName: requiredString(personRecordName, 'claims key'),
        cloudKitRecordName: optionalString(
          claim.cloudKitRecordName ?? claim.cloudkitRecordName ?? claim.cloudUserRecordName ?? claim.subject,
          `claims.${personRecordName}.cloudKitRecordName`
        ),
        accountId: optionalString(claim.accountId ?? claim.userId, `claims.${personRecordName}.accountId`),
      })
    }
  }

  const byPerson = new Map<string, CloudKitMemberClaim>()
  for (const claim of claims) {
    const existing = byPerson.get(claim.personRecordName)
    if (
      existing &&
      (existing.cloudKitRecordName !== claim.cloudKitRecordName || existing.accountId !== claim.accountId)
    ) {
      throw new CloudKitImportValidationError(
        'invalid_envelope',
        `conflicting claims for ${claim.personRecordName}`
      )
    }
    byPerson.set(claim.personRecordName, claim)
  }
  return Array.from(byPerson.values()).sort((left, right) => left.personRecordName.localeCompare(right.personRecordName))
}

function ownerName(root: RawObject, source: RawObject | null): string {
  const rawOwner = root.owner ?? root.sourceOwner ?? source?.owner
  const owner = rawOwner !== null && typeof rawOwner === 'object'
    ? optionalObject(rawOwner, 'owner')
    : null
  const rawOwnership = root.ownership ?? source?.ownership
  const ownership = rawOwnership !== null && typeof rawOwnership === 'object'
    ? optionalObject(rawOwnership, 'ownership')
    : null
  return requiredString(
      root.ownerCloudKitRecordName ??
      root.sourceOwnerCloudKitRecordName ??
      (typeof root.sourceOwner === 'string' ? root.sourceOwner : undefined) ??
      (typeof source?.owner === 'string' ? source.owner : undefined) ??
      owner?.cloudKitRecordName ?? owner?.cloudkitRecordName ?? owner?.recordName ?? owner?.subject ??
      ownership?.ownerCloudKitRecordName ?? ownership?.cloudKitRecordName ?? ownership?.ownerRecordName ?? ownership?.recordName ??
      source?.ownerCloudKitRecordName ?? source?.ownerRecordName ??
      (source?.owner && typeof source.owner === 'object' ? (source.owner as RawObject).cloudKitRecordName : undefined) ??
      (source?.ownership && typeof source.ownership === 'object' ? (source.ownership as RawObject).ownerRecordName : undefined),
    'owner.cloudKitRecordName'
  )
}

function defaultCurrency(root: RawObject, source: RawObject | null): {
  code: string | null
  exponent: number | null
} {
  const value = root.defaultCurrency ?? root.currency ?? source?.defaultCurrency ?? source?.currency
  if (value === undefined || value === null) return { code: null, exponent: null }
  if (typeof value === 'string') {
    const code = normalizeCurrencyCode(requiredString(value, 'defaultCurrency'))
    const exponent = getCurrencyExponent(code)
    if (exponent === null) {
      throw new CloudKitImportValidationError('invalid_envelope', `unsupported default currency ${code}`)
    }
    return { code, exponent }
  }
  const currency = object(value, 'defaultCurrency')
  const code = normalizeCurrencyCode(requiredString(currency.currencyCode ?? currency.code, 'defaultCurrency.currencyCode'))
  const registryExponent = getCurrencyExponent(code)
  if (registryExponent === null) {
    throw new CloudKitImportValidationError('invalid_envelope', `unsupported default currency ${code}`)
  }
  const rawExponent = currency.currencyExponent ?? currency.exponent ?? registryExponent
  if (typeof rawExponent !== 'number' || !Number.isInteger(rawExponent) || rawExponent !== registryExponent) {
    throw new CloudKitImportValidationError('invalid_envelope', `defaultCurrency exponent does not match ${code}`)
  }
  return { code, exponent: rawExponent }
}

function flattenRecords(root: RawObject, source: RawObject | null): Array<{ raw: RawObject; defaults: RawObject }> {
  const records: Array<{ raw: RawObject; defaults: RawObject }> = []
  if (Array.isArray(root.records)) {
    for (const entry of root.records) records.push({ raw: object(entry, 'records[]'), defaults: root })
  }
  const zones = root.zones ?? source?.zones
  if (zones !== undefined) {
    if (!Array.isArray(zones)) throw new CloudKitImportValidationError('invalid_envelope', 'zones must be an array')
    zones.forEach((zoneValue, zoneIndex) => {
      const zone = object(zoneValue, `zones[${zoneIndex}]`)
      const zoneRecords = zone.records
      if (!Array.isArray(zoneRecords)) throw new CloudKitImportValidationError('invalid_envelope', `zones[${zoneIndex}].records must be an array`)
      for (const entry of zoneRecords) records.push({ raw: object(entry, `zones[${zoneIndex}].records[]`), defaults: zone })
    })
  }
  return records
}

export function normalizeCloudKitExport(input: unknown): NormalizedCloudKitExport {
  const root = object(input, 'export')
  const sourceObject = root.source !== null && typeof root.source === 'object'
    ? optionalObject(root.source, 'source')
    : null
  const sourceName = typeof root.source === 'string'
    ? root.source
    : sourceObject?.system ?? sourceObject?.name ?? sourceObject?.source
  if (typeof sourceName !== 'string' || sourceName.trim().toLowerCase() !== CLOUDKIT_IMPORT_SOURCE) {
    throw new CloudKitImportValidationError('invalid_envelope', 'source must be cloudkit')
  }

  const ownerCloudKitRecordName = ownerName(root, sourceObject)
  const currency = defaultCurrency(root, sourceObject)
  const claims = normalizeClaims(root.claims ?? root.memberClaims ?? sourceObject?.claims ?? sourceObject?.memberClaims)
  const rawRecords = flattenRecords(root, sourceObject)
  if (rawRecords.length === 0) {
    throw new CloudKitImportValidationError('invalid_envelope', 'records must contain at least one record')
  }

  const recordsByLogicalKey = new Map<string, CloudKitSourceRecord>()
  let duplicateRecordCount = 0
  for (const [index, entry] of rawRecords.entries()) {
    const raw = entry.raw
    const defaults = entry.defaults
    const database = requiredString(raw.database ?? raw.databaseScope ?? defaults.database ?? defaults.databaseScope ?? root.database ?? root.databaseScope ?? sourceObject?.database ?? sourceObject?.databaseScope, `records[${index}].database`)
    const zoneValue = raw.zone ?? raw.zoneID ?? raw.zoneId ?? raw.zoneName ?? defaults.zone ?? defaults.zoneID ?? defaults.zoneId ?? defaults.zoneName ?? root.zone ?? root.zoneName ?? sourceObject?.zone
    const zone = zoneDetails(zoneValue, `records[${index}].zone`)
    const zoneOwnerName = optionalString(
      raw.zoneOwnerName ?? raw.ownerName ?? defaults.zoneOwnerName ?? defaults.ownerName ?? zone.zoneOwnerName,
      `records[${index}].zoneOwnerName`
    ) ?? '__defaultOwner__'
    const recordType = normalizeRecordType(raw.recordType ?? raw.type, `records[${index}].recordType`)
    const recordName = requiredString(raw.recordName ?? raw.name ?? raw.recordId, `records[${index}].recordName`)
    const fields = recordFields(raw, `records[${index}]`)
    const checksum = checksumForRecord({
      database,
      zoneName: zone.zoneName,
      zoneOwnerName,
      recordType,
      recordName,
      fields,
      rawChecksum: raw.checksum ?? raw.payloadChecksum ?? raw.contentChecksum,
      path: `records[${index}]`,
    })
    const sourceRecord: CloudKitSourceRecord = {
      database,
      zoneName: zone.zoneName,
      zoneOwnerName,
      recordType,
      recordName,
      sourceId: recordId(fields, raw, `records[${index}]`),
      checksum,
      logicalKey: sourceRecordLogicalKey({ database, zoneName: zone.zoneName, zoneOwnerName, recordType, recordName }),
      fields,
    }
    const previous = recordsByLogicalKey.get(sourceRecord.logicalKey)
    if (previous) {
      if (previous.checksum !== sourceRecord.checksum) {
        throw new CloudKitImportValidationError(
          'duplicate_source_record_conflict',
          `CloudKit record ${recordName} has conflicting checksums`,
          { recordName, recordType, database, zoneName: zone.zoneName }
        )
      }
      duplicateRecordCount += 1
      continue
    }
    recordsByLogicalKey.set(sourceRecord.logicalKey, sourceRecord)
  }

  const records = Array.from(recordsByLogicalKey.values()).sort((left, right) =>
    sourceRecordKey(left).localeCompare(sourceRecordKey(right))
  )
  const suppliedSourceKey = root.sourceKey ?? root.migrationId ?? root.exportId ?? root.id ?? sourceObject?.sourceKey
  const sourceKey = suppliedSourceKey === undefined || suppliedSourceKey === null
    ? `cloudkit-${sha256(stableStringify({ ownerCloudKitRecordName, claims, records: records.map((record) => ({ ...record, fields: record.fields })) }))}`
    : requiredString(suppliedSourceKey, 'sourceKey')
  const suppliedChecksum = root.checksum ?? root.exportChecksum ?? sourceObject?.checksum
  const sourceChecksum = suppliedChecksum === undefined || suppliedChecksum === null
    ? sha256(stableStringify({
        source: CLOUDKIT_IMPORT_SOURCE,
        sourceKey,
        ownerCloudKitRecordName,
        currency,
        claims,
        records,
      }))
    : requiredString(suppliedChecksum, 'checksum')

  const suppliedDuplicateRecordCount = root.duplicateRecordCount
  if (suppliedDuplicateRecordCount !== undefined &&
      (typeof suppliedDuplicateRecordCount !== 'number' ||
        !Number.isInteger(suppliedDuplicateRecordCount) ||
        suppliedDuplicateRecordCount < duplicateRecordCount)) {
    throw new CloudKitImportValidationError(
      'invalid_envelope',
      'duplicateRecordCount must be a non-negative integer covering all normalized duplicates'
    )
  }

  return {
    source: CLOUDKIT_IMPORT_SOURCE,
    sourceKey,
    sourceChecksum,
    ownerCloudKitRecordName,
    defaultCurrencyCode: currency.code,
    defaultCurrencyExponent: currency.exponent,
    claims,
    records,
    duplicateRecordCount: suppliedDuplicateRecordCount === undefined
      ? duplicateRecordCount
      : suppliedDuplicateRecordCount,
  }
}

function canonicalMinorUnits(value: unknown, path: string): bigint {
  if (typeof value !== 'string' || !/^(0|-?[1-9]\d*)$/.test(value) || value === '-0') {
    throw new CloudKitImportValidationError('money_not_exact', `${path} must be a canonical signed-integer string`)
  }
  try {
    return BigInt(value)
  } catch {
    throw new CloudKitImportValidationError('money_not_exact', `${path} is outside the supported integer range`)
  }
}

function currencyContext(context: MoneyContext | undefined, path: string): {
  currencyCode: string
  currencyExponent: number
} {
  if (typeof context?.currencyCode !== 'string' || context.currencyCode.trim().length === 0) {
    throw new CloudKitImportValidationError('money_not_exact', `${path}.currencyCode is required`)
  }
  const currencyCode = normalizeCurrencyCode(context.currencyCode)
  const registryExponent = getCurrencyExponent(currencyCode)
  if (registryExponent === null) {
    throw new CloudKitImportValidationError('money_not_exact', `unsupported currency ${currencyCode}`, { path })
  }
  const exponent = context?.currencyExponent ?? registryExponent
  if (!Number.isInteger(exponent) || exponent < 0 || exponent !== registryExponent) {
    throw new CloudKitImportValidationError('money_not_exact', `${path}.currencyExponent does not match ${currencyCode}`)
  }
  return { currencyCode, currencyExponent: exponent }
}

export function parseExactMoney(value: unknown, context?: MoneyContext, path = 'money'): ExactMoney {
  if (typeof value === 'string') {
    const descriptor = currencyContext(context, path)
    const converted = parseDecimalToMinorUnits(value, descriptor.currencyCode)
    if ('code' in converted) {
      throw new CloudKitImportValidationError(
        'money_not_representable',
        `${path} is not representable in ${descriptor.currencyCode}`,
        { value }
      )
    }
    return {
      minorUnits: converted.minorUnits,
      currencyCode: descriptor.currencyCode,
      currencyExponent: descriptor.currencyExponent,
    }
  }

  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new CloudKitImportValidationError('money_not_exact', `${path} must be an exact money object or decimal string`)
  }
  const money = value as RawObject
  const descriptor = currencyContext({
    currencyCode: typeof money.currencyCode === 'string' ? money.currencyCode : context?.currencyCode,
    currencyExponent: typeof money.currencyExponent === 'number' ? money.currencyExponent : context?.currencyExponent,
  }, path)
  return {
    minorUnits: canonicalMinorUnits(money.minorUnits, `${path}.minorUnits`),
    currencyCode: descriptor.currencyCode,
    currencyExponent: descriptor.currencyExponent,
  }
}

export function moneyContextFromFields(fields: JsonObject, defaults: {
  currencyCode?: string | null
  currencyExponent?: number | null
} = {}): MoneyContext {
  const currencyCode = typeof fields.currencyCode === 'string'
    ? fields.currencyCode
    : typeof fields.currency === 'string'
      ? fields.currency
      : defaults.currencyCode
  const rawExponent = fields.currencyExponent ?? fields.exponent ?? defaults.currencyExponent
  return {
    currencyCode: currencyCode ?? null,
    currencyExponent: typeof rawExponent === 'number' ? rawExponent : null,
  }
}
