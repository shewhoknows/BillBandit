import { NextRequest, NextResponse } from 'next/server'
import crypto from 'crypto'
import { prisma } from '@/lib/prisma'

const TOKEN_TTL_SECONDS = 30 * 24 * 60 * 60

type MobileTokenPayload = {
  sub: string
  email: string
  name?: string | null
  iat: number
  exp: number
}

export type MobileSession = {
  user: {
    id: string
    username: string | null
    email: string
    name: string | null
    image: string | null
    phone: string | null
    preferredName: string | null
    upiID: string | null
  }
}

function base64Url(input: Buffer | string) {
  return Buffer.from(input)
    .toString('base64')
    .replace(/=/g, '')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
}

function decodeBase64Url(input: string) {
  const normalized = input.replace(/-/g, '+').replace(/_/g, '/')
  return Buffer.from(normalized, 'base64').toString('utf8')
}

function getSecret() {
  const secret = process.env.MOBILE_JWT_SECRET ?? process.env.NEXTAUTH_SECRET
  if (!secret) {
    throw new Error('MOBILE_JWT_SECRET or NEXTAUTH_SECRET must be set')
  }
  return secret
}

function sign(unsignedToken: string) {
  return base64Url(
    crypto.createHmac('sha256', getSecret()).update(unsignedToken).digest()
  )
}

function timingSafeEqual(a: string, b: string) {
  const left = Buffer.from(a)
  const right = Buffer.from(b)
  return left.length === right.length && crypto.timingSafeEqual(left, right)
}

export function createMobileToken(user: {
  id: string
  email: string
  name: string | null
}) {
  const now = Math.floor(Date.now() / 1000)
  const header = base64Url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }))
  const payload: MobileTokenPayload = {
    sub: user.id,
    email: user.email,
    name: user.name,
    iat: now,
    exp: now + TOKEN_TTL_SECONDS,
  }
  const encodedPayload = base64Url(JSON.stringify(payload))
  const unsignedToken = `${header}.${encodedPayload}`
  return `${unsignedToken}.${sign(unsignedToken)}`
}

export function verifyMobileToken(token: string): MobileTokenPayload | null {
  const parts = token.split('.')
  if (parts.length !== 3) return null

  const [header, payload, signature] = parts
  const expected = sign(`${header}.${payload}`)
  if (!timingSafeEqual(signature, expected)) return null

  try {
    const decoded = JSON.parse(decodeBase64Url(payload)) as MobileTokenPayload
    if (!decoded.sub || !decoded.email || !decoded.exp) return null
    if (decoded.exp < Math.floor(Date.now() / 1000)) return null
    return decoded
  } catch {
    return null
  }
}

export async function getMobileSession(req: NextRequest): Promise<MobileSession | null> {
  const auth = req.headers.get('authorization') ?? ''
  const match = auth.match(/^Bearer\s+(.+)$/i)
  if (!match) return null

  const payload = verifyMobileToken(match[1])
  if (!payload) return null

  const user = await prisma.user.findUnique({
    where: { id: payload.sub },
    select: {
      id: true,
      username: true,
      email: true,
      name: true,
      image: true,
      phone: true,
      preferredName: true,
      upiID: true,
      deletedAt: true,
    },
  })

  if (!user || user.deletedAt) return null
  const { deletedAt: _deletedAt, ...activeUser } = user
  return { user: activeUser }
}

export async function requireMobileSession(req: NextRequest) {
  const session = await getMobileSession(req)
  if (!session) {
    return {
      session: null,
      response: NextResponse.json({ error: 'Unauthorized' }, { status: 401 }),
    }
  }
  return { session, response: null }
}
