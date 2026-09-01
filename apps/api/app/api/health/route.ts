import { NextResponse } from 'next/server'
import { readFileSync } from 'node:fs'
import path from 'node:path'

export const dynamic = 'force-dynamic'
export const revalidate = 0
export const runtime = 'nodejs'

type DeployInfo = {
  commit?: string
  shortCommit?: string
  branch?: string | null
  builtAt?: string
  runId?: string | null
  runAttempt?: string | null
  workflow?: string | null
}

const noStoreHeaders = {
  'Cache-Control': 'no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0, s-maxage=0',
  Pragma: 'no-cache',
  Expires: '0',
  'Surrogate-Control': 'no-store',
}

function readDeployInfo(): DeployInfo {
  try {
    const deployInfoPath = path.join(process.cwd(), 'public', 'deploy-info.json')
    return JSON.parse(readFileSync(deployInfoPath, 'utf8')) as DeployInfo
  } catch {
    return {}
  }
}

export async function GET() {
  const deployInfo = readDeployInfo()

  return NextResponse.json(
    {
      status: 'ok',
      timestamp: new Date().toISOString(),
      commit: deployInfo.commit ?? process.env.RAILWAY_GIT_COMMIT_SHA ?? null,
      shortCommit:
        deployInfo.shortCommit ??
        process.env.RAILWAY_GIT_COMMIT_SHA?.slice(0, 7) ??
        null,
      branch: deployInfo.branch ?? process.env.RAILWAY_GIT_BRANCH ?? null,
      builtAt: deployInfo.builtAt ?? null,
      runId: deployInfo.runId ?? null,
      runAttempt: deployInfo.runAttempt ?? null,
      workflow: deployInfo.workflow ?? null,
      railway: {
        environment: process.env.RAILWAY_ENVIRONMENT_NAME ?? null,
        service: process.env.RAILWAY_SERVICE_NAME ?? null,
      },
    },
    {
      headers: noStoreHeaders,
    }
  )
}
