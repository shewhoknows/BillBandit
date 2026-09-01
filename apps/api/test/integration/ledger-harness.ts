import { randomBytes } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { PrismaClient } from '@prisma/client'

const apiRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const repositoryRoot = resolve(apiRoot, '../..')

const productionLike = /(?:^|[._-])(prod|production|primary|main|live|staging)(?:$|[._-])/i
const hostedProduction = /(?:supabase|neon\.tech|amazonaws|rds\.|heroku|render\.com|railway\.app)/i
const testMarker = /(?:^|[._-])(test|testing|ci|dev|development|local|sandbox)(?:$|[._-])/i

export type LedgerTestDatabase = {
  db: PrismaClient
  url: string
  schema: string
  close: () => Promise<void>
}

function databaseName(url: URL): string {
  return decodeURIComponent(url.pathname.replace(/^\//, ''))
}

export function requireTestDatabaseUrl(): string {
  const raw = process.env.TEST_DATABASE_URL?.trim()
  if (!raw) {
    throw new Error(
      'Ledger tests require TEST_DATABASE_URL pointing at a disposable PostgreSQL test database.'
    )
  }

  let parsed: URL
  try {
    parsed = new URL(raw)
  } catch {
    throw new Error('TEST_DATABASE_URL must be a valid PostgreSQL URL.')
  }

  if (parsed.protocol !== 'postgres:' && parsed.protocol !== 'postgresql:') {
    throw new Error('TEST_DATABASE_URL must use the postgres:// or postgresql:// scheme.')
  }
  if (!parsed.hostname || !databaseName(parsed)) {
    throw new Error('TEST_DATABASE_URL must include a PostgreSQL host and database name.')
  }

  const host = parsed.hostname.toLowerCase()
  const schema = parsed.searchParams.get('schema')?.toLowerCase() ?? ''
  const database = databaseName(parsed).toLowerCase()
  if (productionLike.test(host) || productionLike.test(database) || productionLike.test(schema)) {
    throw new Error('Refusing TEST_DATABASE_URL because it looks production-like.')
  }
  if (hostedProduction.test(host)) {
    throw new Error('Refusing TEST_DATABASE_URL for a hosted production-like PostgreSQL service.')
  }

  const localHost = host === 'localhost' || host === '127.0.0.1' || host === '::1'
  if (!localHost && !testMarker.test(host) && !testMarker.test(database) && !testMarker.test(schema)) {
    throw new Error(
      'Refusing TEST_DATABASE_URL without a local host or an explicit test/CI database marker.'
    )
  }
  if (process.env.DATABASE_URL?.trim() === raw) {
    throw new Error('TEST_DATABASE_URL must not be the same value as DATABASE_URL.')
  }

  return raw
}

function withSchema(raw: string, schema: string): string {
  const url = new URL(raw)
  url.searchParams.set('schema', schema)
  return url.toString()
}

function prismaBinary(): string {
  const candidates = [
    join(apiRoot, 'node_modules/.bin/prisma'),
    join(repositoryRoot, 'node_modules/.bin/prisma'),
  ]
  const binary = candidates.find((candidate) => existsSync(candidate))
  if (!binary) {
    throw new Error('Prisma CLI is unavailable; install the workspace dependencies before running ledger tests.')
  }
  return binary
}

function provisionSchema(url: string): void {
  try {
    execFileSync(
      prismaBinary(),
      ['db', 'push', '--skip-generate', '--schema', join(apiRoot, 'prisma/schema.prisma')],
      {
        cwd: apiRoot,
        env: { ...process.env, DATABASE_URL: url },
        stdio: ['ignore', 'pipe', 'pipe'],
      }
    )
  } catch (error) {
    const output = error && typeof error === 'object'
      ? [
          (error as { stdout?: unknown }).stdout,
          (error as { stderr?: unknown }).stderr,
        ].filter(Boolean).map(String).join('\n')
      : ''
    const message = error instanceof Error ? error.message : String(error)
    throw new Error(`Ledger test schema provisioning failed: ${message}.${output ? `\n${output}` : ''}`)
  }
}

/**
 * Create one uniquely named schema, provision it from the checked-in Prisma schema, and
 * return a Prisma client scoped to that schema. The database itself is never
 * dropped; teardown can only remove the generated schema.
 */
export async function createLedgerTestDatabase(): Promise<LedgerTestDatabase> {
  const raw = requireTestDatabaseUrl()
  const schema = `ledger_test_${process.pid}_${randomBytes(6).toString('hex')}`
  const adminUrl = withSchema(raw, 'public')
  const isolatedUrl = withSchema(raw, schema)
  const previousDatabaseUrl = process.env.DATABASE_URL
  const admin = new PrismaClient({ datasources: { db: { url: adminUrl } } })
  let db: PrismaClient | null = null

  try {
    await admin.$connect()
    await admin.$executeRawUnsafe(`CREATE SCHEMA IF NOT EXISTS "${schema}"`)
    provisionSchema(isolatedUrl)
    db = new PrismaClient({ datasources: { db: { url: isolatedUrl } } })
    await db.$connect()
    process.env.DATABASE_URL = isolatedUrl

    let closed = false
    return {
      db,
      url: isolatedUrl,
      schema,
      close: async () => {
        if (closed) return
        closed = true
        await db!.$disconnect()
        await admin.$executeRawUnsafe(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`)
        await admin.$disconnect()
        if (previousDatabaseUrl === undefined) delete process.env.DATABASE_URL
        else process.env.DATABASE_URL = previousDatabaseUrl
      },
    }
  } catch (error) {
    await db?.$disconnect().catch(() => undefined)
    await admin.$executeRawUnsafe(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`).catch(() => undefined)
    await admin.$disconnect().catch(() => undefined)
    throw error
  }
}
