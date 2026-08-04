import { NextRequest, NextResponse } from 'next/server'
import { randomUUID } from 'node:crypto'
import { prisma } from '@/lib/prisma'
import { requireMobileSession } from '@/lib/mobile-auth'
import { loadGroupReadModel } from '@/lib/ledger/read-model/loader'
import {
  buildGroupDetailResponseFromLedger,
  canonicalGroupIsReadOnly,
  readModelErrorResponse,
} from '@/lib/mobile-groups'
import {
  legacySharedLedgerWriteResponse,
  migrationReadOnlyResponse,
  mutationErrorResponse,
  readMutationMetadata,
} from '@/lib/mobile-expenses'
import { mobileFinalizeV2Schema } from '@/lib/validations-mobile-ledger'
import { mutationRequestHash } from '@/lib/ledger/mutation'
import { LedgerMutationError, MutationConflictError, conflictReadModel } from '@/lib/ledger/mutation/errors'

const RETENTION_DAYS = 30

async function finalizeGroup(input: {
  groupId: string
  accountId: string
  operationId: string
  expectedRevision: number
}) {
  const requestHash = mutationRequestHash({
    groupId: input.groupId,
    kind: 'group.finalize',
    payload: { groupId: input.groupId },
  })

  return prisma.$transaction(async (tx) => {
    const now = new Date()
    const operation = await tx.ledgerOperation.upsert({
      where: {
        accountId_operationKey: {
          accountId: input.accountId,
          operationKey: input.operationId,
        },
      },
      create: {
        id: randomUUID(),
        accountId: input.accountId,
        groupId: input.groupId,
        operationKey: input.operationId,
        requestHash,
        expectedRevision: input.expectedRevision,
        state: 'PENDING',
      },
      update: {},
    })

    const current = await tx.group.findUnique({
      where: { id: input.groupId },
      select: { id: true, settlementVersion: true, simplifyDebts: true, isArchived: true, finalizedAt: true },
    })
    if (!current) throw new LedgerMutationError('GROUP_NOT_FOUND', 404, 'Group not found')
    const readModel = conflictReadModel({
      groupId: current.id,
      revision: current.settlementVersion,
      simplifyDebts: current.simplifyDebts,
      isArchived: current.isArchived,
      finalizedAt: current.finalizedAt,
    })

    if (operation.requestHash !== requestHash || operation.groupId !== input.groupId) {
      throw new MutationConflictError('IDEMPOTENCY_KEY_REUSED', {
        groupId: input.groupId,
        operationId: input.operationId,
        expectedRevision: input.expectedRevision,
        currentRevision: current.settlementVersion,
        currentVersion: current.settlementVersion,
        retryable: false,
        serverAuthoritative: true,
        readModel,
        currentReadModel: readModel,
        expectedRequestHash: requestHash,
        existingRequestHash: operation.requestHash,
      })
    }
    if (operation.state === 'COMMITTED') {
      const revision = operation.resultRevision ?? current.settlementVersion
      const recordId = operation.resultRecordId ?? input.groupId
      return {
        groupId: input.groupId,
        operationId: input.operationId,
        outcome: 'replayed' as const,
        replayed: true,
        revision,
        readRevision: revision,
        currentRevision: revision,
        requestHash,
        recordId,
        eventType: 'group_finalized',
        result: { recordId, eventType: 'group_finalized' },
        idempotency: {
          key: input.operationId,
          requestHash,
          replayed: true,
          resultRevision: revision,
          retainedUntil: new Date(
            (operation.completedAt ?? operation.createdAt).getTime() + RETENTION_DAYS * 24 * 60 * 60 * 1000
          ).toISOString(),
        },
        authority: {
          serverAuthoritative: true as const,
          moneyAuthority: 'minor_units' as const,
          revisionAuthority: 'group' as const,
        },
        finalizedAt: current.finalizedAt?.toISOString() ?? null,
      }
    }
    if (operation.state === 'FAILED') {
      throw new LedgerMutationError('MUTATION_FAILED', 409, 'The operation previously failed')
    }
    const membership = await tx.groupMember.findUnique({
      where: { groupId_userId: { groupId: input.groupId, userId: input.accountId } },
      select: { role: true },
    })
    if (!membership || membership.role !== 'ADMIN') {
      throw new LedgerMutationError('FORBIDDEN', 403, 'An administrator is required')
    }
    if (current.settlementVersion !== input.expectedRevision) {
      throw new MutationConflictError('REVISION_CONFLICT', {
        groupId: input.groupId,
        operationId: input.operationId,
        expectedRevision: input.expectedRevision,
        currentRevision: current.settlementVersion,
        currentVersion: current.settlementVersion,
        retryable: true,
        serverAuthoritative: true,
        readModel,
        currentReadModel: readModel,
      })
    }
    if (current.isArchived) throw new LedgerMutationError('GROUP_ARCHIVED', 403, 'Group is archived')
    if (current.finalizedAt) throw new LedgerMutationError('GROUP_FINALIZED', 409, 'Group is finalized')

    const finalizedAt = now
    const updated = await tx.group.updateMany({
      where: {
        id: input.groupId,
        settlementVersion: input.expectedRevision,
        finalizedAt: null,
        isArchived: false,
      },
      data: {
        finalizedAt,
        finalizedById: input.accountId,
        settlementVersion: { increment: 1 },
      },
    })
    if (updated.count !== 1) {
      throw new MutationConflictError('REVISION_CONFLICT', {
        groupId: input.groupId,
        operationId: input.operationId,
        expectedRevision: input.expectedRevision,
        currentRevision: input.expectedRevision + 1,
        currentVersion: input.expectedRevision + 1,
        retryable: true,
        serverAuthoritative: true,
        readModel,
        currentReadModel: readModel,
      })
    }
    const revision = input.expectedRevision + 1
    await tx.settlementVersionJournal.create({
      data: { groupId: input.groupId, version: revision, recordId: input.groupId, eventType: 'group_finalized' },
    })
    await tx.settlementOutbox.create({
      data: { groupId: input.groupId, version: revision, recordId: input.groupId, eventType: 'group_finalized' },
    })
    await tx.ledgerOperation.update({
      where: { id: operation.id },
      data: {
        state: 'COMMITTED',
        resultRevision: revision,
        resultRecordId: input.groupId,
        completedAt: now,
      },
    })
    return {
      groupId: input.groupId,
      operationId: input.operationId,
      outcome: 'applied' as const,
      replayed: false,
      revision,
      readRevision: revision,
      currentRevision: revision,
      requestHash,
      recordId: input.groupId,
      eventType: 'group_finalized',
      result: { recordId: input.groupId, eventType: 'group_finalized' },
      idempotency: {
        key: input.operationId,
        requestHash,
        replayed: false,
        resultRevision: revision,
        retainedUntil: new Date(now.getTime() + RETENTION_DAYS * 24 * 60 * 60 * 1000).toISOString(),
      },
      authority: {
        serverAuthoritative: true as const,
        moneyAuthority: 'minor_units' as const,
        revisionAuthority: 'group' as const,
      },
      finalizedAt: finalizedAt.toISOString(),
    }
  })
}

