import { createHash } from 'node:crypto'
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { basename, extname, join, resolve } from 'node:path'

type TableName = 'Expense' | 'ExpenseSplit' | 'Transaction'
type Classification = 'converted' | 'alreadyExact' | 'quarantined'

const MIN_BIGINT = BigInt('-9223372036854775808')
const MAX_BIGINT = BigInt('9223372036854775807')

type JsonObject = Record<string, unknown>

type LegacyRow = {
  tableName: TableName
  id: string
  amount: unknown
  currency: unknown
  groupId: unknown
  amountMinorUnits: unknown
  currencyExponent: unknown
  expenseId?: unknown
}

type RegistryEntry = {
  code: string
  exponent: number
  version: number
}

type Registry = {
  entries: Map<string, RegistryEntry>
  ambiguousCodes: Set<string>
}

type RehearsalData = {
  rows: LegacyRow[]
  registry: Registry
  source: string
}

type DecimalValue = {
  digits: string
  scale: number
  negative: boolean
}

type ClassifiedRow = {
  row: LegacyRow
  classification: Classification
  currencyCode: string | null
  amountText: string | null
  minorUnits: bigint | null
  currencyExponent: number | null
  reason: string | null
}

type RehearsalReport = {
  mode: 'dry-run' | 'apply'
  source: string
  registryEntries: number
  records: number
  counts: {
    converted: number
    alreadyExact: number
    quarantined: number
    unresolved: number
  }
  checksums: {
    input: string
    all: string
    converted: string
    alreadyExact: string
    quarantined: string
  }
  unresolvedRecords: Array<{
    tableName: TableName
    recordId: string
    currencyCode: string | null
    amount: string | null
    reason: string
  }>
  applied?: {
    converted: number
    quarantined: number
  }
}

function canonicalKey(value: string): string {
  return value.replace(/[^a-zA-Z0-9]/g, '').toLowerCase()
}

function isObject(value: unknown): value is JsonObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function valueFor(object: JsonObject, names: readonly string[]): unknown {
  const wanted = new Set(names.map(canonicalKey))
  for (const [key, value] of Object.entries(object)) {
    if (wanted.has(canonicalKey(key))) return value
  }
  return undefined
}

function tableFromName(value: string): TableName | null {
  const key = canonicalKey(value)
  if (key === 'expense' || key === 'expenses') return 'Expense'
  if (key === 'expensesplit' || key === 'expensesplits' || key === 'split' || key === 'splits') return 'ExpenseSplit'
  if (key === 'transaction' || key === 'transactions') return 'Transaction'
  return null
}

function isRegistryName(value: string): boolean {
  const key = canonicalKey(value)
  return (
    key === 'registry' ||
    key === 'registries' ||
    key === 'currencyregistry' ||
    key === 'currencyregistries' ||
    key === 'currencyexponents' ||
    key === 'currencyexponentregistry' ||
    key === 'currencyexponentregistries' ||
    key === 'currencies'
  )
}

function tableFromPath(path: string): TableName | null {
  return tableFromName(basename(path, extname(path)))
}

function registryFromPath(path: string): boolean {
  return isRegistryName(basename(path, extname(path)))
}

function stringOrNull(value: unknown): string | null {
  if (value === null || value === undefined) return null
  if (typeof value === 'string') {
    const trimmed = value.trim()
    return trimmed.length === 0 ? null : trimmed
  }
  if (typeof value === 'bigint') return value.toString()
  return String(value)
}

function normalizeCode(value: unknown): string | null {
  const text = stringOrNull(value)
  return text === null ? null : text.toUpperCase()
}

function numberOrDefault(value: unknown, fallback: number): number {
  const text = stringOrNull(value)
  if (text === null) return fallback
  const number = Number(text)
  return Number.isInteger(number) ? number : fallback
}

function normalizeRegistryEntry(value: unknown): RegistryEntry | null {
  if (!isObject(value)) return null
  const code = normalizeCode(valueFor(value, ['code', 'currency', 'currencyCode']))
  const exponentText = stringOrNull(valueFor(value, ['exponent', 'currencyExponent']))
  if (code === null || exponentText === null || !/^-?\d+$/.test(exponentText)) return null
  const exponent = Number(exponentText)
  if (!Number.isSafeInteger(exponent)) return null
  return {
    code,
    exponent,
    version: numberOrDefault(valueFor(value, ['version', 'registryVersion']), 1),
  }
}

