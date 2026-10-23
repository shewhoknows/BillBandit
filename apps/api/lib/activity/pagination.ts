import type { AccountActivityItem } from '../ledger/read-model/types'

export const DEFAULT_ACTIVITY_PAGE_SIZE = 30
export const MAX_ACTIVITY_PAGE_SIZE = 100

/**
 * Activity arrives newest first, ordered by (at desc, groupId asc, activityId asc).
 * A cursor names the last item a client already holds, so new events that land
 * between requests never shift a page or repeat a row.
 */
export function encodeActivityCursor(item: Pick<AccountActivityItem, 'at' | 'groupId' | 'activityId'>): string {
  return Buffer.from(JSON.stringify([item.at, item.groupId, item.activityId]), 'utf8').toString('base64url')
}

export function decodeActivityCursor(cursor: string): [string, string, string] | null {
  try {
    const value = JSON.parse(Buffer.from(cursor, 'base64url').toString('utf8'))
    if (Array.isArray(value) && value.length === 3 && value.every((part) => typeof part === 'string')) {
      return value as [string, string, string]
    }
  } catch {
    // Malformed cursors are treated as absent below.
  }
  return null
}

function isAfterCursor(item: AccountActivityItem, cursor: [string, string, string]): boolean {
  const [at, groupId, activityId] = cursor
  if (item.at !== at) return item.at < at
  if (item.groupId !== groupId) return item.groupId > groupId
  return item.activityId > activityId
}

export function parseActivityPageSize(value: string | null): number | null {
  if (value === null) return null
  const parsed = Number.parseInt(value, 10)
  if (!Number.isFinite(parsed)) return DEFAULT_ACTIVITY_PAGE_SIZE
  return Math.min(Math.max(parsed, 1), MAX_ACTIVITY_PAGE_SIZE)
}

export function pageActivity(
  activity: AccountActivityItem[],
  options: { limit: number; before?: string | null }
): { items: AccountActivityItem[]; nextCursor: string | null } {
  const cursor = options.before ? decodeActivityCursor(options.before) : null
  const remaining = cursor ? activity.filter((item) => isAfterCursor(item, cursor)) : activity
  const items = remaining.slice(0, options.limit)
  const hasMore = remaining.length > items.length
  return {
    items,
    nextCursor: hasMore && items.length > 0 ? encodeActivityCursor(items[items.length - 1]) : null,
  }
}
