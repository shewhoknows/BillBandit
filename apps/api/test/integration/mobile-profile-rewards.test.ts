import assert from 'node:assert/strict'
import { test } from 'node:test'
import { loadMobileRewardEvents } from '../../lib/mobile-rewards'
import {
  mobileProfileAvatarImage,
  parseMobileProfileAvatar,
} from '../../lib/profile-avatar'

test('mobile avatar values use a small server-safe allow list', () => {
  assert.equal(parseMobileProfileAvatar(' bucket-hat '), 'bucket-hat')
  assert.equal(mobileProfileAvatarImage('bucket-hat'), 'billbandit-avatar:bucket-hat')
  assert.equal(parseMobileProfileAvatar('https://example.com/avatar.svg'), null)
  assert.equal(parseMobileProfileAvatar('unknown'), null)
})

test('reward facts include shared actions from active and archived groups', async () => {
  const db = {
    expense: {
      findMany: async () => [
        { id: 'expense-2', createdAt: new Date('2026-08-12T10:02:00.000Z') },
        { id: 'expense-1', createdAt: new Date('2026-08-12T10:01:00.000Z') },
      ],
    },
    transaction: {
      findMany: async () => [
        { id: 'settlement-1', createdAt: new Date('2026-08-12T10:03:00.000Z') },
      ],
    },
  }

  const events = await loadMobileRewardEvents('account-esha', db as never)
  assert.deepEqual(events.map((event) => [event.action, event.eventId]), [
    ['expenseAdded', 'expense-1'],
    ['expenseAdded', 'expense-2'],
    ['settlementRecorded', 'settlement-1'],
  ])
})