function addRegistryEntry(registry: Registry, entry: RegistryEntry): void {
  const existing = registry.entries.get(entry.code)
  if (existing === undefined || entry.version > existing.version) {
    registry.entries.set(entry.code, entry)
    registry.ambiguousCodes.delete(entry.code)
    return
  }
  if (entry.version === existing.version && entry.exponent !== existing.exponent) {
    registry.ambiguousCodes.add(entry.code)
  }
}

function addRegistryValue(registry: Registry, value: unknown): void {
  if (Array.isArray(value)) {
    for (const item of value) addRegistryValue(registry, item)
    return
  }

  const entry = normalizeRegistryEntry(value)
  if (entry !== null) {
    addRegistryEntry(registry, entry)
    return
  }

  if (!isObject(value)) return
  for (const [code, exponentValue] of Object.entries(value)) {
    const exponentText = stringOrNull(exponentValue)
    if (exponentText === null || !/^-?\d+$/.test(exponentText)) continue
    const exponent = Number(exponentText)
    if (!Number.isSafeInteger(exponent)) continue
    addRegistryEntry(registry, { code: code.toUpperCase(), exponent, version: 1 })
  }
}

function rowFromObject(tableName: TableName, value: unknown, index: number): LegacyRow | null {
  if (!isObject(value)) return null
  const idNames =
    tableName === 'Expense'
      ? ['id', 'expenseId', 'recordId', 'legacyId']
      : tableName === 'ExpenseSplit'
        ? ['id', 'splitId', 'recordId', 'legacyId']
        : ['id', 'transactionId', 'settlementId', 'recordId', 'legacyId']
  const id = stringOrNull(valueFor(value, idNames)) ?? `${tableName.toLowerCase()}-${index + 1}`
  const amountValue = valueFor(value, ['amount', 'legacyAmount', 'legacyValue', 'amountFloat', 'floatValue', 'value'])
  const canonicalMoney = isObject(amountValue) ? amountValue : null
  return {
    tableName,
    id,
    amount: canonicalMoney === null ? amountValue : valueFor(canonicalMoney, ['majorUnits', 'decimalAmount']),
    currency:
      valueFor(value, ['currency', 'currencyCode', 'currency_code']) ??
      (canonicalMoney === null ? undefined : valueFor(canonicalMoney, ['currency', 'currencyCode'])),
    groupId: valueFor(value, ['groupId', 'group_id']),
    amountMinorUnits:
      valueFor(value, ['amountMinorUnits', 'minorUnits', 'minor_units']) ??
      (canonicalMoney === null ? undefined : valueFor(canonicalMoney, ['amountMinorUnits', 'minorUnits'])),
    currencyExponent:
      valueFor(value, ['currencyExponent', 'currency_exponent']) ??
      (canonicalMoney === null ? undefined : valueFor(canonicalMoney, ['currencyExponent'])),
    expenseId: valueFor(value, ['expenseId', 'expense_id']),
  }
}

type FixtureCollector = {
  rows: Map<string, LegacyRow>
  registry: Registry
}

function addRows(collector: FixtureCollector, tableName: TableName, value: unknown): void {
  const values = Array.isArray(value) ? value : [value]
  values.forEach((item, index) => {
    const row = rowFromObject(tableName, item, index)
    if (row === null) return

    collector.rows.set(`${row.tableName}:${row.id}`, row)

    const currencyCode = normalizeCode(row.currency)
    const minorUnits = exactMinor(row.amountMinorUnits)
    const currencyExponent = exactExponent(row.currencyExponent)
    if (currencyCode !== null && minorUnits !== null && currencyExponent !== null) {
      addRegistryEntry(collector.registry, { code: currencyCode, exponent: currencyExponent, version: 1 })
    }

    if (tableName !== 'Expense' || !isObject(item)) return
    const splits = valueFor(item, ['splits', 'expenseSplits'])
    if (!Array.isArray(splits)) return
    addRows(
      collector,
      'ExpenseSplit',
      splits.map((split) =>
        isObject(split)
          ? {
              ...split,
              expenseId: valueFor(split, ['expenseId', 'expense_id']) ?? row.id,
              groupId: valueFor(split, ['groupId', 'group_id']) ?? row.groupId,
            }
          : split
      )
    )
  })
}

