import { Prisma, type PrismaClient } from '@prisma/client'
import { prisma as defaultPrisma } from '../../prisma'
import { getCurrencyExponent, normalizeCurrencyCode } from '../../settlement/money/registry'
import {
  CLOUDKIT_IMPORT_SOURCE,
  CLOUDKIT_RECORD_TYPES,
  CloudKitImportNeedsRepairError,
  CloudKitImportValidationError,
  type CloudKitImportCounts,
  type CloudKitImportDb,
  type CloudKitImportLookup,
  type CloudKitImportRequest,
  type CloudKitImportResult,
  type CloudKitImportStatus,
  type CloudKitMemberClaim,
  type CloudKitMigrationMarker,
  type CloudKitSourceRecord,
  type ExactMoney,
  type JsonObject,
  type NormalizedCloudKitExport,
} from './types'
import {
  moneyContextFromFields,
  normalizeCloudKitExport,
  parseExactMoney,
  sha256,
  sourceRecordKey,
} from './normalize'

const IMPORTABLE_RECORD_RANK: Record<CloudKitSourceRecord['recordType'], number> = {
  [CLOUDKIT_RECORD_TYPES.PERSON]: 0,
  [CLOUDKIT_RECORD_TYPES.GROUP]: 1,
  [CLOUDKIT_RECORD_TYPES.EXPENSE]: 2,
  [CLOUDKIT_RECORD_TYPES.SPLIT]: 3,
  [CLOUDKIT_RECORD_TYPES.SETTLEMENT]: 4,
  [CLOUDKIT_RECORD_TYPES.ACTIVITY]: 5,
}

const METADATA_RECORD_TYPE = '__cloudkit_metadata__'
const METADATA_KEY_PREFIX = '__cloudkit_metadata__:'

type DbTransaction = Prisma.TransactionClient

function isPrismaClient(db: CloudKitImportDb): db is PrismaClient {
  return '$transaction' in db && typeof db.$transaction === 'function'
}

function withTransaction<T>(
  db: CloudKitImportDb,
  callback: (tx: DbTransaction) => Promise<T>
): Promise<T> {
  return isPrismaClient(db) ? db.$transaction(callback) : callback(db)
}

type ResolvedPerson = {
  source: CloudKitSourceRecord
  cloudKitRecordName: string
  accountId: string
  displayName: string
}

type SemanticState = {
  peopleByRef: Map<string, ResolvedPerson>
  groupsByRef: Map<string, CloudKitSourceRecord>
  expensesByRef: Map<string, CloudKitSourceRecord>
  settlementsByRef: Map<string, CloudKitSourceRecord>
  groupCurrencyByLogicalKey: Map<string, string>
  groupOwnerByLogicalKey: Map<string, ResolvedPerson>
  splitRowsByExpenseRef: Map<string, Array<{ source: CloudKitSourceRecord; fields: JsonObject }>>
  inlineSplitsByExpenseRef: Map<string, Array<{ sourceId: string; fields: JsonObject }>>
}

type PreparedImport = {
  importId: string
  status: CloudKitImportStatus
  sourceChecksum: string
  alreadyCompleted: boolean
  needsRepairReason: string | null
}

type ImportRow = {
  id: string
  accountId: string
  sourceSystem: string
  sourceKey: string
  state: string
  sourceChecksum: string | null
  failureReason: string | null
  startedAt: Date | null
  completedAt: Date | null
}

