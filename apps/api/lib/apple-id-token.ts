import { createRemoteJWKSet, jwtVerify } from 'jose'

const appleJwks = createRemoteJWKSet(new URL('https://appleid.apple.com/auth/keys'))

export type AppleIdentity = {
  subject: string
  email?: string
}

export async function verifyAppleIdentityToken(
  identityToken: string,
  nonce?: string | null
): Promise<AppleIdentity> {
  const mockSubject = process.env.MOBILE_AUTH_MOCK_APPLE_SUBJECT
  if (mockSubject && identityToken === process.env.MOBILE_AUTH_MOCK_APPLE_TOKEN) {
    return { subject: mockSubject, email: process.env.MOBILE_AUTH_MOCK_APPLE_EMAIL }
  }

  const configuredAudience =
    process.env.APPLE_CLIENT_ID ??
    process.env.IOS_BUNDLE_ID ??
    process.env.NEXT_PUBLIC_IOS_BUNDLE_ID
  const audience = configuredAudience
    ? configuredAudience.split(',').map((value) => value.trim()).filter(Boolean)
    : ['com.billbandit.app']

  const { payload } = await jwtVerify(identityToken, appleJwks, {
    issuer: 'https://appleid.apple.com',
    audience,
  })

  if (nonce && payload.nonce !== nonce) {
    throw new Error('Invalid Apple nonce')
  }

  if (!payload.sub) {
    throw new Error('Apple token is missing a subject')
  }

  return {
    subject: String(payload.sub),
    email: typeof payload.email === 'string' ? payload.email : undefined,
  }
}