function extractFixtureValue(
  collector: FixtureCollector,
  value: unknown,
  hint: TableName | 'registry' | null
): void {
  if (Array.isArray(value)) {
    if (hint === 'registry') {
      addRegistryValue(collector.registry, value)
    } else if (hint !== null) {
      addRows(collector, hint, value)
    } else {
      for (const item of value) extractFixtureValue(collector, item, null)
    }
    return
  }

  if (!isObject(value)) return

  const explicitTable = tableFromName(stringOrNull(valueFor(value, ['table', 'tableName', 'sourceTable'])) ?? '')
  if (explicitTable !== null) {
    addRows(collector, explicitTable, value)
    return
  }

  if (hint === 'registry') {
    addRegistryValue(collector.registry, value)
    return
  }

  if (hint !== null) {
    const hasRecordShape =
      valueFor(value, ['id', 'recordId', 'legacyId']) !== undefined ||
      valueFor(value, ['amount', 'legacyAmount', 'legacyValue', 'amountFloat', 'floatValue', 'value']) !== undefined
    if (hasRecordShape) {
      addRows(collector, hint, value)
      return
    }
  }

  for (const [key, child] of Object.entries(value)) {
    const table = tableFromName(key)
    if (table !== null) {
      addRows(collector, table, child)
    } else if (isRegistryName(key)) {
      addRegistryValue(collector.registry, child)
    } else if (canonicalKey(key) === 'data' || canonicalKey(key) === 'rows' || canonicalKey(key) === 'records' || canonicalKey(key) === 'fixture') {
      extractFixtureValue(collector, child, null)
    } else if (isObject(child) || Array.isArray(child)) {
      extractFixtureValue(collector, child, null)
    }
  }
}

function fixtureFiles(path: string): string[] {
  const info = statSync(path)
  if (info.isFile()) return [path]
  if (!info.isDirectory()) throw new Error(`Fixture path is not a file or directory: ${path}`)

  const files: string[] = []
  for (const entry of readdirSync(path, { withFileTypes: true })) {
    const child = join(path, entry.name)
    if (entry.isDirectory()) files.push(...fixtureFiles(child))
    else if (/\.(json|jsonl|ndjson)$/i.test(entry.name)) files.push(child)
  }
  return files.sort()
}

function parseFixtureFile(path: string): unknown {
  const text = readFileSync(path, 'utf8').trim()
  if (text.length === 0) return null
  if (/\.(jsonl|ndjson)$/i.test(path)) {
    return text.split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line))
  }
  return JSON.parse(text)
}

function loadFixture(pathValue: string): RehearsalData {
  const path = resolve(pathValue)
  const collector: FixtureCollector = {
    rows: new Map(),
    registry: { entries: new Map(), ambiguousCodes: new Set() },
  }

  for (const file of fixtureFiles(path)) {
    const hint: TableName | 'registry' | null = registryFromPath(file) ? 'registry' : tableFromPath(file)
    extractFixtureValue(collector, parseFixtureFile(file), hint)
  }

  const expenses = new Map(
    [...collector.rows.values()]
      .filter((row) => row.tableName === 'Expense')
      .map((row) => [row.id, row] as const)
  )
  const rows = [...collector.rows.values()].map((row) => {
    if (row.tableName !== 'ExpenseSplit' || normalizeCode(row.currency) !== null) return row
    const parent = expenses.get(stringOrNull(row.expenseId) ?? '')
    if (parent === undefined) return row
    return { ...row, currency: parent.currency, groupId: parent.groupId }
  })

  if (rows.length === 0) throw new Error(`No Expense, ExpenseSplit, or Transaction rows found in ${path}`)
  return { rows, registry: collector.registry, source: path }
}

function dbRow(tableName: TableName, value: JsonObject): LegacyRow {
  return {
    tableName,
    id: stringOrNull(value.id) ?? 'unknown',
    amount: value.amount,
    currency: value.currency,
    groupId: value.groupId,
    amountMinorUnits: value.amountMinorUnits,
    currencyExponent: value.currencyExponent,
  }
}

