import { NextRequest, NextResponse } from 'next/server'
import { requireMobileSession } from '@/lib/mobile-auth'
import {
  cloudKitImportErrorBody,
  cloudKitImportErrorStatus,
  getCloudKitImport,
  resumeCloudKitImport,
} from '@/lib/migrations/cloudkit'

const noStoreHeaders = {
  'Cache-Control': 'no-store',
  Pragma: 'no-cache',
}
function resultStatus(status: string): number {
  if (status === 'completed') return 200
  if (status === 'needs-repair') return 409
  return 202
}

async function optionalBody(req: NextRequest): Promise<unknown | undefined> {
  const text = await req.text()
  if (!text.trim()) return undefined
  try {
    return JSON.parse(text) as unknown
  } catch {
    throw new Error('A JSON CloudKit export envelope is required.')
  }
}

function envelopeFromBody(body: unknown): unknown {
  if (body && typeof body === 'object' && !Array.isArray(body) && 'export' in body) {
    return (body as { export: unknown }).export
  }
  return body
}

export async function GET(req: NextRequest, { params }: { params: { id: string } }) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response
  try {
    const result = await getCloudKitImport({ accountId: session.user.id, importId: params.id })
    return NextResponse.json(result, { status: resultStatus(result.status), headers: noStoreHeaders })
  } catch (error) {
    return NextResponse.json(cloudKitImportErrorBody(error), {
      status: cloudKitImportErrorStatus(error),
      headers: noStoreHeaders,
    })
  }
}

export async function POST(req: NextRequest, { params }: { params: { id: string } }) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response
  try {
    const body = envelopeFromBody(await optionalBody(req))
    const result = await resumeCloudKitImport({ accountId: session.user.id, importId: params.id, export: body })
    return NextResponse.json(result, { status: resultStatus(result.status), headers: noStoreHeaders })
  } catch (error) {
    const status = error instanceof Error && error.message === 'A JSON CloudKit export envelope is required.' ? 400 : cloudKitImportErrorStatus(error)
    return NextResponse.json(status === 400 && error instanceof Error && !(error as { code?: unknown }).code
      ? { error: error.message }
      : cloudKitImportErrorBody(error), { status, headers: noStoreHeaders })
  }
}
