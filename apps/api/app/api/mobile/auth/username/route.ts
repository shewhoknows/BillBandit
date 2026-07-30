import { Prisma } from '@prisma/client'
import { NextRequest, NextResponse } from 'next/server'
import { prisma } from '@/lib/prisma'
import { requireMobileSession } from '@/lib/mobile-auth'
import { mobileUser } from '@/lib/mobile-dto'
import { parseUsernameHandle } from '@/lib/username-handle'

const userSelect = {
  id: true,
  username: true,
  name: true,
  email: true,
  image: true,
  phone: true,
  preferredName: true,
  upiID: true,
}

export async function GET(req: NextRequest) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  const parsed = parseUsernameHandle(new URL(req.url).searchParams.get('username') ?? '')
  if (!parsed.success) {
    return NextResponse.json({ available: false, error: parsed.error }, { status: 400 })
  }

  const owner = await prisma.user.findUnique({
    where: { username: parsed.username },
    select: { id: true },
  })
  return NextResponse.json({
    username: parsed.username,
    available: owner === null || owner.id === session.user.id,
  })
}

// Initial onboarding claim. Repeating the same claim is idempotent; changing an
// existing handle must use PUT, which the iOS client exposes only from Profile.
export async function POST(req: NextRequest) {
  const auth = await requireMobileSession(req)
  if (!auth.session) return auth.response

  const parsed = await requestedUsername(req)
  if (parsed instanceof NextResponse) return parsed

  const existing = await prisma.user.findUnique({
    where: { id: auth.session.user.id },
    select: { username: true },
  })
  if (existing?.username) {
    if (existing.username !== parsed) {
      return NextResponse.json(
        {
          code: 'username_already_claimed',
          error: `Your account already uses @${existing.username}. Change it from Profile.`,
          username: existing.username,
        },
        { status: 409 }
      )
    }
    return userResponse(auth.session.user.id)
  }

  try {
    const claimed = await prisma.user.updateMany({
      where: { id: auth.session.user.id, username: null },
      data: { username: parsed },
    })
    if (claimed.count === 0) {
      return NextResponse.json(
        { code: 'username_already_claimed', error: 'Username was already claimed.' },
        { status: 409 }
      )
    }
    return userResponse(auth.session.user.id)
  } catch (error) {
    return usernameWriteError(error)
  }
}

// Profile-only rename path. PostgreSQL's unique index is the final atomic guard
// against two accounts claiming the same normalized handle concurrently.
export async function PUT(req: NextRequest) {
  const auth = await requireMobileSession(req)
  if (!auth.session) return auth.response

  const parsed = await requestedUsername(req)
  if (parsed instanceof NextResponse) return parsed

  try {
    await prisma.user.update({
      where: { id: auth.session.user.id },
      data: { username: parsed },
    })
    return userResponse(auth.session.user.id)
  } catch (error) {
    return usernameWriteError(error)
  }
}

async function requestedUsername(req: NextRequest) {
  let body: unknown
  try {
    body = await req.json()
  } catch {
    return NextResponse.json({ error: 'Username is required.' }, { status: 400 })
  }

  const raw = typeof body === 'object' && body !== null && 'username' in body
    ? (body as { username?: unknown }).username
    : undefined
  if (typeof raw !== 'string') {
    return NextResponse.json({ error: 'Username is required.' }, { status: 400 })
  }

  const parsed = parseUsernameHandle(raw)
  if (!parsed.success) {
    return NextResponse.json({ error: parsed.error }, { status: 400 })
  }
  return parsed.username
}

async function userResponse(userId: string) {
  const user = await prisma.user.findUniqueOrThrow({
    where: { id: userId },
    select: userSelect,
  })
  return NextResponse.json({ user: mobileUser(user) })
}

function usernameWriteError(error: unknown) {
  if (error instanceof Prisma.PrismaClientKnownRequestError && error.code === 'P2002') {
    return NextResponse.json(
      { code: 'username_taken', error: 'That username is already taken.' },
      { status: 409 }
    )
  }
  console.error('[MOBILE USERNAME]', error)
  return NextResponse.json({ error: 'Could not save username.' }, { status: 500 })
}