async function loadDatabase(): Promise<RehearsalData> {
  const { PrismaClient } = await import('@prisma/client')
  const prisma = new PrismaClient()
  try {
    type DbRow = JsonObject
    const registryRows = await prisma.$queryRawUnsafe<DbRow[]>(
      'SELECT "code", "exponent", "version" FROM "CurrencyExponentRegistry" ORDER BY "version", "code"'
    )
    const expenses = await prisma.$queryRawUnsafe<DbRow[]>(
      'SELECT "id", "amount"::text AS "amount", "currency", "groupId", "amountMinorUnits"::text AS "amountMinorUnits", "currencyExponent" FROM "Expense"'
    )
    const splits = await prisma.$queryRawUnsafe<DbRow[]>(
      'SELECT s."id", s."amount"::text AS "amount", e."currency", e."groupId", s."amountMinorUnits"::text AS "amountMinorUnits", s."currencyExponent" FROM "ExpenseSplit" s JOIN "Expense" e ON e."id" = s."expenseId"'
    )
    const transactions = await prisma.$queryRawUnsafe<DbRow[]>(
      'SELECT "id", "amount"::text AS "amount", "currency", "groupId", "amountMinorUnits"::text AS "amountMinorUnits", "currencyExponent" FROM "Transaction"'
    )
    const registry: Registry = { entries: new Map(), ambiguousCodes: new Set() }
    for (const value of registryRows) {
      const entry = normalizeRegistryEntry(value)
      if (entry !== null) addRegistryEntry(registry, entry)
    }
    const rows = [
      ...expenses.map((row) => dbRow('Expense', row)),
      ...splits.map((row) => dbRow('ExpenseSplit', row)),
      ...transactions.map((row) => dbRow('Transaction', row)),
    ]
    return { rows, registry, source: 'database' }
  } finally {
    await prisma.$disconnect()
  }
}

function decimalValue(value: unknown): { text: string; decimal: DecimalValue } | { text: string; decimal: null } {
  const text = stringOrNull(value) ?? ''
  if (text.length === 0) return { text, decimal: null }
  if (text.toLowerCase() === 'nan' || text.toLowerCase() === 'infinity' || text.toLowerCase() === '-infinity') {
    return { text, decimal: null }
  }

  const match = /^([+-]?)(\d+)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$/.exec(text)
  if (match === null) return { text, decimal: null }

  const sign = match[1] === '-'
  const whole = match[2]
  const fraction = match[3] ?? ''
  const scientificExponent = Number(match[4] ?? '0')
  if (!Number.isSafeInteger(scientificExponent)) return { text, decimal: null }

  const digits = `${whole}${fraction}`.replace(/^0+(?=\d)/, '') || '0'
  return {
    text,
    decimal: {
      digits,
      scale: fraction.length - scientificExponent,
      negative: sign && digits !== '0',
    },
  }
}

function minorUnitsFor(decimal: DecimalValue, exponent: number): bigint | null {
  if (!Number.isSafeInteger(exponent) || exponent < 0) return null
  const digits = BigInt(decimal.digits)
  const shift = exponent - decimal.scale
  let minorUnits: bigint
  if (shift >= 0) {
    minorUnits = digits * BigInt(10) ** BigInt(shift)
  } else {
    const divisor = BigInt(10) ** BigInt(-shift)
    if (digits % divisor !== BigInt(0)) return null
    minorUnits = digits / divisor
  }
  if (decimal.negative) minorUnits = -minorUnits
  return minorUnits >= MIN_BIGINT && minorUnits <= MAX_BIGINT ? minorUnits : null
}

function exactExponent(value: unknown): number | null {
  const text = stringOrNull(value)
  if (text === null || !/^-?\d+$/.test(text)) return null
  const exponent = Number(text)
  return Number.isSafeInteger(exponent) ? exponent : null
}

function exactMinor(value: unknown): bigint | null {
  const text = stringOrNull(value)
  if (text === null || !/^-?\d+$/.test(text)) return null
  try {
    const minor = BigInt(text)
    return minor >= MIN_BIGINT && minor <= MAX_BIGINT ? minor : null
  } catch {
    return null
  }
}

