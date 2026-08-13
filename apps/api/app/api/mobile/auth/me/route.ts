import { NextRequest, NextResponse } from 'next/server'
import { requireMobileSession } from '@/lib/mobile-auth'
import { mobileUser } from '@/lib/mobile-dto'
import { deleteMobileAccount } from '@/lib/account-deletion'
import { prisma } from '@/lib/prisma'
import {
  mobileProfileAvatarImage,
  parseMobileProfileAvatar,
} from '@/lib/profile-avatar'

export async function GET(req: NextRequest) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response
  return NextResponse.json({ user: mobileUser(session.user) })
}

export async function PATCH(req: NextRequest) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  let body: unknown
  try {
    body = await req.json()
  } catch {
    return NextResponse.json({ error: 'A JSON object is required' }, { status: 400 })
  }
  const avatar = parseMobileProfileAvatar(
    body && typeof body === 'object' && !Array.isArray(body)
      ? (body as Record<string, unknown>).avatar
      : null
  )
  if (!avatar) {
    return NextResponse.json({ error: 'Choose a valid BillBandit avatar' }, { status: 400 })
  }

  const user = await prisma.user.update({
    where: { id: session.user.id },
    data: { image: mobileProfileAvatarImage(avatar) },
  })
  return NextResponse.json({ user: mobileUser(user) })
}

export async function DELETE(req: NextRequest) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  try {
    const result = await deleteMobileAccount(session.user.id)
    if (result.status === 'not_found') {
      return NextResponse.json({ error: 'Account not found' }, { status: 404 })
    }
    return NextResponse.json({ deleted: true })
  } catch (error) {
    console.error('[MOBILE ACCOUNT DELETE]', error)
    return NextResponse.json({ error: 'Could not delete your account' }, { status: 500 })
  }
}
