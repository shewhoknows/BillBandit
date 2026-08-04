import { NextRequest, NextResponse } from 'next/server'
import { requireMobileSession } from '@/lib/mobile-auth'
import {
  cloudKitImportErrorBody,
  cloudKitImportErrorStatus,
  importCloudKitLedger,
  listCloudKitImports,
} from '@/lib/migrations/cloudkit'

const noStoreHeaders = {
  'Cache-Control': 'no-store',
  Pragma: 'no-cache',
}
async function requestBody(req: NextRequest): Promise<unknown> {
  try {
    return await req.json()
  } catch {
    throw new Error('A JSON CloudKit export envelope is required.')
  }
}

function resultStatus(status: string): number {
  if (status === 'completed') return 200
  if (status === 'needs-repair') return 409
  return 202
}

export async function GET(req: NextRequest) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response
  try {
    const imports = await listCloudKitImports({ accountId: session.user.id })
    return NextResponse.json({ imports }, { headers: noStoreHeaders })
  } catch (error) {
    console.error('[GET /api/mobile/migrations/cloudkit]', error)
    return NextResponse.json(cloudKitImportErrorBody(error), {
      status: cloudKitImportErrorStatus(error),
      headers: noStoreHeaders,
    })
  }
}

export async function POST(req: NextRequest) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response
  try {
    const body = await requestBody(req)
    const envelope = body && typeof body === 'object' && !Array.isArray(body) && 'export' in body
      ? (body as { export: unknown }).export
      : body
    const result = await importCloudKitLedger({ accountId: session.user.id, export: envelope })
    return NextResponse.json(result, { status: resultStatus(result.status), headers: noStoreHeaders })
  } catch (error) {
    const status = error instanceof Error && error.message === 'A JSON CloudKit export envelope is required.' ? 400 : cloudKitImportErrorStatus(error)
    return NextResponse.json(status === 400 && error instanceof Error && !(error as { code?: unknown }).code
      ? { error: error.message }
      : cloudKitImportErrorBody(error), { status, headers: noStoreHeaders })
  }
}
