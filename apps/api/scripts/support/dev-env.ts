/**
 * Shared settings for the local development server and the dev-data tool.
 *
 * Both sides must use the same database and the same token secret, so a
 * token made by `dev-data` is accepted by `dev-server`. These values are for
 * this computer only. The live server has its own secret and database.
 */
import { existsSync, readFileSync } from 'node:fs'
import { userInfo } from 'node:os'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

export const apiRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..')

/** Read `apps/api/.env.local` (gitignored) so a person can change the defaults. */
function loadEnvLocal() {
  const path = resolve(apiRoot, '.env.local')
  if (!existsSync(path)) return
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const match = line.match(/^\s*([A-Z0-9_]+)\s*=\s*"?(.*?)"?\s*$/)
    if (match && process.env[match[1]] === undefined) process.env[match[1]] = match[2]
  }
}
loadEnvLocal()

export const devDatabaseUrl =
  process.env.DEV_DATABASE_URL?.trim() || `postgresql://${userInfo().username}@localhost:5432/billbandit`
export const devApiBase = process.env.DEV_API_BASE?.trim() || 'http://127.0.0.1:3000'
export const devJwtSecret =
  process.env.DEV_MOBILE_JWT_SECRET?.trim() || 'billbandit-local-dev-only-secret-not-for-production'

const loopback = new Set(['localhost', '127.0.0.1', '::1', '[::1]'])

/** Refuse anything that is not on this computer. This tool must never touch live data. */
export function assertLocalOnly() {
  const db = new URL(devDatabaseUrl)
  if (!loopback.has(db.hostname.toLowerCase())) {
    throw new Error(`Refusing to run: the database host "${db.hostname}" is not this computer.`)
  }
  const api = new URL(devApiBase)
  if (!loopback.has(api.hostname.toLowerCase())) {
    throw new Error(`Refusing to run: the API host "${api.hostname}" is not this computer.`)
  }
}

/** Environment for the local Next.js server (and for minting tokens it accepts). */
export function devServerEnv(): NodeJS.ProcessEnv {
  return {
    ...process.env,
    NODE_ENV: 'development',
    DATABASE_URL: devDatabaseUrl,
    MOBILE_JWT_SECRET: devJwtSecret,
    NEXTAUTH_SECRET: devJwtSecret,
    // Lets the real Apple sign-in route be tried locally. Off on the live server.
    MOBILE_AUTH_MOCK_APPLE_SUBJECT: process.env.MOBILE_AUTH_MOCK_APPLE_SUBJECT ?? 'dev-apple-you',
    MOBILE_AUTH_MOCK_APPLE_TOKEN: process.env.MOBILE_AUTH_MOCK_APPLE_TOKEN ?? 'dev-apple-identity-token-local-only',
    MOBILE_AUTH_MOCK_APPLE_EMAIL: process.env.MOBILE_AUTH_MOCK_APPLE_EMAIL ?? 'you@dev.billbandit.local',
  }
}
