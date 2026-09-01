const { setTimeout: sleep } = require('node:timers/promises')

const baseUrl = process.env.TEST_URL?.replace(/\/$/, '')
const expectedSha = process.env.EXPECTED_SHA || process.env.GITHUB_SHA
const attempts = Number(process.env.DEPLOY_VERIFY_ATTEMPTS || 60)
const intervalMs = Number(process.env.DEPLOY_VERIFY_INTERVAL_MS || 15000)

if (!baseUrl) {
  console.error('TEST_URL is required to verify the deployment.')
  process.exit(1)
}

if (!expectedSha) {
  console.error('EXPECTED_SHA or GITHUB_SHA is required to verify the deployment.')
  process.exit(1)
}

async function readHealth(attempt) {
  const url = new URL('/api/health', baseUrl)
  url.searchParams.set('expected', expectedSha)
  url.searchParams.set('attempt', String(attempt))
  url.searchParams.set('t', String(Date.now()))

  const response = await fetch(url, { cache: 'no-store' })
  const text = await response.text()

  try {
    return {
      ok: response.ok,
      status: response.status,
      body: JSON.parse(text),
    }
  } catch {
    return {
      ok: response.ok,
      status: response.status,
      body: null,
      text: text.slice(0, 160),
    }
  }
}

async function main() {
  const expectedShort = expectedSha.slice(0, 12)

  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const health = await readHealth(attempt)
      const deployedCommit = health.body?.commit || null
      const deployedShort = deployedCommit?.slice(0, 12) || 'missing'

      if (health.ok && deployedCommit === expectedSha) {
        console.log(`Production is serving ${expectedShort} after ${attempt} attempt(s).`)
        return
      }

      console.log(
        `Attempt ${attempt}/${attempts}: HTTP ${health.status}; deployed commit ${deployedShort}; expected ${expectedShort}.`
      )
    } catch (error) {
      console.log(
        `Attempt ${attempt}/${attempts}: ${error instanceof Error ? error.message : String(error)}.`
      )
    }

    if (attempt < attempts) {
      await sleep(intervalMs)
    }
  }

  console.error(`Production did not serve ${expectedShort} within the verification window.`)
  process.exit(1)
}

main()
