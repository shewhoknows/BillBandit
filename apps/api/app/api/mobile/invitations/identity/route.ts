import { NextRequest, NextResponse } from 'next/server'
import { requireMobileSession } from '@/lib/mobile-auth'
import {
  linkExternalIdentity,
  listExternalIdentities,
  resolveExternalIdentity,
} from '@/lib/identity/external-identities'
import {
  identityErrorResponse,
  parseJson,
  requestedExternalIdentity,
} from '@/lib/identity/mobile-routes'
import { externalIdentity } from '@/lib/identity/types'
import { prisma } from '@/lib/prisma'
import { verifyAppleIdentityToken } from '@/lib/apple-id-token'

export async function GET(req: NextRequest) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  try {
    const identities = await listExternalIdentities(session.user.id)
    return NextResponse.json({
      identities: identities.map((identity) => ({
        id: identity.id,
        accountId: identity.accountId,
        provider: identity.provider,
        subject: identity.subject,
        createdAt: identity.createdAt.toISOString(),
        updatedAt: identity.updatedAt.toISOString(),
      })),
    })
  } catch (error) {
    return identityErrorResponse(error)
  }
}

export async function POST(req: NextRequest) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  try {
    const body = await parseJson(req)
    const hasExplicitIdentity =
      body.identity !== undefined ||
      body.externalIdentity !== undefined ||
      body.provider !== undefined ||
      body.subject !== undefined ||
      body.recordName !== undefined ||
      body.appleSubject !== undefined ||
      body.cloudKitRecordName !== undefined ||
      body.cloudkitRecordName !== undefined
    let verifiedAppleSubject: string | undefined
    let identity
    if (!hasExplicitIdentity && typeof body.identityToken === 'string') {
      const verified = await verifyAppleIdentityToken(
        body.identityToken,
        typeof body.nonce === 'string' ? body.nonce : undefined
      )
      verifiedAppleSubject = verified.subject
      identity = externalIdentity('apple', verified.subject)
    } else {
      identity = requestedExternalIdentity(body)
    }

    // A mobile caller cannot prove an arbitrary Apple subject by sending it in
    // JSON. Prefer a freshly verified Apple token; without one, only accept a
    // subject already present in this account's explicit Account mapping.
    if (identity.provider === 'apple') {
      if (typeof body.identityToken === 'string' && body.identityToken.length > 0) {
        const verifiedSubject =
          verifiedAppleSubject ??
          (
            await verifyAppleIdentityToken(
              body.identityToken,
              typeof body.nonce === 'string' ? body.nonce : undefined
            )
          ).subject
        if (verifiedSubject !== identity.subject) {
          return NextResponse.json(
            {
              code: 'identity_repair_required',
              state: 'repair_required',
              error: 'The supplied Apple identity does not match the verified account credential.',
            },
            { status: 409 }
          )
        }
        identity = externalIdentity('apple', verifiedSubject)
      } else {
        const account = await prisma.account.findUnique({
          where: {
            provider_providerAccountId: {
              provider: 'apple',
              providerAccountId: identity.subject,
            },
          },
          select: { userId: true },
        })
        if (!account) {
          return NextResponse.json(
            { code: 'identity_not_registered', error: 'The Apple identity is not registered.' },
            { status: 404 }
          )
        }
        if (account.userId !== session.user.id) {
          return NextResponse.json(
            {
              code: 'identity_repair_required',
              state: 'repair_required',
              error: 'This Apple identity is linked to a different account. No account was merged.',
            },
            { status: 409 }
          )
        }
      }
    } else {
      const existing = await resolveExternalIdentity(identity.provider, identity.subject)
      if (existing && existing.accountId !== session.user.id) {
        return NextResponse.json(
          {
            code: 'identity_repair_required',
            state: 'repair_required',
            error: 'This CloudKit identity is linked to a different account. No account was merged.',
          },
          { status: 409 }
        )
      }
      if (!existing) {
        return NextResponse.json(
          { code: 'identity_not_registered', error: 'The CloudKit identity is not registered.' },
          { status: 404 }
        )
      }
    }

    const result = await linkExternalIdentity({
      accountId: session.user.id,
      provider: identity.provider,
      subject: identity.subject,
    })

    if (result.status === 'repair_required') {
      return NextResponse.json(
        {
          code: 'identity_repair_required',
          state: 'repair_required',
          reason: result.reason,
          error: 'This external identity is already linked inconsistently. Repair is required; no account was merged.',
        },
        { status: 409 }
      )
    }

    return NextResponse.json(
      {
        identity: {
          id: result.identityId,
          accountId: result.accountId,
          provider: result.identity.provider,
          subject: result.identity.subject,
        },
        status: result.status,
      },
      { status: result.status === 'created' ? 201 : 200 }
    )
  } catch (error) {
    return identityErrorResponse(error)
  }
}
