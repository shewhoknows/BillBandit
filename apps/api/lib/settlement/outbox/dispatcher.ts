import { prisma } from '@/lib/prisma'
import { isRealtimeConfigured, publishOutboxEvent } from './pusher'

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
  await prisma.settlementOutbox.updateMany({
    where: {
      state: 'LEASED',
      leaseExpiresAt: { lt: now },
    },
    data: {
      state: 'PENDING',
      leaseOwner: null,
      leaseExpiresAt: null,
    },
  })

  const pending = await prisma.settlementOutbox.findMany({
    where: {
      state: 'PENDING',
      nextAttemptAt: { lte: now },
    },
    orderBy: { createdAt: 'asc' },
    take: 25,
  })

  let published = 0
  for (const row of pending) {
    const leaseExpiresAt = new Date(Date.now() + LEASE_MS)
    const leased = await prisma.settlementOutbox.updateMany({
      where: { id: row.id, state: 'PENDING' },
      data: {
        state: 'LEASED',
        leaseOwner: owner,
        leaseExpiresAt,
      },
    })
    if (leased.count === 0) continue

    try {
      await publishOutboxEvent(row.groupId, {
        eventType: row.eventType,
        groupId: row.groupId,
        recordId: row.recordId,
        version: row.version,
      })
      await prisma.settlementOutbox.update({
        where: { id: row.id },
        data: {
          state: 'PUBLISHED',
          publishedAt: new Date(),
          leaseOwner: null,
          leaseExpiresAt: null,
          failureCode: null,
        },
      })
      published++
    } catch {
      const attemptCount = row.attemptCount + 1
      await prisma.settlementOutbox.update({
        where: { id: row.id },
        data: {
          state: 'PENDING',
          attemptCount,
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

export function wakeOutboxDispatcher(): void {
  if (!isRealtimeConfigured()) return
  void drainOutboxOnce()
}

export function startOutboxDispatcher(): void {
  if (dispatcherStarted || !isRealtimeConfigured()) return
  dispatcherStarted = true
  void drainOutboxOnce()
  intervalHandle = setInterval(() => {
    void drainOutboxOnce()
  }, DRAIN_INTERVAL_MS)
  intervalHandle.unref?.()
}

export function stopOutboxDispatcher(): void {
  if (intervalHandle) clearInterval(intervalHandle)
  intervalHandle = null
  dispatcherStarted = false
}

export function isOutboxDispatcherRunning(): boolean {
  return dispatcherStarted
}