function classify(row: LegacyRow, registry: Registry): ClassifiedRow {
  const currencyCode = normalizeCode(row.currency)
  const amount = decimalValue(row.amount)
  const hasMinor = row.amountMinorUnits !== null && row.amountMinorUnits !== undefined
  const hasExponent = row.currencyExponent !== null && row.currencyExponent !== undefined
  const existingMinor = hasMinor ? exactMinor(row.amountMinorUnits) : null
  const existingExponent = hasExponent ? exactExponent(row.currencyExponent) : null
  const registryEntry = currencyCode === null ? null : registry.entries.get(currencyCode) ?? null
  const registryAmbiguous = currencyCode !== null && registry.ambiguousCodes.has(currencyCode)

  if (hasMinor !== hasExponent) {
    return {
      row,
      classification: 'quarantined',
      currencyCode,
      amountText: amount.text || null,
      minorUnits: null,
      currencyExponent: null,
      reason: 'PARTIAL_EXACT_FIELDS',
    }
  }

  if (hasMinor && hasExponent) {
    if (existingMinor === null || existingExponent === null) {
      return {
        row,
        classification: 'quarantined',
        currencyCode,
        amountText: amount.text || null,
        minorUnits: null,
        currencyExponent: null,
        reason: 'INVALID_EXACT_VALUE',
      }
    }
    if (registryAmbiguous || registryEntry === null || existingExponent !== registryEntry.exponent) {
      return {
        row,
        classification: 'quarantined',
        currencyCode,
        amountText: amount.text || null,
        minorUnits: existingMinor,
        currencyExponent: existingExponent,
        reason: registryAmbiguous ? 'AMBIGUOUS_CURRENCY_REGISTRY' : 'EXACT_EXPONENT_MISMATCH',
      }
    }
    return {
      row,
      classification: 'alreadyExact',
      currencyCode,
      amountText: amount.text || null,
      minorUnits: existingMinor,
      currencyExponent: existingExponent,
      reason: null,
    }
  }

  if (currencyCode === null || registryEntry === null) {
    return {
      row,
      classification: 'quarantined',
      currencyCode,
      amountText: amount.text || null,
      minorUnits: null,
      currencyExponent: null,
      reason: currencyCode === null ? 'INVALID_CURRENCY_CODE' : 'UNSUPPORTED_CURRENCY',
    }
  }
  if (registryAmbiguous) {
    return {
      row,
      classification: 'quarantined',
      currencyCode,
      amountText: amount.text || null,
      minorUnits: null,
      currencyExponent: null,
      reason: 'AMBIGUOUS_CURRENCY_REGISTRY',
    }
  }
  if (registryEntry.exponent < 0) {
    return {
      row,
      classification: 'quarantined',
      currencyCode,
      amountText: amount.text || null,
      minorUnits: null,
      currencyExponent: registryEntry.exponent,
      reason: 'INVALID_CURRENCY_EXPONENT',
    }
  }
  if (amount.decimal === null) {
    return {
      row,
      classification: 'quarantined',
      currencyCode,
      amountText: amount.text || null,
      minorUnits: null,
      currencyExponent: null,
      reason: 'INVALID_LEGACY_VALUE',
    }
  }

  const minorUnits = minorUnitsFor(amount.decimal, registryEntry.exponent)
  if (minorUnits === null) {
    const normalizedScale = amount.decimal.scale - registryEntry.exponent
    return {
      row,
      classification: 'quarantined',
      currencyCode,
      amountText: amount.text || null,
      minorUnits: null,
      currencyExponent: registryEntry.exponent,
      reason: normalizedScale > 0 ? 'AMBIGUOUS_LEGACY_VALUE' : 'OUT_OF_RANGE',
    }
  }
  return {
    row,
    classification: 'converted',
    currencyCode,
    amountText: amount.text || null,
    minorUnits,
    currencyExponent: registryEntry.exponent,
    reason: null,
  }
}

function checksum(results: ClassifiedRow[]): string {
  const lines = results
    .slice()
    .sort((a, b) => `${a.row.tableName}:${a.row.id}`.localeCompare(`${b.row.tableName}:${b.row.id}`))
    .map((result) => [
      result.row.tableName,
      result.row.id,
      result.currencyCode ?? '',
      result.amountText ?? '',
      result.row.amountMinorUnits === null || result.row.amountMinorUnits === undefined ? '' : String(result.row.amountMinorUnits),
      result.row.currencyExponent === null || result.row.currencyExponent === undefined ? '' : String(result.row.currencyExponent),
      result.classification,
      result.reason ?? '',
      result.minorUnits?.toString() ?? '',
      result.currencyExponent?.toString() ?? '',
    ].join('|'))
  return createHash('sha256').update(lines.join('\n')).digest('hex')
}

function inputChecksum(rows: LegacyRow[]): string {
  const lines = rows
    .slice()
    .sort((a, b) => `${a.tableName}:${a.id}`.localeCompare(`${b.tableName}:${b.id}`))
    .map((row) => [
      row.tableName,
      row.id,
      stringOrNull(row.amount) ?? '',
      stringOrNull(row.currency) ?? '',
      stringOrNull(row.groupId) ?? '',
      stringOrNull(row.amountMinorUnits) ?? '',
      stringOrNull(row.currencyExponent) ?? '',
    ].join('|'))
  return createHash('sha256').update(lines.join('\n')).digest('hex')
}

