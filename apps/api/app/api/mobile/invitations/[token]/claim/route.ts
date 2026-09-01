import { NextRequest } from 'next/server'
import { claimInvitationResponse } from '@/lib/identity/mobile-routes'

export async function POST(
  req: NextRequest,
  { params }: { params: { token: string } }
) {
  return claimInvitationResponse(req, params.token)
}
