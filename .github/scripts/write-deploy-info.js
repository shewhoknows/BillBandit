const fs = require('node:fs')
const path = require('node:path')

const commit = process.env.GITHUB_SHA

if (!commit) {
  console.error('GITHUB_SHA is required to write deploy metadata.')
  process.exit(1)
}

const deployInfo = {
  commit,
  shortCommit: commit.slice(0, 7),
  branch: process.env.GITHUB_REF_NAME || null,
  builtAt: new Date().toISOString(),
  runId: process.env.GITHUB_RUN_ID || null,
  runAttempt: process.env.GITHUB_RUN_ATTEMPT || null,
  workflow: process.env.GITHUB_WORKFLOW || null,
}

const publicDir = path.join(process.cwd(), 'apps', 'api', 'public')
fs.mkdirSync(publicDir, { recursive: true })
fs.writeFileSync(
  path.join(publicDir, 'deploy-info.json'),
  `${JSON.stringify(deployInfo, null, 2)}\n`
)

console.log(`Wrote apps/api/public/deploy-info.json for ${deployInfo.shortCommit}.`)
