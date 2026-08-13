import assert from 'node:assert/strict'
import test from 'node:test'
import {
  FRIEND_INVITE_ALPHABET,
  generateFriendInviteCode,
  isValidFriendInviteCode,
  normalizeFriendInviteCode,
  normalizedFriendPair,
} from '../../lib/friends'

test('friend codes normalize to five unambiguous uppercase alphanumeric characters', () => {
  assert.equal(normalizeFriendInviteCode(' al-2ce '), 'AL2CE')
  assert.equal(normalizeFriendInviteCode('AI10O'), 'A')
  assert.equal(isValidFriendInviteCode(' al-2ce '), true)
  assert.equal(isValidFriendInviteCode('ABC2'), false)

  for (let index = 0; index < 100; index += 1) {
    const code = generateFriendInviteCode()
    assert.equal(code.length, 5)
    assert.match(code, /^[A-Z0-9]{5}$/)
    assert.equal([...code].every((character) => FRIEND_INVITE_ALPHABET.includes(character)), true)
  }
})

test('friend pair keys do not depend on claim direction', () => {
  const forward = normalizedFriendPair('account-b', 'account-a')
  const reverse = normalizedFriendPair('account-a', 'account-b')
  assert.deepEqual(forward, reverse)
  assert.deepEqual(forward, {
    fromId: 'account-a',
    toId: 'account-b',
  })
})
