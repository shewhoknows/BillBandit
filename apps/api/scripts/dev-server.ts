/**
 * Start the API on this computer for day-to-day testing.
 *
 *   npm run dev:server            (from apps/api, or `npm run dev:server` at the repo root)
 *
 * It brings the local database up to the newest schema, then runs `next dev`
 * on port 3000, which is where Debug builds of the app look by default.
 * It never deletes data.
 */
import { execFileSync, spawn } from 'node:child_process'
import { resolve } from 'node:path'
import { apiRoot, assertLocalOnly, devApiBase, devServerEnv } from './support/dev-env'

assertLocalOnly()
const env = devServerEnv()
const port = new URL(devApiBase).port || '3000'
const prisma = resolve(apiRoot, '../../node_modules/.bin/prisma')

console.log('Applying database migrations to the local database...')
execFileSync(prisma, ['migrate', 'deploy', '--schema', resolve(apiRoot, 'prisma/schema.prisma')], {
  cwd: apiRoot,
  env,
  stdio: 'inherit',
})

console.log(`Starting the API at ${devApiBase}`)
const server = spawn(resolve(apiRoot, '../../node_modules/.bin/next'), ['dev', '-p', port, '-H', '127.0.0.1'], {
  cwd: apiRoot,
  env,
  stdio: 'inherit',
})
server.on('exit', (code) => process.exit(code ?? 0))
process.on('SIGINT', () => server.kill('SIGINT'))