export async function POST(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  let body: unknown
  try {
    body = await req.json()
  } catch {
    return legacySharedLedgerWriteResponse(req, 'A canonical v2 finalize body is required')
  }
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    return legacySharedLedgerWriteResponse(req, 'A canonical v2 finalize body is required')
  }
  const parsed = mobileFinalizeV2Schema.safeParse(body)
  if (!parsed.success) {
    return NextResponse.json({ error: parsed.error.errors[0].message }, { status: 400 })
  }
  const metadataResult = readMutationMetadata(req, body)
  if ('response' in metadataResult) return metadataResult.response

  try {
    const read = await loadGroupReadModel(params.id, session.user.id)
    if (canonicalGroupIsReadOnly(read.group)) return migrationReadOnlyResponse(read.group)
    const actor = read.group.members.find((member) => member.accountId === session.user.id)
    if (!actor || actor.role !== 'owner') return NextResponse.json({ error: 'Forbidden' }, { status: 403 })

    const result = await finalizeGroup({
      groupId: params.id,
      accountId: session.user.id,
      operationId: metadataResult.metadata.operationId,
      expectedRevision: metadataResult.metadata.expectedRevision,
    })
    const after = await loadGroupReadModel(params.id, session.user.id)
    const responseBody = buildGroupDetailResponseFromLedger(after.group)
    responseBody.group.status = 'FINALIZED'
    responseBody.group.finalizedAt = result.finalizedAt
    return NextResponse.json(
      { ...responseBody, mutation: result, revision: result.revision, readModel: after.envelope },
      { status: 200 }
    )
  } catch (error) {
    const readResponse = readModelErrorResponse(error, params.id)
    if (readResponse) return readResponse
    return mutationErrorResponse(error, '[MOBILE POST /groups/:id/finalize]')
  }
}
