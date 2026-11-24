import { NextRequest, NextResponse } from 'next/server'
import { requireMobileSession } from '@/lib/mobile-auth'
import {
  cloudKitImportErrorBody,
  cloudKitImportErrorStatus,
  linkCloudKitIdentityForAccount,
} from '@/lib/migrations/cloudkit'

const noStoreHeaders = {
  'Cache-Control': 'no-store',
  Pragma: 'no-cache',
}

/**
 * POST { cloudKitRecordName } links the signed-in account to its own CloudKit
 * user record name. 200 linked / already_linked; 409 identity_conflict when
 * either side is already linked elsewhere (never moved).
 */
export async function POST(req: NextRequest) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response
  let body: unknown
  try {
    body = await req.json()
  } catch {
    return NextResponse.json(
      { error: 'A JSON body with cloudKitRecordName is required.' },
      { status: 400, headers: noStoreHeaders },
    )
  }
  const cloudKitRecordName =
    body && typeof body === 'object' && !Array.isArray(body)
      ? (body as { cloudKitRecordName?: unknown }).cloudKitRecordName
      : undefined
  try {
    const result = await linkCloudKitIdentityForAccount({
      accountId: session.user.id,
      cloudKitRecordName,
    })
    return NextResponse.json(result, { headers: noStoreHeaders })
  } catch (error) {
    if (cloudKitImportErrorStatus(error) === 500)
      console.error('[POST /api/mobile/migrations/cloudkit/identity]', error)
    return NextResponse.json(cloudKitImportErrorBody(error), {
      status: cloudKitImportErrorStatus(error),
      headers: noStoreHeaders,
    })
  }
}
