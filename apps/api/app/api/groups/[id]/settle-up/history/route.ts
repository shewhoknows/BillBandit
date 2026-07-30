import { NextRequest, NextResponse } from 'next/server'
import { requireSettlementUserId } from '@/lib/settlement/route-auth'
import { loadSettledPage } from '@/lib/settlement/read/sync'
import { resolveCallerAccess } from '@/lib/settlement/commands/core'
import { derivePermissions } from '@/lib/settlement/access/matrix'
import { prisma } from '@/lib/prisma'

export async function GET(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const { userId, response } = await requireSettlementUserId(req)
  if (response) return response

  const cursor = req.nextUrl.searchParams.get('cursor')
  const access = await resolveCallerAccess(params.id, userId!, prisma)
  const permissions = derivePermissions(access)
  if (!permissions.canReadHistory) {
    return NextResponse.json({ error: 'Forbidden' }, { status: 403 })
  }

  const page = await loadSettledPage(params.id, access, cursor)
  return NextResponse.json(page)
}
