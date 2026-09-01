import { NextRequest, NextResponse } from 'next/server'
import { prisma } from '@/lib/prisma'
import { appleSignInSchema } from '@/lib/validations-mobile-auth'
import { createMobileToken } from '@/lib/mobile-auth'
import { mobileUser } from '@/lib/mobile-dto'
import { syntheticEmailForAppleSubject } from '@/lib/mobile-auth-identifiers'
import { verifyAppleIdentityToken } from '@/lib/apple-id-token'

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

export async function POST(req: NextRequest) {
  try {
    const body = await req.json()
    const parsed = appleSignInSchema.safeParse(body)
    if (!parsed.success) {
      return NextResponse.json({ error: parsed.error.errors[0].message }, { status: 400 })
    }

    const identity = await verifyAppleIdentityToken(parsed.data.identityToken, parsed.data.nonce)
    // Only trust the email Apple signed into the identity token. A client-
    // supplied email must never link an Apple subject to somebody else's user.
    const email = identity.email ?? syntheticEmailForAppleSubject(identity.subject)
    const displayName = parsed.data.name ?? parsed.data.fullName

    const account = await prisma.account.upsert({
      where: {
        provider_providerAccountId: {
          provider: 'apple',
          providerAccountId: identity.subject,
        },
      },
      update: {},
      create: {
        type: 'oauth',
        provider: 'apple',
        providerAccountId: identity.subject,
        user: {
          connectOrCreate: {
            where: { email },
            create: {
              email,
              emailVerified: identity.email ? new Date() : null,
              name: displayName ?? null,
              preferredName: displayName ?? null,
              image: `https://api.dicebear.com/7.x/avataaars/svg?seed=${encodeURIComponent(identity.subject)}`,
            },
          },
        },
      },
      select: { user: { select: userSelect } },
    })
    const user = account.user
    return NextResponse.json({ token: createMobileToken(user), user: mobileUser(user) })
  } catch (error) {
    console.error('[MOBILE APPLE AUTH]', error)
    return NextResponse.json({ error: 'Apple sign-in failed' }, { status: 401 })
  }
}
