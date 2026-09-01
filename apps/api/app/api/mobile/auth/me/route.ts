import { NextRequest, NextResponse } from 'next/server'
import { requireMobileSession } from '@/lib/mobile-auth'
import { mobileUser } from '@/lib/mobile-dto'
import { deleteMobileAccount } from '@/lib/account-deletion'

export async function GET(req: NextRequest) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response
  return NextResponse.json({ user: mobileUser(session.user) })
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