function reportFor(data: RehearsalData, mode: 'dry-run' | 'apply'): { report: RehearsalReport; results: ClassifiedRow[] } {
  const results = data.rows.map((row) => classify(row, data.registry))
  const converted = results.filter((result) => result.classification === 'converted')
  const alreadyExact = results.filter((result) => result.classification === 'alreadyExact')
  const quarantined = results.filter((result) => result.classification === 'quarantined')
  const report: RehearsalReport = {
    mode,
    source: data.source,
    registryEntries: data.registry.entries.size,
    records: results.length,
    counts: {
      converted: converted.length,
      alreadyExact: alreadyExact.length,
      quarantined: quarantined.length,
      unresolved: quarantined.length,
    },
    checksums: {
      input: inputChecksum(data.rows),
      all: checksum(results),
      converted: checksum(converted),
      alreadyExact: checksum(alreadyExact),
      quarantined: checksum(quarantined),
    },
    unresolvedRecords: quarantined.map((result) => ({
      tableName: result.row.tableName,
      recordId: result.row.id,
      currencyCode: result.currencyCode,
      amount: result.amountText,
      reason: result.reason ?? 'UNRESOLVED',
    })),
  }
  return { report, results }
}

function issueId(result: ClassifiedRow): string {
  const reason = result.reason ?? 'UNRESOLVED'
  return createHash('md5')
    .update(`money-migration:${result.row.tableName}:${result.row.id}:${reason}`)
    .digest('hex')
}

async function applyResults(results: ClassifiedRow[]): Promise<{ converted: number; quarantined: number }> {
  const { PrismaClient } = await import('@prisma/client')
  const prisma = new PrismaClient()
  let converted = 0
  let quarantined = 0
  try {
    await prisma.$transaction(async (tx) => {
      for (const result of results) {
        if (result.classification === 'converted') {
          const affected = await tx.$executeRawUnsafe(
            `UPDATE "${result.row.tableName}" SET "amountMinorUnits" = $1::bigint, "currencyExponent" = $2 WHERE "id" = $3 AND "amountMinorUnits" IS NULL AND "currencyExponent" IS NULL`,
            result.minorUnits?.toString(),
            result.currencyExponent,
            result.row.id
          )
          converted += affected
          continue
        }
        if (result.classification !== 'quarantined') continue

        const affected = await tx.$executeRawUnsafe(
          `INSERT INTO "MoneyMigrationIssue" ("id", "tableName", "recordId", "groupId", "currencyCode", "reason", "floatValue") VALUES ($1, $2, $3, $4, $5, $6, $7) ON CONFLICT ("id") DO NOTHING`,
          issueId(result),
          result.row.tableName,
          result.row.id,
          stringOrNull(result.row.groupId),
          result.currencyCode,
          result.reason ?? 'UNRESOLVED',
          result.amountText
        )
        quarantined += affected
      }
    })
    return { converted, quarantined }
  } finally {
    await prisma.$disconnect()
  }
}

function parseArgs(argv: string[]): { fixture: string | null; apply: boolean } {
  let fixture: string | null = null
  let apply = false
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--apply') {
      apply = true
    } else if (argument === '--fixture') {
      const next = argv[index + 1]
      if (next === undefined || next.startsWith('--')) throw new Error('--fixture requires a path')
      fixture = next
      index += 1
    } else if (argument === '--dry-run') {
      apply = false
    } else if (argument === '--help' || argument === '-h') {
      console.log('Usage: ledger-money-rehearsal.ts [--fixture PATH] [--apply]')
      console.log('The default mode is dry-run. --apply is required to write exact values or quarantine issues.')
      process.exit(0)
    } else {
      throw new Error(`Unknown argument: ${argument}`)
    }
  }
  return { fixture, apply }
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2))
  const data = args.fixture === null ? await loadDatabase() : loadFixture(args.fixture)
  const { report, results } = reportFor(data, args.apply ? 'apply' : 'dry-run')
  if (args.apply) report.applied = await applyResults(results)
  console.log(JSON.stringify(report, null, 2))
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error)
  console.error(`ledger-money-rehearsal failed: ${message}`)
  process.exitCode = 1
})
