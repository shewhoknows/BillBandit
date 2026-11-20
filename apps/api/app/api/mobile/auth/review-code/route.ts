import { createHash, timingSafeEqual } from 'node:crypto'
import { isIP } from 'node:net'
import { NextRequest, NextResponse } from 'next/server'
import { prisma } from '@/lib/prisma'
import { createMobileToken } from '@/lib/mobile-auth'
import { mobileUser } from '@/lib/mobile-dto'
import { REVIEW_ACCOUNT_EMAIL, REVIEW_ACCOUNT_ID, reviewCodeEnabled } from '@/lib/review-account'

export const dynamic = 'force-dynamic'

const windowMs = 15 * 60 * 1000
const failureLimit = 10

export async function GET() {
  return NextResponse.json({ enabled: reviewCodeEnabled() }, { headers: { 'Cache-Control': 'no-store' } })
}

export async function POST(req: NextRequest) {
  const expected = process.env.BILLBANDIT_REVIEW_CODE
  if (!expected || !reviewCodeEnabled()) return NextResponse.json({ error: 'Not found' }, { status: 404 })

  let body: unknown
  try { body = await req.json() } catch { body = null }
  const code = body && typeof body === 'object' && 'code' in body && typeof body.code === 'string'
    ? body.code : ''
  const ip = req.headers.get('x-real-ip')?.trim() ?? ''
  const key = createHash('sha256').update(isIP(ip) ? ip : 'unknown').digest('hex')
  const matches = timingSafeEqual(
    createHash('sha256').update(code).digest(),
    createHash('sha256').update(expected).digest(),
  )

  try {
    const outcome = await prisma.$transaction(async (tx) => {
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${key}))`
      const now = new Date()
      const previous = await tx.reviewCodeRateLimit.findUnique({ where: { key } })
      if (previous?.blockedUntil && previous.blockedUntil > now) return { status: 'blocked' as const }
      if (!matches) {
        const count = previous && now.getTime() - previous.windowStartedAt.getTime() < windowMs
          ? previous.failureCount + 1 : 1
        const started = count === 1 ? now : previous!.windowStartedAt
        await tx.reviewCodeRateLimit.upsert({
          where: { key },
          create: { key, windowStartedAt: started, failureCount: count, blockedUntil: count >= failureLimit ? new Date(now.getTime() + windowMs) : null },
          update: { windowStartedAt: started, failureCount: count, blockedUntil: count >= failureLimit ? new Date(now.getTime() + windowMs) : null },
        })
        return { status: 'failure' as const }
      }
      const user = await tx.user.findUnique({ where: { id: REVIEW_ACCOUNT_ID } })
      if (!user || user.email !== REVIEW_ACCOUNT_EMAIL || user.deletedAt) return { status: 'unavailable' as const }
      await tx.reviewCodeRateLimit.deleteMany({ where: { key } })
      return { status: 'success' as const, user }
    })
    console.info(`[MOBILE REVIEW AUTH] ${outcome.status}`)
    if (outcome.status === 'success') {
      return NextResponse.json({ token: createMobileToken(outcome.user), user: mobileUser(outcome.user) })
    }
    return NextResponse.json({ error: 'That code did not work.' }, { status: outcome.status === 'blocked' ? 429 : 401 })
  } catch {
    console.error('[MOBILE REVIEW AUTH] error')
    return NextResponse.json({ error: 'That code did not work.' }, { status: 503 })
  }
}