function isUniqueConstraint(error: unknown): boolean {
  return error instanceof Prisma.PrismaClientKnownRequestError && error.code === 'P2002'
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function stringField(fields: JsonObject, names: string[], path: string): string | null {
  for (const name of names) {
    const value = fields[name]
    if (typeof value === 'string' && value.trim().length > 0) return value.trim()
  }
  return null
}

function requiredField(fields: JsonObject, names: string[], path: string): string {
  const value = stringField(fields, names, path)
  if (!value) throw new CloudKitImportNeedsRepairError(`${path} is required`, 'invalid_record')
  return value
}

function booleanField(fields: JsonObject, names: string[], fallback: boolean): boolean {
  for (const name of names) {
    const value = fields[name]
    if (typeof value === 'boolean') return value
  }
  return fallback
}

function stringArrayField(fields: JsonObject, names: string[], path: string): string[] {
  for (const name of names) {
    const value = fields[name]
    if (value === undefined || value === null) continue
    if (!Array.isArray(value) || value.some((entry) => typeof entry !== 'string' || entry.trim().length === 0)) {
      throw new CloudKitImportNeedsRepairError(`${path}.${name} must be a non-empty-string array`, 'invalid_record')
    }
    return value.map((entry) => String(entry).trim())
  }
  return []
}

function objectArrayField(fields: JsonObject, names: string[], path: string): JsonObject[] {
  for (const name of names) {
    const value = fields[name]
    if (value === undefined || value === null) continue
    if (!Array.isArray(value) || value.some((entry) => !isRecord(entry))) {
      throw new CloudKitImportNeedsRepairError(`${path}.${name} must be an object array`, 'invalid_record')
    }
    return value as JsonObject[]
  }
  return []
}

function mapByReference(records: CloudKitSourceRecord[], label: string): Map<string, CloudKitSourceRecord> {
  const map = new Map<string, CloudKitSourceRecord>()
  for (const source of records) {
    const references = new Set([source.sourceId, source.recordName])
    for (const reference of references) {
      const previous = map.get(reference)
      if (previous && previous.logicalKey !== source.logicalKey) {
        throw new CloudKitImportNeedsRepairError(`ambiguous ${label} reference ${reference}`, 'dependency_missing')
      }
      map.set(reference, source)
    }
  }
  return map
}

function personClaim(
  source: CloudKitSourceRecord,
  claims: CloudKitMemberClaim[]
): CloudKitMemberClaim | null {
  return claims.find((claim) => claim.personRecordName === source.sourceId || claim.personRecordName === source.recordName) ?? null
}

function cloudUserFromPerson(source: CloudKitSourceRecord): string | null {
  return stringField(source.fields, ['cloudUser', 'cloudKitRecordName', 'cloudkitRecordName', 'cloudUserRecordName'], `${source.recordType}.${source.sourceId}`)
}

function sourceGroupReference(fields: JsonObject, path: string): string {
  return requiredField(fields, ['groupID', 'groupId', 'group'], path)
}

function sourceExpenseReference(fields: JsonObject, path: string): string {
  return requiredField(fields, ['expenseID', 'expenseId', 'expense'], path)
}

function sourcePersonReference(fields: JsonObject, path: string): string {
  return requiredField(fields, ['personID', 'personId', 'userId', 'memberId', 'user'], path)
}

function exactMoneyField(
  fields: JsonObject,
  defaults: { currencyCode?: string | null; currencyExponent?: number | null },
  path: string
): ExactMoney {
  const value = fields.amount ?? fields.money ?? fields.computedAmount ?? fields.amountMinorUnits
  if (value === undefined) {
    throw new CloudKitImportNeedsRepairError(`${path}.amount is required`, 'money_not_exact')
  }
  const normalizedValue = fields.amountMinorUnits !== undefined && fields.amount === undefined && fields.money === undefined && fields.computedAmount === undefined
    ? {
        minorUnits: fields.amountMinorUnits,
        currencyCode: fields.currencyCode ?? fields.currency ?? defaults.currencyCode,
        currencyExponent: fields.currencyExponent ?? defaults.currencyExponent,
      }
    : value
  try {
    return parseExactMoney(normalizedValue, moneyContextFromFields(fields, defaults), path)
  } catch (error) {
    if (error instanceof CloudKitImportValidationError) {
      throw new CloudKitImportNeedsRepairError(error.message, error.code, error.details)
    }
    throw error
  }
}

function sourceDate(fields: JsonObject, names: string[], path: string, fallback: Date): Date {
  const value = fields[names[0]] ?? names.slice(1).map((name) => fields[name]).find((entry) => entry !== undefined)
  if (value === undefined || value === null) return fallback
  if (typeof value !== 'string' || Number.isNaN(new Date(value).getTime())) {
    throw new CloudKitImportNeedsRepairError(`${path} must be an ISO date`, 'invalid_record')
  }
  return new Date(value)
}

function targetId(prefix: string, value: string): string {
  return `cloudkit-${prefix}-${sha256(value).slice(0, 32)}`
}

function sourceTargetId(prefix: string, source: CloudKitSourceRecord): string {
  return targetId(prefix, sourceRecordKey(source))
}

function referenceKey(source: CloudKitSourceRecord): string {
  return source.logicalKey
}

function resolveReference(map: Map<string, CloudKitSourceRecord>, reference: string, path: string): CloudKitSourceRecord {
  const resolved = map.get(reference)
  if (!resolved) throw new CloudKitImportNeedsRepairError(`${path} references an unknown CloudKit record ${reference}`, 'dependency_missing')
  return resolved
}

function currencyForGroup(
  group: CloudKitSourceRecord,
  expenses: CloudKitSourceRecord[],
  normalized: NormalizedCloudKitExport
): string {
  const groupCurrency = stringField(group.fields, ['currencyCode', 'currency'], `group.${group.sourceId}`)
  if (groupCurrency) {
    const code = normalizeCurrencyCode(groupCurrency)
    if (getCurrencyExponent(code) === null) throw new CloudKitImportNeedsRepairError(`unsupported group currency ${code}`, 'money_not_exact')
    return code
  }
  if (normalized.defaultCurrencyCode) return normalized.defaultCurrencyCode
  for (const expense of expenses) {
    const value = expense.fields.amount ?? expense.fields.money
    if (isRecord(value) && typeof value.currencyCode === 'string') {
      const code = normalizeCurrencyCode(value.currencyCode)
      if (getCurrencyExponent(code) !== null) return code
    }
  }
  throw new CloudKitImportNeedsRepairError(`group ${group.sourceId} has no currency`, 'money_not_exact')
}

function splitMode(fields: JsonObject): 'EQUAL' | 'EXACT' | 'PERCENTAGE' | 'SHARES' {
  const raw = stringField(fields, ['splitType', 'splitMode', 'mode', 'modeRaw'], 'split.mode')?.toLowerCase() ?? 'equal'
  if (raw === 'equal') return 'EQUAL'
  if (raw === 'exact') return 'EXACT'
  if (raw === 'percent' || raw === 'percentage') return 'PERCENTAGE'
  if (raw === 'shares') return 'SHARES'
  throw new CloudKitImportNeedsRepairError(`unsupported split mode ${raw}`, 'invalid_record')
}

function numericMetadata(value: unknown, path: string): number | null {
  if (value === undefined || value === null) return null
  const result = typeof value === 'number' ? value : typeof value === 'string' && /^-?\d+(\.\d+)?$/.test(value.trim()) ? Number(value) : NaN
  if (!Number.isFinite(result)) throw new CloudKitImportNeedsRepairError(`${path} must be numeric metadata`, 'invalid_record')
  return result
}

function integerMetadata(value: unknown, path: string): number | null {
  const result = numericMetadata(value, path)
  if (result === null) return null
  if (!Number.isInteger(result)) throw new CloudKitImportNeedsRepairError(`${path} must be an integer`, 'invalid_record')
  return result
}

function inlineSplitFields(split: JsonObject, path: string): JsonObject {
  const person = stringField(split, ['personID', 'personId', 'userId', 'memberId', 'user'], path)
  if (!person) throw new CloudKitImportNeedsRepairError(`${path}.personID is required`, 'dependency_missing')
  return split
}

async function resolvePeople(
  tx: DbTransaction,
  accountId: string,
  normalized: NormalizedCloudKitExport,
  people: CloudKitSourceRecord[]
): Promise<Map<string, ResolvedPerson>> {
  const result = new Map<string, ResolvedPerson>()
  for (const source of people) {
    const claim = personClaim(source, normalized.claims)
    if (!claim) {
      throw new CloudKitImportNeedsRepairError(`person ${source.sourceId} has no member claim`, 'missing_member_claim', { personRecordName: source.recordName })
    }
    const sourceCloudUser = cloudUserFromPerson(source)
    const cloudKitRecordName = claim.cloudKitRecordName ?? sourceCloudUser
    if (!cloudKitRecordName) {
      throw new CloudKitImportNeedsRepairError(`person ${source.sourceId} has no CloudKit identity`, 'identity_not_claimed')
    }
    if (claim.cloudKitRecordName && sourceCloudUser && claim.cloudKitRecordName !== sourceCloudUser) {
      throw new CloudKitImportNeedsRepairError(`person ${source.sourceId} claim does not match its CloudKit identity`, 'identity_not_claimed')
    }
    const external = await tx.externalIdentity.findUnique({
      where: { provider_subject: { provider: 'cloudkit', subject: cloudKitRecordName } },
      select: { accountId: true },
    })
    if (!external) {
      throw new CloudKitImportNeedsRepairError(`CloudKit identity ${cloudKitRecordName} is not linked to an API account`, 'identity_not_claimed', { cloudKitRecordName })
    }
    if (claim.accountId && claim.accountId !== external.accountId) {
      throw new CloudKitImportNeedsRepairError(`member claim for ${source.sourceId} points to a different account`, 'identity_not_claimed')
    }
    const resolvedAccountId = external.accountId
    const user = await tx.user.findUnique({ where: { id: resolvedAccountId }, select: { id: true, name: true, preferredName: true, email: true } })
    if (!user) throw new CloudKitImportNeedsRepairError(`claimed account ${resolvedAccountId} does not exist`, 'identity_not_claimed')
    const resolved: ResolvedPerson = {
      source,
      cloudKitRecordName,
      accountId: resolvedAccountId,
      displayName: stringField(source.fields, ['name', 'displayName'], `person.${source.sourceId}`) ?? user.name ?? user.preferredName ?? user.email,
    }
    for (const reference of [source.sourceId, source.recordName]) result.set(reference, resolved)
  }

  const owner = Array.from(result.values()).find((person) => person.cloudKitRecordName === normalized.ownerCloudKitRecordName)
  if (!owner || owner.accountId !== accountId) {
    throw new CloudKitImportNeedsRepairError('the authenticated account does not own the CloudKit export', 'missing_source_owner', { ownerCloudKitRecordName: normalized.ownerCloudKitRecordName })
  }
  return result
}

function sourceRecordForPerson(peopleByRef: Map<string, ResolvedPerson>, reference: string, path: string): ResolvedPerson {
  const person = peopleByRef.get(reference)
  if (!person) throw new CloudKitImportNeedsRepairError(`${path} references an unclaimed person ${reference}`, 'missing_member_claim')
  return person
}

function groupMemberReferences(group: CloudKitSourceRecord): string[] {
  return stringArrayField(group.fields, ['memberIDs', 'memberIds', 'members'], `group.${group.sourceId}.memberIDs`)
}

function splitMoney(
  fields: JsonObject,
  expenseMoney: ExactMoney,
  path: string
): ExactMoney {
  const value = fields.amount ?? fields.computedAmount ?? fields.computedAmountString ?? fields.money ?? fields.amountMinorUnits
  const normalizedValue = fields.amountMinorUnits !== undefined && fields.amount === undefined && fields.computedAmount === undefined && fields.money === undefined
    ? { minorUnits: fields.amountMinorUnits, currencyCode: expenseMoney.currencyCode, currencyExponent: expenseMoney.currencyExponent }
    : value
  if (normalizedValue === undefined) throw new CloudKitImportNeedsRepairError(`${path}.amount is required`, 'money_not_exact')
  const money = parseExactMoney(normalizedValue, {
    currencyCode: expenseMoney.currencyCode,
    currencyExponent: expenseMoney.currencyExponent,
  }, path)
  if (money.currencyCode !== expenseMoney.currencyCode || money.currencyExponent !== expenseMoney.currencyExponent) {
    throw new CloudKitImportNeedsRepairError(`${path} currency differs from its expense`, 'money_not_exact')
  }
  return money
}

function validateSplitSet(
  expense: CloudKitSourceRecord,
  expenseMoney: ExactMoney,
  splitFields: Array<{ sourceId: string; fields: JsonObject }>,
  peopleByRef: Map<string, ResolvedPerson>
) {
  if (splitFields.length === 0) throw new CloudKitImportNeedsRepairError(`expense ${expense.sourceId} has no splits`, 'dependency_missing')
  const seenPeople = new Set<string>()
  let total = 0n
  for (const split of splitFields) {
    const personRef = sourcePersonReference(split.fields, `split.${split.sourceId}.personID`)
    const person = sourceRecordForPerson(peopleByRef, personRef, `split.${split.sourceId}`)
    if (seenPeople.has(person.accountId)) throw new CloudKitImportNeedsRepairError(`expense ${expense.sourceId} contains duplicate splits for one member`, 'invalid_record')
    seenPeople.add(person.accountId)
    const money = splitMoney(split.fields, expenseMoney, `split.${split.sourceId}`)
    total += money.minorUnits
    const mode = splitMode(split.fields)
    if (mode === 'PERCENTAGE') numericMetadata(split.fields.percentage ?? split.fields.value ?? split.fields.valueString, `split.${split.sourceId}.percentage`)
    if (mode === 'SHARES') integerMetadata(split.fields.shares ?? split.fields.value ?? split.fields.valueString, `split.${split.sourceId}.shares`)
  }
  if (total !== expenseMoney.minorUnits) {
    throw new CloudKitImportNeedsRepairError(`expense ${expense.sourceId} splits do not equal the expense amount`, 'money_not_exact', {
      expectedMinorUnits: expenseMoney.minorUnits.toString(),
      actualMinorUnits: total.toString(),
    })
  }
}

async function validateAndResolve(
  tx: DbTransaction,
  accountId: string,
  normalized: NormalizedCloudKitExport
): Promise<SemanticState> {
  const people = normalized.records.filter((record) => record.recordType === CLOUDKIT_RECORD_TYPES.PERSON)
  const groups = normalized.records.filter((record) => record.recordType === CLOUDKIT_RECORD_TYPES.GROUP)
  const expenses = normalized.records.filter((record) => record.recordType === CLOUDKIT_RECORD_TYPES.EXPENSE)
  const splitRecords = normalized.records.filter((record) => record.recordType === CLOUDKIT_RECORD_TYPES.SPLIT)
  const settlements = normalized.records.filter((record) => record.recordType === CLOUDKIT_RECORD_TYPES.SETTLEMENT)
  const peopleByRef = await resolvePeople(tx, accountId, normalized, people)
  const groupsByRef = mapByReference(groups, 'group')
  const expensesByRef = mapByReference(expenses, 'expense')
  const settlementsByRef = mapByReference(settlements, 'settlement')
  const groupCurrencyByLogicalKey = new Map<string, string>()
  const groupOwnerByLogicalKey = new Map<string, ResolvedPerson>()
  const splitRowsByExpenseRef = new Map<string, Array<{ source: CloudKitSourceRecord; fields: JsonObject }>>()
  const inlineSplitsByExpenseRef = new Map<string, Array<{ sourceId: string; fields: JsonObject }>>()

  for (const group of groups) {
    const members = groupMemberReferences(group)
    if (members.length === 0) throw new CloudKitImportNeedsRepairError(`group ${group.sourceId} has no members`, 'dependency_missing')
    const owner = Array.from(peopleByRef.values()).find((person) => person.accountId === accountId && (members.includes(person.source.sourceId) || members.includes(person.source.recordName)))
    if (!owner) throw new CloudKitImportNeedsRepairError(`group ${group.sourceId} does not claim the source owner`, 'missing_source_owner')
    groupOwnerByLogicalKey.set(referenceKey(group), owner)
    for (const member of members) sourceRecordForPerson(peopleByRef, member, `group.${group.sourceId}.memberIDs`)
    if (group.zoneOwnerName !== '__defaultOwner__' && group.zoneOwnerName !== normalized.ownerCloudKitRecordName) {
      throw new CloudKitImportNeedsRepairError(`group ${group.sourceId} is not owned by the export owner`, 'missing_source_owner')
    }
    const groupExpenses = expenses.filter((expense) => {
      const reference = stringField(expense.fields, ['groupID', 'groupId', 'group'], `expense.${expense.sourceId}.groupID`)
      return reference !== null && groupsByRef.get(reference)?.logicalKey === group.logicalKey
    })
    groupCurrencyByLogicalKey.set(referenceKey(group), currencyForGroup(group, groupExpenses, normalized))
  }

  const inlineSplitRows = new Map<string, Array<{ sourceId: string; fields: JsonObject }>>()
  for (const expense of expenses) {
    const group = resolveReference(groupsByRef, sourceGroupReference(expense.fields, `expense.${expense.sourceId}.groupID`), `expense.${expense.sourceId}.groupID`)
    const groupCurrency = groupCurrencyByLogicalKey.get(referenceKey(group))
    const expenseMoney = exactMoneyField(expense.fields, {
      currencyCode: groupCurrency,
      currencyExponent: groupCurrency ? getCurrencyExponent(groupCurrency) : null,
    }, `expense.${expense.sourceId}`)
    const members = groupMemberReferences(group)
    const payer = sourceRecordForPerson(peopleByRef, requiredField(expense.fields, ['paidByID', 'paidById', 'paidBy', 'payerId'], `expense.${expense.sourceId}.paidByID`), `expense.${expense.sourceId}.paidByID`)
    if (!members.some((reference) => peopleByRef.get(reference)?.accountId === payer.accountId)) {
      throw new CloudKitImportNeedsRepairError(`expense ${expense.sourceId} payer is not a group member`, 'dependency_missing')
    }
    const inline = objectArrayField(expense.fields, ['splits'], `expense.${expense.sourceId}`)
      .map((fields, index) => ({ sourceId: stringField(fields, ['id', 'splitId'], `expense.${expense.sourceId}.splits[${index}]`) ?? `${expense.sourceId}:inline:${index}`, fields: inlineSplitFields(fields, `expense.${expense.sourceId}.splits[${index}]`) }))
    inlineSplitRows.set(referenceKey(expense), inline)
    const separate = splitRecords.filter((split) => {
      const reference = stringField(split.fields, ['expenseID', 'expenseId', 'expense'], `split.${split.sourceId}.expenseID`)
      return reference !== null && expensesByRef.get(reference)?.logicalKey === expense.logicalKey
    }).map((split) => ({ source: split, fields: split.fields }))
    splitRowsByExpenseRef.set(referenceKey(expense), separate)
    const allSplits = [
      ...inline.map((split) => ({ sourceId: split.sourceId, fields: split.fields })),
      ...separate.map((split) => ({ sourceId: split.source.sourceId, fields: split.fields })),
    ]
    validateSplitSet(expense, expenseMoney, allSplits, peopleByRef)
  }

  for (const split of splitRecords) {
    const expense = resolveReference(expensesByRef, sourceExpenseReference(split.fields, `split.${split.sourceId}.expenseID`), `split.${split.sourceId}.expenseID`)
    const group = resolveReference(groupsByRef, sourceGroupReference(expense.fields, `expense.${expense.sourceId}.groupID`), `expense.${expense.sourceId}.groupID`)
    sourceRecordForPerson(peopleByRef, sourcePersonReference(split.fields, `split.${split.sourceId}.personID`), `split.${split.sourceId}.personID`)
    if (!groupCurrencyByLogicalKey.has(referenceKey(group))) throw new CloudKitImportNeedsRepairError(`split ${split.sourceId} has no group currency`, 'money_not_exact')
  }

  for (const settlement of settlements) {
    const group = resolveReference(groupsByRef, sourceGroupReference(settlement.fields, `settlement.${settlement.sourceId}.groupID`), `settlement.${settlement.sourceId}.groupID`)
    const from = sourceRecordForPerson(peopleByRef, requiredField(settlement.fields, ['fromID', 'fromId', 'senderId', 'from'], `settlement.${settlement.sourceId}.fromID`), `settlement.${settlement.sourceId}.fromID`)
    const to = sourceRecordForPerson(peopleByRef, requiredField(settlement.fields, ['toID', 'toId', 'receiverId', 'to'], `settlement.${settlement.sourceId}.toID`), `settlement.${settlement.sourceId}.toID`)
    const members = groupMemberReferences(group)
    if (!members.some((reference) => peopleByRef.get(reference)?.accountId === from.accountId) || !members.some((reference) => peopleByRef.get(reference)?.accountId === to.accountId)) {
      throw new CloudKitImportNeedsRepairError(`settlement ${settlement.sourceId} references a non-member`, 'dependency_missing')
    }
    exactMoneyField(settlement.fields, {
      currencyCode: groupCurrencyByLogicalKey.get(referenceKey(group)),
      currencyExponent: getCurrencyExponent(groupCurrencyByLogicalKey.get(referenceKey(group)) ?? ''),
    }, `settlement.${settlement.sourceId}`)
  }

  for (const activity of normalized.records.filter((record) => record.recordType === CLOUDKIT_RECORD_TYPES.ACTIVITY)) {
    const groupReference = stringField(activity.fields, ['groupID', 'groupId', 'group'], `activity.${activity.sourceId}.groupID`)
    if (groupReference) resolveReference(groupsByRef, groupReference, `activity.${activity.sourceId}.groupID`)
    const actorReference = stringField(activity.fields, ['actorID', 'actorId', 'actor'], `activity.${activity.sourceId}.actorID`)
    if (actorReference) sourceRecordForPerson(peopleByRef, actorReference, `activity.${activity.sourceId}.actorID`)
  }

  return {
    peopleByRef,
    groupsByRef,
    expensesByRef,
    settlementsByRef,
    groupCurrencyByLogicalKey,
    groupOwnerByLogicalKey,
    splitRowsByExpenseRef,
    inlineSplitsByExpenseRef: inlineSplitRows,
  }
}

function physicalStatus(state: string): CloudKitImportStatus {
  if (state === 'COMPLETED') return 'completed'
  if (state === 'RUNNING') return 'running'
  if (state === 'FAILED') return 'needs-repair'
  return 'pending'
}

function importIdFor(accountId: string, sourceKey: string): string {
  return targetId('import', `${accountId}:${sourceKey}`)
}

function metadataKey(sourceKey: string): string {
  return `${METADATA_KEY_PREFIX}${sha256(sourceKey).slice(0, 40)}`
}

function jsonInput(value: unknown): Prisma.InputJsonValue {
  return value as Prisma.InputJsonValue
}

function storedEnvelope(normalized: NormalizedCloudKitExport): JsonObject {
  return {
    source: normalized.source,
    sourceKey: normalized.sourceKey,
    checksum: normalized.sourceChecksum,
    owner: { cloudKitRecordName: normalized.ownerCloudKitRecordName },
    defaultCurrency: normalized.defaultCurrencyCode
      ? {
          currencyCode: normalized.defaultCurrencyCode,
          currencyExponent: normalized.defaultCurrencyExponent,
        }
      : null,
    claims: normalized.claims,
    duplicateRecordCount: normalized.duplicateRecordCount,
    records: normalized.records.map((record) => ({
      database: record.database,
      zone: { name: record.zoneName, ownerName: record.zoneOwnerName },
      recordType: record.recordType,
      recordName: record.recordName,
      checksum: record.checksum,
      fields: record.fields,
    })),
  }
}

function rowSelect() {
  return {
    id: true,
    accountId: true,
    sourceSystem: true,
    sourceKey: true,
    state: true,
    sourceChecksum: true,
    failureReason: true,
    startedAt: true,
    completedAt: true,
  } as const
}

async function findImport(tx: DbTransaction, accountId: string, sourceKey: string): Promise<ImportRow | null> {
  return tx.ledgerImport.findUnique({
    where: {
      accountId_sourceSystem_sourceKey: {
        accountId,
        sourceSystem: CLOUDKIT_IMPORT_SOURCE,
        sourceKey,
      },
    },
    select: rowSelect(),
  }) as Promise<ImportRow | null>
}

async function createOrFindImport(tx: DbTransaction, normalized: NormalizedCloudKitExport, accountId: string, now: Date): Promise<ImportRow> {
  const existing = await findImport(tx, accountId, normalized.sourceKey)
  if (existing) return existing
  const completedImport = await tx.ledgerImport.findFirst({
    where: { accountId, sourceSystem: CLOUDKIT_IMPORT_SOURCE, state: 'COMPLETED' },
    select: { id: true },
  })
  if (completedImport) {
    throw new CloudKitImportValidationError(
      'completed_import_frozen',
      'A completed CloudKit import is frozen against later source writes',
      { importId: completedImport.id, sourceKey: normalized.sourceKey }
    )
  }
  const id = importIdFor(accountId, normalized.sourceKey)
  try {
    return (await tx.ledgerImport.create({
      data: {
        id,
        accountId,
        sourceSystem: CLOUDKIT_IMPORT_SOURCE,
        sourceKey: normalized.sourceKey,
        sourceChecksum: normalized.sourceChecksum,
        state: 'PENDING',
        createdAt: now,
        updatedAt: now,
      },
      select: rowSelect(),
    })) as ImportRow
  } catch (error) {
    if (!isUniqueConstraint(error)) throw error
    const raced = await findImport(tx, accountId, normalized.sourceKey)
    if (!raced) throw error
    return raced
  }
}

async function ensureMetadataRow(
  tx: DbTransaction,
  importRow: ImportRow,
  normalized: NormalizedCloudKitExport,
  now: Date
): Promise<void> {
  const key = metadataKey(normalized.sourceKey)
  const existing = await tx.ledgerImportRecord.findUnique({
    where: {
      accountId_sourceSystem_sourceRecordKey: {
        accountId: importRow.accountId,
        sourceSystem: CLOUDKIT_IMPORT_SOURCE,
        sourceRecordKey: key,
      },
    },
    select: { id: true, payloadChecksum: true, importId: true },
  })
  if (existing) {
    if (existing.importId !== importRow.id || existing.payloadChecksum !== normalized.sourceChecksum) {
      throw new CloudKitImportNeedsRepairError('metadata already belongs to a different CloudKit import', 'source_checksum_conflict')
    }
    return
  }
  try {
    await tx.ledgerImportRecord.create({
      data: {
        id: targetId('metadata', `${importRow.id}:${key}`),
        accountId: importRow.accountId,
        importId: importRow.id,
        sourceSystem: CLOUDKIT_IMPORT_SOURCE,
        sourceRecordKey: key,
        sourceRecordType: METADATA_RECORD_TYPE,
        payload: jsonInput(storedEnvelope(normalized)),
        payloadChecksum: normalized.sourceChecksum,
        state: 'SKIPPED',
        createdAt: now,
        updatedAt: now,
      },
    })
  } catch (error) {
    if (!isUniqueConstraint(error)) throw error
    const raced = await tx.ledgerImportRecord.findUnique({
      where: {
        accountId_sourceSystem_sourceRecordKey: {
          accountId: importRow.accountId,
          sourceSystem: CLOUDKIT_IMPORT_SOURCE,
          sourceRecordKey: key,
        },
      },
      select: { importId: true, payloadChecksum: true },
    })
    if (!raced || raced.importId !== importRow.id || raced.payloadChecksum !== normalized.sourceChecksum) {
      throw new CloudKitImportNeedsRepairError('metadata race produced a conflicting CloudKit import', 'source_checksum_conflict')
    }
  }
}

async function ensureRecordRows(
  tx: DbTransaction,
  importRow: ImportRow,
  normalized: NormalizedCloudKitExport,
  now: Date
): Promise<void> {
  for (const source of normalized.records) {
    const sourceRecordKey = source.logicalKey
    const existing = await tx.ledgerImportRecord.findUnique({
      where: {
        accountId_sourceSystem_sourceRecordKey: {
          accountId: importRow.accountId,
          sourceSystem: CLOUDKIT_IMPORT_SOURCE,
          sourceRecordKey,
        },
      },
      select: { id: true, importId: true, payloadChecksum: true, state: true },
    })
    if (existing) {
      if (existing.payloadChecksum !== source.checksum) {
        throw new CloudKitImportNeedsRepairError(`CloudKit record ${source.recordName} changed after it was recorded`, 'source_checksum_conflict', { recordName: source.recordName })
      }
      if (existing.importId === importRow.id && existing.state !== 'IMPORTED') {
        await tx.ledgerImportRecord.update({
          where: { id: existing.id },
          data: { payload: jsonInput(source.fields), state: 'PENDING', quarantineReason: null, updatedAt: now },
        })
      }
      continue
    }
    try {
      await tx.ledgerImportRecord.create({
        data: {
          id: targetId('record', `${importRow.id}:${source.logicalKey}`),
          accountId: importRow.accountId,
          importId: importRow.id,
          sourceSystem: CLOUDKIT_IMPORT_SOURCE,
          sourceRecordKey,
          sourceRecordType: source.recordType,
          payload: jsonInput(source.fields),
          payloadChecksum: source.checksum,
          state: 'PENDING',
          createdAt: now,
          updatedAt: now,
        },
      })
    } catch (error) {
      if (!isUniqueConstraint(error)) throw error
      const raced = await tx.ledgerImportRecord.findUnique({
        where: {
          accountId_sourceSystem_sourceRecordKey: {
            accountId: importRow.accountId,
            sourceSystem: CLOUDKIT_IMPORT_SOURCE,
            sourceRecordKey,
          },
        },
        select: { payloadChecksum: true },
      })
      if (!raced || raced.payloadChecksum !== source.checksum) {
        throw new CloudKitImportNeedsRepairError(`CloudKit record ${source.recordName} raced with a different checksum`, 'source_checksum_conflict')
      }
    }
  }
}

async function prepareImport(
  rootDb: CloudKitImportDb,
  accountId: string,
  normalized: NormalizedCloudKitExport,
  now: Date
): Promise<PreparedImport> {
  return withTransaction(rootDb, async (tx) => {
    const importRow = await createOrFindImport(tx, normalized, accountId, now)
    if (importRow.sourceChecksum && importRow.sourceChecksum !== normalized.sourceChecksum) {
      if (importRow.state === 'COMPLETED') {
        throw new CloudKitImportValidationError(
          'completed_import_frozen',
          'A completed CloudKit import is frozen against later source writes',
          { importId: importRow.id, sourceKey: normalized.sourceKey }
        )
      }
      const reason = 'The CloudKit export checksum changed while the import was incomplete.'
      await tx.ledgerImport.update({
        where: { id: importRow.id },
        data: { state: 'FAILED', failureReason: reason, completedAt: null },
      })
      return {
        importId: importRow.id,
        status: 'needs-repair',
        sourceChecksum: normalized.sourceChecksum,
        alreadyCompleted: false,
        needsRepairReason: reason,
      }
    }
    if (importRow.state === 'COMPLETED') {
      return {
        importId: importRow.id,
        status: 'completed',
        sourceChecksum: importRow.sourceChecksum ?? normalized.sourceChecksum,
        alreadyCompleted: true,
        needsRepairReason: null,
      }
    }

    try {
      await validateAndResolve(tx, accountId, normalized)
      await ensureMetadataRow(tx, importRow, normalized, now)
      await ensureRecordRows(tx, importRow, normalized, now)
    } catch (error) {
      if (!(error instanceof CloudKitImportNeedsRepairError) && !(error instanceof CloudKitImportValidationError)) throw error
      const reason = error.message
      await tx.ledgerImport.update({
        where: { id: importRow.id },
        data: { state: 'FAILED', failureReason: reason, sourceChecksum: normalized.sourceChecksum, completedAt: null },
      })
      return {
        importId: importRow.id,
        status: 'needs-repair',
        sourceChecksum: normalized.sourceChecksum,
        alreadyCompleted: false,
        needsRepairReason: reason,
      }
    }

    const startedAt = importRow.startedAt ?? now
    await tx.ledgerImport.update({
      where: { id: importRow.id },
      data: {
        state: 'RUNNING',
        sourceChecksum: normalized.sourceChecksum,
        failureReason: null,
        startedAt,
        completedAt: null,
      },
    })
    return {
      importId: importRow.id,
      status: 'running',
      sourceChecksum: normalized.sourceChecksum,
      alreadyCompleted: false,
      needsRepairReason: null,
    }
  })
}

function legacyAmount(money: ExactMoney): number {
  const value = Number(money.minorUnits) / 10 ** money.currencyExponent
  if (!Number.isFinite(value)) {
    throw new CloudKitImportNeedsRepairError('exact money cannot be represented by the legacy database column', 'money_not_exact')
  }
  return value
}

function groupCategory(fields: JsonObject): 'HOME' | 'TRIP' | 'COUPLE' | 'WORK' | 'OTHER' {
  const value = stringField(fields, ['category', 'icon'], 'group.category')?.toLowerCase()
  if (value === 'home' || value === 'house') return 'HOME'
  if (value === 'trip' || value === 'travel' || value === 'plane') return 'TRIP'
  if (value === 'couple') return 'COUPLE'
  if (value === 'work') return 'WORK'
  return 'OTHER'
}

function splitValue(fields: JsonObject): { percentage: number | null; shares: number | null } {
  const mode = splitMode(fields)
  return {
    percentage: mode === 'PERCENTAGE' ? numericMetadata(fields.percentage ?? fields.value ?? fields.valueString, 'split.percentage') : null,
    shares: mode === 'SHARES' ? integerMetadata(fields.shares ?? fields.value ?? fields.valueString, 'split.shares') : null,
  }
}

function expenseSplitMode(source: CloudKitSourceRecord, state: SemanticState): 'EQUAL' | 'EXACT' | 'PERCENTAGE' | 'SHARES' {
  const explicit = stringField(source.fields, ['splitType', 'splitMode'], `expense.${source.sourceId}.splitType`)
  if (explicit) return splitMode(source.fields)
  const inline = state.inlineSplitsByExpenseRef.get(referenceKey(source)) ?? []
  const separate = state.splitRowsByExpenseRef.get(referenceKey(source)) ?? []
  const first = inline[0]?.fields ?? separate[0]?.fields
  return first ? splitMode(first) : 'EQUAL'
}

function participantId(groupId: string, accountId: string): string {
  return targetId('participant', `${groupId}:${accountId}`)
}

async function ensureGroupMembers(
  tx: DbTransaction,
  group: CloudKitSourceRecord,
  groupId: string,
  state: SemanticState,
  ownerAccountId: string
): Promise<void> {
  for (const reference of groupMemberReferences(group)) {
    const person = sourceRecordForPerson(state.peopleByRef, reference, `group.${group.sourceId}.memberIDs`)
    const role = person.accountId === ownerAccountId ? 'ADMIN' : 'MEMBER'
    await tx.groupMember.upsert({
      where: { groupId_userId: { groupId, userId: person.accountId } },
      create: {
        id: targetId('member', `${groupId}:${person.accountId}`),
        groupId,
        userId: person.accountId,
        role,
      },
      update: { role },
    })
    const id = participantId(groupId, person.accountId)
    await tx.groupParticipant.upsert({
      where: { groupId_userId: { groupId, userId: person.accountId } },
      create: {
        id,
        groupId,
        userId: person.accountId,
        displayName: person.displayName,
      },
      update: { displayName: person.displayName },
    })
  }
}

async function importPerson(
  _tx: DbTransaction,
  source: CloudKitSourceRecord,
  state: SemanticState
): Promise<{ targetType: string; targetId: string; inlineSplits: number }> {
  const person = state.peopleByRef.get(source.sourceId) ?? state.peopleByRef.get(source.recordName)
  if (!person) throw new CloudKitImportNeedsRepairError(`person ${source.sourceId} is not claimed`, 'missing_member_claim')
  return { targetType: 'user', targetId: person.accountId, inlineSplits: 0 }
}

async function importGroup(
  tx: DbTransaction,
  source: CloudKitSourceRecord,
  state: SemanticState,
  ownerAccountId: string,
  now: Date
): Promise<{ targetType: string; targetId: string; inlineSplits: number }> {
  const groupId = sourceTargetId('group', source)
  const currency = state.groupCurrencyByLogicalKey.get(referenceKey(source))
  if (!currency) throw new CloudKitImportNeedsRepairError(`group ${source.sourceId} has no currency`, 'money_not_exact')
  const createdAt = sourceDate(source.fields, ['createdAt', 'date'], `group.${source.sourceId}.createdAt`, now)
  const name = stringField(source.fields, ['name', 'title'], `group.${source.sourceId}.name`) ?? 'Imported group'
  await tx.group.upsert({
    where: { id: groupId },
    create: {
      id: groupId,
      name,
      description: stringField(source.fields, ['description'], `group.${source.sourceId}.description`),
      currency,
      category: groupCategory(source.fields),
      simplifyDebts: booleanField(source.fields, ['simplifyDebts', 'simplify'], true),
      createdAt,
    },
    update: {
      name,
      description: stringField(source.fields, ['description'], `group.${source.sourceId}.description`),
      currency,
      category: groupCategory(source.fields),
      simplifyDebts: booleanField(source.fields, ['simplifyDebts', 'simplify'], true),
    },
  })
  await ensureGroupMembers(tx, source, groupId, state, ownerAccountId)
  return { targetType: 'group', targetId: groupId, inlineSplits: 0 }
}

function groupForExpense(state: SemanticState, expense: CloudKitSourceRecord): CloudKitSourceRecord {
  const groupReference = sourceGroupReference(expense.fields, `expense.${expense.sourceId}.groupID`)
  const group = state.groupsByRef.get(groupReference)
  if (!group) throw new CloudKitImportNeedsRepairError(`expense ${expense.sourceId} references an unknown group`, 'dependency_missing')
  return group
}

function expenseMoney(state: SemanticState, expense: CloudKitSourceRecord): ExactMoney {
  const group = groupForExpense(state, expense)
  const currency = state.groupCurrencyByLogicalKey.get(referenceKey(group))
  return exactMoneyField(expense.fields, {
    currencyCode: currency,
    currencyExponent: currency ? getCurrencyExponent(currency) : null,
  }, `expense.${expense.sourceId}`)
}

async function upsertSplit(
  tx: DbTransaction,
  splitId: string,
  expenseId: string,
  fields: JsonObject,
  money: ExactMoney,
  person: ResolvedPerson
): Promise<void> {
  const metadata = splitValue(fields)
  await tx.expenseSplit.upsert({
    where: { id: splitId },
    create: {
      id: splitId,
      expenseId,
      userId: person.accountId,
      amount: legacyAmount(money),
      amountMinorUnits: money.minorUnits,
      currencyExponent: money.currencyExponent,
      percentage: metadata.percentage,
      shares: metadata.shares,
      isPaid: booleanField(fields, ['isPaid', 'paid'], false),
    },
    update: {
      amount: legacyAmount(money),
      amountMinorUnits: money.minorUnits,
      currencyExponent: money.currencyExponent,
      percentage: metadata.percentage,
      shares: metadata.shares,
      isPaid: booleanField(fields, ['isPaid', 'paid'], false),
      userId: person.accountId,
    },
  })
}

async function importExpense(
  tx: DbTransaction,
  source: CloudKitSourceRecord,
  state: SemanticState,
  now: Date
): Promise<{ targetType: string; targetId: string; inlineSplits: number }> {
  const group = groupForExpense(state, source)
  const groupId = sourceTargetId('group', group)
  const money = expenseMoney(state, source)
  const payerReference = requiredField(source.fields, ['paidByID', 'paidById', 'paidBy', 'payerId'], `expense.${source.sourceId}.paidByID`)
  const payer = sourceRecordForPerson(state.peopleByRef, payerReference, `expense.${source.sourceId}.paidByID`)
  const expenseId = sourceTargetId('expense', source)
  const date = sourceDate(source.fields, ['date', 'createdAt'], `expense.${source.sourceId}.date`, now)
  const description = stringField(source.fields, ['title', 'description', 'name'], `expense.${source.sourceId}.title`) ?? 'Imported expense'
  const category = stringField(source.fields, ['category'], `expense.${source.sourceId}.category`) ?? 'general'
  const splitType = expenseSplitMode(source, state)
  await tx.expense.upsert({
    where: { id: expenseId },
    create: {
      id: expenseId,
      description,
      amount: legacyAmount(money),
      amountMinorUnits: money.minorUnits,
      currencyExponent: money.currencyExponent,
      currency: money.currencyCode,
      date,
      category,
      groupId,
      paidById: payer.accountId,
      splitType,
      notes: stringField(source.fields, ['notes'], `expense.${source.sourceId}.notes`),
      isDeleted: booleanField(source.fields, ['isDeleted', 'deleted'], false),
    },
    update: {
      description,
      amount: legacyAmount(money),
      amountMinorUnits: money.minorUnits,
      currencyExponent: money.currencyExponent,
      currency: money.currencyCode,
      date,
      category,
      groupId,
      paidById: payer.accountId,
      splitType,
      notes: stringField(source.fields, ['notes'], `expense.${source.sourceId}.notes`),
      isDeleted: booleanField(source.fields, ['isDeleted', 'deleted'], false),
    },
  })

  const inlineSplits = state.inlineSplitsByExpenseRef.get(referenceKey(source)) ?? []
  for (const inline of inlineSplits) {
    const person = sourceRecordForPerson(state.peopleByRef, sourcePersonReference(inline.fields, `split.${inline.sourceId}.personID`), `split.${inline.sourceId}.personID`)
    const splitMoneyValue = splitMoney(inline.fields, money, `split.${inline.sourceId}`)
    await upsertSplit(tx, targetId('split', `${sourceRecordKey(source)}:${inline.sourceId}`), expenseId, inline.fields, splitMoneyValue, person)
  }
  return { targetType: 'expense', targetId: expenseId, inlineSplits: inlineSplits.length }
}

async function importSplit(
  tx: DbTransaction,
  source: CloudKitSourceRecord,
  state: SemanticState
): Promise<{ targetType: string; targetId: string; inlineSplits: number }> {
  const expenseReference = sourceExpenseReference(source.fields, `split.${source.sourceId}.expenseID`)
  const expense = state.expensesByRef.get(expenseReference)
  if (!expense) throw new CloudKitImportNeedsRepairError(`split ${source.sourceId} references an unknown expense`, 'dependency_missing')
  const money = expenseMoney(state, expense)
  const person = sourceRecordForPerson(state.peopleByRef, sourcePersonReference(source.fields, `split.${source.sourceId}.personID`), `split.${source.sourceId}.personID`)
  const splitId = targetId('split', sourceRecordKey(source))
  await upsertSplit(tx, splitId, sourceTargetId('expense', expense), source.fields, splitMoney(source.fields, money, `split.${source.sourceId}`), person)
  return { targetType: 'split', targetId: splitId, inlineSplits: 0 }
}

function settlementMode(fields: JsonObject): 'DIRECT' | 'SIMPLIFIED' {
  const value = stringField(fields, ['settlementMode', 'mode'], 'settlement.mode')?.toUpperCase()
  return value === 'SIMPLIFIED' ? 'SIMPLIFIED' : 'DIRECT'
}

async function importSettlement(
  tx: DbTransaction,
  source: CloudKitSourceRecord,
  state: SemanticState,
  ownerAccountId: string,
  now: Date
): Promise<{ targetType: string; targetId: string; inlineSplits: number }> {
  const group = state.groupsByRef.get(sourceGroupReference(source.fields, `settlement.${source.sourceId}.groupID`))
  if (!group) throw new CloudKitImportNeedsRepairError(`settlement ${source.sourceId} references an unknown group`, 'dependency_missing')
  const groupId = sourceTargetId('group', group)
  const from = sourceRecordForPerson(state.peopleByRef, requiredField(source.fields, ['fromID', 'fromId', 'senderId', 'from'], `settlement.${source.sourceId}.fromID`), `settlement.${source.sourceId}.fromID`)
  const to = sourceRecordForPerson(state.peopleByRef, requiredField(source.fields, ['toID', 'toId', 'receiverId', 'to'], `settlement.${source.sourceId}.toID`), `settlement.${source.sourceId}.toID`)
  const currency = state.groupCurrencyByLogicalKey.get(referenceKey(group))
  const money = exactMoneyField(source.fields, {
    currencyCode: currency,
    currencyExponent: currency ? getCurrencyExponent(currency) : null,
  }, `settlement.${source.sourceId}`)
  const actorReference = stringField(source.fields, ['actorID', 'actorId', 'actor'], `settlement.${source.sourceId}.actorID`)
  const actor = actorReference ? sourceRecordForPerson(state.peopleByRef, actorReference, `settlement.${source.sourceId}.actorID`) : from
  const transactionId = sourceTargetId('settlement', source)
  const payerParticipantId = participantId(groupId, from.accountId)
  const recipientParticipantId = participantId(groupId, to.accountId)
  const rawVersion = source.fields.settlementGroupVersion ?? source.fields.version
  const version = typeof rawVersion === 'number' && Number.isInteger(rawVersion) ? rawVersion : null
  await tx.transaction.upsert({
    where: { id: transactionId },
    create: {
      id: transactionId,
      senderId: from.accountId,
      receiverId: to.accountId,
      amount: legacyAmount(money),
      amountMinorUnits: money.minorUnits,
      currencyExponent: money.currencyExponent,
      currency: money.currencyCode,
      note: stringField(source.fields, ['note', 'notes'], `settlement.${source.sourceId}.note`),
      groupId,
      payerParticipantId,
      recipientParticipantId,
      actorUserId: actor.accountId || ownerAccountId,
      settlementMode: settlementMode(source.fields),
      settlementGroupVersion: version,
      createdAt: sourceDate(source.fields, ['date', 'createdAt'], `settlement.${source.sourceId}.date`, now),
    },
    update: {
      senderId: from.accountId,
      receiverId: to.accountId,
      amount: legacyAmount(money),
      amountMinorUnits: money.minorUnits,
      currencyExponent: money.currencyExponent,
      currency: money.currencyCode,
      note: stringField(source.fields, ['note', 'notes'], `settlement.${source.sourceId}.note`),
      groupId,
      payerParticipantId,
      recipientParticipantId,
      actorUserId: actor.accountId || ownerAccountId,
      settlementMode: settlementMode(source.fields),
      settlementGroupVersion: version,
      createdAt: sourceDate(source.fields, ['date', 'createdAt'], `settlement.${source.sourceId}.date`, now),
    },
  })
  return { targetType: 'settlement', targetId: transactionId, inlineSplits: 0 }
}

function activityType(fields: JsonObject): 'EXPENSE_CREATED' | 'EXPENSE_UPDATED' | 'EXPENSE_DELETED' | 'PAYMENT_MADE' | 'GROUP_CREATED' | 'GROUP_JOINED' | 'FRIEND_ADDED' | 'COMMENT_ADDED' {
  const raw = stringField(fields, ['kind', 'type', 'activityType'], 'activity.type')?.toLowerCase()
  if (raw === 'expenseedited' || raw === 'expense_updated' || raw === 'expenseupdated') return 'EXPENSE_UPDATED'
  if (raw === 'expensedeleted' || raw === 'expense_deleted') return 'EXPENSE_DELETED'
  if (raw === 'settlementrecorded' || raw === 'payment' || raw === 'payment_made' || raw === 'paymentmade') return 'PAYMENT_MADE'
  if (raw === 'groupcreated' || raw === 'group_created') return 'GROUP_CREATED'
  if (raw === 'memberadded' || raw === 'group_joined' || raw === 'groupjoined') return 'GROUP_JOINED'
  if (raw === 'friendadded' || raw === 'friend_added') return 'FRIEND_ADDED'
  if (raw === 'commentadded' || raw === 'comment_added') return 'COMMENT_ADDED'
  return 'EXPENSE_CREATED'
}

function activityReferenceTarget(
  fields: JsonObject,
  state: SemanticState
): { groupId: string | null; referenceId: string | null } {
  const groupReference = stringField(fields, ['groupID', 'groupId', 'group'], 'activity.groupID')
  const groupId = groupReference ? (state.groupsByRef.get(groupReference) ? sourceTargetId('group', state.groupsByRef.get(groupReference)!) : null) : null
  const reference = stringField(fields, ['refID', 'refId', 'recordId'], 'activity.refID')
  if (!reference) return { groupId, referenceId: null }
  const expense = state.expensesByRef.get(reference)
  if (expense) return { groupId, referenceId: sourceTargetId('expense', expense) }
  const settlement = state.settlementsByRef.get(reference)
  if (settlement) return { groupId, referenceId: sourceTargetId('settlement', settlement) }
  return { groupId, referenceId: null }
}

async function importActivity(
  tx: DbTransaction,
  source: CloudKitSourceRecord,
  state: SemanticState,
  ownerAccountId: string,
  now: Date,
  importId: string
): Promise<{ targetType: string; targetId: string; inlineSplits: number }> {
  const groupReference = stringField(source.fields, ['groupID', 'groupId', 'group'], `activity.${source.sourceId}.groupID`)
  const group = groupReference ? state.groupsByRef.get(groupReference) : null
  const actorReference = stringField(source.fields, ['actorID', 'actorId', 'actor'], `activity.${source.sourceId}.actorID`)
  const actor = actorReference ? sourceRecordForPerson(state.peopleByRef, actorReference, `activity.${source.sourceId}.actorID`) : (group ? state.groupOwnerByLogicalKey.get(referenceKey(group)) : null)
  const referenceTarget = activityReferenceTarget(source.fields, state)
  const activityId = sourceTargetId('activity', source)
  const description = stringField(source.fields, ['summary', 'description', 'message'], `activity.${source.sourceId}.summary`) ?? 'Imported ledger activity'
  const metadata: JsonObject = {
    source: CLOUDKIT_IMPORT_SOURCE,
    migrationId: importId,
    sourceDatabase: source.database,
    sourceZone: source.zoneName,
    sourceRecordType: source.recordType,
    sourceRecordName: source.recordName,
    sourceChecksum: source.checksum,
    groupId: referenceTarget.groupId,
    referenceId: referenceTarget.referenceId,
  }
  await tx.activityLog.upsert({
    where: { id: activityId },
    create: {
      id: activityId,
      userId: actor?.accountId ?? ownerAccountId,
      type: activityType(source.fields),
      description,
      metadata: jsonInput(metadata),
      createdAt: sourceDate(source.fields, ['timestamp', 'createdAt', 'date'], `activity.${source.sourceId}.timestamp`, now),
    },
    update: {
      userId: actor?.accountId ?? ownerAccountId,
      type: activityType(source.fields),
      description,
      metadata: jsonInput(metadata),
      createdAt: sourceDate(source.fields, ['timestamp', 'createdAt', 'date'], `activity.${source.sourceId}.timestamp`, now),
    },
  })
  return { targetType: 'activity', targetId: activityId, inlineSplits: 0 }
}

type ProcessedSource = {
  targetType: string
  targetId: string
  inlineSplits: number
  reused: boolean
}

async function processSourceRecord(
  tx: DbTransaction,
  accountId: string,
  importId: string,
  source: CloudKitSourceRecord,
  state: SemanticState,
  now: Date
): Promise<ProcessedSource> {
  const row = await tx.ledgerImportRecord.findUnique({
    where: {
      accountId_sourceSystem_sourceRecordKey: {
        accountId,
        sourceSystem: CLOUDKIT_IMPORT_SOURCE,
        sourceRecordKey: source.logicalKey,
      },
    },
    select: { id: true, importId: true, state: true, payloadChecksum: true, targetType: true, targetId: true },
  })
  if (!row) throw new CloudKitImportNeedsRepairError(`source record ${source.recordName} was not reserved`, 'source_checksum_conflict')
  if (row.payloadChecksum !== source.checksum) throw new CloudKitImportNeedsRepairError(`source record ${source.recordName} checksum changed`, 'source_checksum_conflict')
  if (row.state === 'IMPORTED' || row.state === 'SKIPPED') {
    if (!row.targetType || !row.targetId) throw new CloudKitImportNeedsRepairError(`source record ${source.recordName} has no import target`, 'dependency_missing')
    return { targetType: row.targetType, targetId: row.targetId, inlineSplits: 0, reused: true }
  }
  const result = source.recordType === CLOUDKIT_RECORD_TYPES.PERSON
    ? await importPerson(tx, source, state)
    : source.recordType === CLOUDKIT_RECORD_TYPES.GROUP
      ? await importGroup(tx, source, state, accountId, now)
      : source.recordType === CLOUDKIT_RECORD_TYPES.EXPENSE
        ? await importExpense(tx, source, state, now)
        : source.recordType === CLOUDKIT_RECORD_TYPES.SPLIT
          ? await importSplit(tx, source, state)
          : source.recordType === CLOUDKIT_RECORD_TYPES.SETTLEMENT
            ? await importSettlement(tx, source, state, accountId, now)
            : await importActivity(tx, source, state, accountId, now, importId)
  await tx.ledgerImportRecord.update({
    where: { id: row.id },
    data: {
      state: 'IMPORTED',
      targetType: result.targetType,
      targetId: result.targetId,
      quarantineReason: null,
      updatedAt: now,
    },
  })
  return { ...result, reused: row.importId !== importId }
}

async function processAllRecords(
  rootDb: CloudKitImportDb,
  accountId: string,
  importId: string,
  normalized: NormalizedCloudKitExport,
  state: SemanticState,
  now: Date
): Promise<void> {
  const ordered = [...normalized.records].sort((left, right) =>
    IMPORTABLE_RECORD_RANK[left.recordType] - IMPORTABLE_RECORD_RANK[right.recordType] || sourceRecordKey(left).localeCompare(sourceRecordKey(right))
  )
  for (const source of ordered) {
    try {
      await withTransaction(rootDb, (tx) => processSourceRecord(tx, accountId, importId, source, state, now))
    } catch (error) {
      if (error instanceof CloudKitImportNeedsRepairError || error instanceof CloudKitImportValidationError) {
        await withTransaction(rootDb, async (tx) => {
          const row = await tx.ledgerImportRecord.findUnique({
            where: {
              accountId_sourceSystem_sourceRecordKey: {
                accountId,
                sourceSystem: CLOUDKIT_IMPORT_SOURCE,
                sourceRecordKey: source.logicalKey,
              },
            },
            select: { id: true },
          })
          if (row) await tx.ledgerImportRecord.update({ where: { id: row.id }, data: { state: 'QUARANTINED', quarantineReason: error.message } })
          await tx.ledgerImport.update({ where: { id: importId }, data: { state: 'FAILED', failureReason: error.message, completedAt: null } })
        })
        return
      }
      throw error
    }
  }
  await withTransaction(rootDb, async (tx) => {
    let ready = true
    for (const source of normalized.records) {
      const row = await tx.ledgerImportRecord.findUnique({
        where: {
          accountId_sourceSystem_sourceRecordKey: {
            accountId,
            sourceSystem: CLOUDKIT_IMPORT_SOURCE,
            sourceRecordKey: source.logicalKey,
          },
        },
        select: { state: true },
      })
      if (!row || (row.state !== 'IMPORTED' && row.state !== 'SKIPPED')) {
        ready = false
        break
      }
    }
    if (ready) {
      await tx.ledgerImport.update({
        where: { id: importId },
        data: { state: 'COMPLETED', completedAt: now, failureReason: null },
      })
    }
  })
}

async function loadImportRow(rootDb: CloudKitImportDb, accountId: string, importId: string): Promise<ImportRow> {
  const row = await rootDb.ledgerImport.findFirst({
    where: { id: importId, accountId, sourceSystem: CLOUDKIT_IMPORT_SOURCE },
    select: rowSelect(),
  }) as ImportRow | null
  if (!row) throw new CloudKitImportValidationError('import_not_found', 'CloudKit import was not found', { importId })
  return row
}

async function loadStoredNormalized(rootDb: CloudKitImportDb, row: ImportRow): Promise<NormalizedCloudKitExport> {
  const metadata = await rootDb.ledgerImportRecord.findFirst({
    where: { importId: row.id, sourceSystem: CLOUDKIT_IMPORT_SOURCE, sourceRecordType: METADATA_RECORD_TYPE },
    select: { payload: true },
  })
  if (!metadata?.payload) {
    throw new CloudKitImportValidationError('invalid_envelope', 'CloudKit import metadata is unavailable', { importId: row.id })
  }
  return normalizeCloudKitExport(metadata.payload)
}

function emptyCounts(): CloudKitImportCounts {
  return {
    people: 0,
    groups: 0,
    expenses: 0,
    splits: 0,
    settlements: 0,
    activity: 0,
    importedRecords: 0,
    duplicateRecords: 0,
  }
}

async function buildImportResult(
  rootDb: CloudKitImportDb,
  row: ImportRow,
  normalized: NormalizedCloudKitExport
): Promise<CloudKitImportResult> {
  const rows = await rootDb.ledgerImportRecord.findMany({
    where: { accountId: row.accountId, sourceSystem: CLOUDKIT_IMPORT_SOURCE, sourceRecordType: { not: METADATA_RECORD_TYPE }, OR: [{ importId: row.id }, { sourceRecordKey: { in: normalized.records.map((record) => record.logicalKey) } }] },
    select: { importId: true, sourceRecordKey: true, sourceRecordType: true, payload: true, payloadChecksum: true, state: true, targetId: true },
    orderBy: [{ sourceRecordType: 'asc' }, { sourceRecordKey: 'asc' }],
  })
  const rowByKey = new Map(rows.map((record) => [record.sourceRecordKey, record]))
  const counts = emptyCounts()
  const serverGroupIds: string[] = []
  const importedGroups: Array<{ source: CloudKitSourceRecord; targetId: string }> = []
  for (const source of normalized.records) {
    const record = rowByKey.get(source.logicalKey)
    if (!record || (record.state !== 'IMPORTED' && record.state !== 'SKIPPED')) continue
    counts.importedRecords += 1
    if (record.importId !== row.id) counts.duplicateRecords += 1
    switch (source.recordType) {
      case CLOUDKIT_RECORD_TYPES.PERSON:
        counts.people += 1
        break
      case CLOUDKIT_RECORD_TYPES.GROUP:
        counts.groups += 1
        if (record.targetId) {
          serverGroupIds.push(record.targetId)
          importedGroups.push({ source, targetId: record.targetId })
        }
        break
      case CLOUDKIT_RECORD_TYPES.EXPENSE:
        counts.expenses += 1
        counts.splits += objectArrayField(source.fields, ['splits'], `expense.${source.sourceId}`).length
        break
      case CLOUDKIT_RECORD_TYPES.SPLIT:
        counts.splits += 1
        break
      case CLOUDKIT_RECORD_TYPES.SETTLEMENT:
        counts.settlements += 1
        break
      case CLOUDKIT_RECORD_TYPES.ACTIVITY:
        counts.activity += 1
        break
    }
  }
  counts.duplicateRecords += normalized.duplicateRecordCount
  const status = physicalStatus(row.state)
  const importedAt = row.completedAt?.toISOString() ?? null
  const migrationStatus = status === 'completed' ? 'complete' : status === 'needs-repair' ? 'blocked' : status === 'running' ? 'in_progress' : 'pending'
  const migrationMarkers: CloudKitMigrationMarker[] = status === 'completed' && importedAt
    ? importedGroups.map(({ source, targetId }) => ({
        source: CLOUDKIT_IMPORT_SOURCE,
        migrationId: row.id,
        status: 'complete',
        dualWriteEnabled: false,
        recoveryReadOnly: true,
        importedAt,
        serverGroupId: targetId,
        sourceGroupRecordName: source.recordName,
      }))
    : []
  return {
    importId: row.id,
    source: CLOUDKIT_IMPORT_SOURCE,
    sourceKey: row.sourceKey,
    sourceChecksum: row.sourceChecksum,
    status,
    counts,
    serverGroupIds: Array.from(new Set(serverGroupIds)).sort(),
    serverGroupId: Array.from(new Set(serverGroupIds)).sort()[0] ?? null,
    migration: {
      status: migrationStatus,
      source: CLOUDKIT_IMPORT_SOURCE,
      migrationId: row.id,
      importedAt,
      dualWriteEnabled: false,
      recoveryReadOnly: true,
    },
    migrationMarkers,
    startedAt: row.startedAt?.toISOString() ?? null,
    completedAt: importedAt,
    needsRepairReason: row.failureReason,
  }
}

async function runNormalizedImport(
  rootDb: CloudKitImportDb,
  accountId: string,
  normalized: NormalizedCloudKitExport,
  now: Date
): Promise<CloudKitImportResult> {
  const prepared = await prepareImport(rootDb, accountId, normalized, now)
  let row = await loadImportRow(rootDb, accountId, prepared.importId)
  if (prepared.status === 'completed' || prepared.status === 'needs-repair') {
    return buildImportResult(rootDb, row, normalized)
  }

  let state: SemanticState
  try {
    state = await withTransaction(rootDb, (tx) => validateAndResolve(tx, accountId, normalized))
  } catch (error) {
    if (!(error instanceof CloudKitImportNeedsRepairError) && !(error instanceof CloudKitImportValidationError)) throw error
    await withTransaction(rootDb, async (tx) => {
      await tx.ledgerImport.update({ where: { id: prepared.importId }, data: { state: 'FAILED', failureReason: error.message, completedAt: null } })
    })
    row = await loadImportRow(rootDb, accountId, prepared.importId)
    return buildImportResult(rootDb, row, normalized)
  }
  await processAllRecords(rootDb, accountId, prepared.importId, normalized, state, now)
  row = await loadImportRow(rootDb, accountId, prepared.importId)
  return buildImportResult(rootDb, row, normalized)
}

export async function importCloudKitLedger(request: CloudKitImportRequest): Promise<CloudKitImportResult> {
  const normalized = normalizeCloudKitExport(request.export)
  const rootDb = request.db ?? defaultPrisma
  return runNormalizedImport(rootDb, request.accountId, normalized, request.now ?? new Date())
}

export async function resumeCloudKitImport(input: CloudKitImportLookup & { export?: unknown; now?: Date }): Promise<CloudKitImportResult> {
  const rootDb = input.db ?? defaultPrisma
  const row = await loadImportRow(rootDb, input.accountId, input.importId)
  const normalized = input.export === undefined
    ? await loadStoredNormalized(rootDb, row)
    : normalizeCloudKitExport(input.export)
  if (normalized.sourceKey !== row.sourceKey) {
    throw new CloudKitImportValidationError('source_checksum_conflict', 'The export does not belong to this CloudKit import', { importId: row.id })
  }
  return runNormalizedImport(rootDb, input.accountId, normalized, input.now ?? new Date())
}

export async function getCloudKitImport(input: CloudKitImportLookup): Promise<CloudKitImportResult> {
  const rootDb = input.db ?? defaultPrisma
  const row = await loadImportRow(rootDb, input.accountId, input.importId)
  const normalized = await loadStoredNormalized(rootDb, row)
  return buildImportResult(rootDb, row, normalized)
}

export async function listCloudKitImports(input: { accountId: string; db?: CloudKitImportDb }): Promise<CloudKitImportResult[]> {
  const rootDb = input.db ?? defaultPrisma
  const rows = await rootDb.ledgerImport.findMany({
    where: { accountId: input.accountId, sourceSystem: CLOUDKIT_IMPORT_SOURCE },
    select: rowSelect(),
    orderBy: [{ createdAt: 'desc' }, { id: 'desc' }],
  }) as ImportRow[]
  return Promise.all(rows.map(async (row) => buildImportResult(rootDb, row, await loadStoredNormalized(rootDb, row))))
}

export function cloudKitImportErrorStatus(error: unknown): number {
  if (error instanceof CloudKitImportValidationError) {
    if (error.code === 'import_not_found') return 404
    if (error.code === 'completed_import_frozen' || error.code === 'source_checksum_conflict') return 409
    return 400
  }
  if (error instanceof CloudKitImportNeedsRepairError) return 409
  return 500
}

export function cloudKitImportErrorBody(error: unknown): Record<string, unknown> {
  if (error instanceof CloudKitImportValidationError || error instanceof CloudKitImportNeedsRepairError) {
    return {
      error: error.message,
      code: error.code,
      ...(error.details ?? {}),
    }
  }
  return { error: 'Internal server error' }
}
