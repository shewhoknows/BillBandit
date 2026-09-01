import { NextRequest } from 'next/server'
import { requireMobileSession } from '@/lib/mobile-auth'

/** Mobile Bearer session only — no NextAuth web fallback. */
export async function requireSettlementUserId(req: NextRequest) {
  const { session, response } = await requireMobileSession(req)
  if (response) return { userId: null, response }
  return { userId: session.user.id, response: null }
}
