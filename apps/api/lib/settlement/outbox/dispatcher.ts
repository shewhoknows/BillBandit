import { randomUUID } from 'node:crypto'
import { prisma } from '@/lib/prisma'
import { isRealtimeConfigured, publishOutboxEvent } from './pusher'
import { outboxLeaseToken, outboxTransition } from '../state'

const LEASE_MS = 30_000
const MAX_BACKOFF_MS = 60_000
const DRAIN_INTERVAL_MS = 5_000

let dispatcherStarted = false
let intervalHandle: ReturnType<typeof setInterval> | null = null

export function computeBackoffMs(attemptCount: number): number {
  const base = Math.min(MAX_BACKOFF_MS, 1000 * 2 ** attemptCount)
  const jitter = Math.floor(Math.random() * 250)
  return base + jitter
}

export async function drainOutboxOnce(owner = `worker-${process.pid}`): Promise<number> {
  if (!isRealtimeConfigured() || !process.env.DATABASE_URL) {
    return 0
  }

  const now = new Date()
  const reclaim = outboxTransition('reclaimExpired')
  await prisma.settlementOutbox.updateMany({
    where: {
      state: reclaim.from,
      leaseExpiresAt: { lt: now },
    },
    data: {
      state: reclaim.to,
      leaseOwner: null,
      leaseExpiresAt: null,
    },
  })

  const pending = await prisma.settlementOutbox.findMany({
    where: {
      state: outboxTransition('lease').from,
      nextAttemptAt: { lte: now },
    },
    orderBy: { createdAt: 'asc' },
    take: 25,
  })

  let published = 0
  for (const row of pending) {
    const leaseExpiresAt = new Date(Date.now() + LEASE_MS)
    const lease = outboxTransition('lease')
    const leaseToken = outboxLeaseToken(owner, randomUUID())
    const leased = await prisma.settlementOutbox.updateMany({
      where: { id: row.id, state: lease.from },
      data: {
        state: lease.to,
        leaseOwner: leaseToken,
        leaseExpiresAt,
      },
    })
    if (leased.count === 0) continue
    // Only the current lease holder may finish the row. If this lease expired
    // and another worker took the row, these writes match nothing.
    const held = { id: row.id, state: lease.to, leaseOwner: leaseToken }

    try {
      await publishOutboxEvent(row.groupId, {
        eventType: row.eventType,
        groupId: row.groupId,
        recordId: row.recordId,
        version: row.version,
      })
      const done = await prisma.settlementOutbox.updateMany({
        where: held,
        data: {
          state: outboxTransition('published').to,
          publishedAt: new Date(),
          leaseOwner: null,
          leaseExpiresAt: null,
          failureCode: null,
        },
      })
      if (done.count === 1) published++
    } catch {
      const attemptCount = row.attemptCount + 1
      await prisma.settlementOutbox.updateMany({
        where: held,
        data: {
          state: outboxTransition('publishFailed').to,
          attemptCount: { increment: 1 },
          nextAttemptAt: new Date(Date.now() + computeBackoffMs(attemptCount)),
          leaseOwner: null,
          leaseExpiresAt: null,
          failureCode: 'PUBLISH_FAILED',
        },
      })
    }
  }

  return published
}

function drainInBackground(): void {
  // A database error here must not become an unhandled rejection. Rows stay
  // PENDING or LEASED (lease expires) and the next drain picks them up.
  drainOutboxOnce().catch((error) => {
    console.error('[settlement outbox] drain failed', error)
  })
}

export function wakeOutboxDispatcher(): void {
  if (!isRealtimeConfigured()) return
  drainInBackground()
}

export function startOutboxDispatcher(): void {
  if (dispatcherStarted || !isRealtimeConfigured()) return
  dispatcherStarted = true
  drainInBackground()
  intervalHandle = setInterval(drainInBackground, DRAIN_INTERVAL_MS)
  intervalHandle.unref?.()
}
