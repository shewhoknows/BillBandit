import assert from 'node:assert/strict'
import { test } from 'node:test'
import { profileDisplayName } from '../lib/profile-display-name'

test('public profile names use the same stable priority on all surfaces', () => {
  assert.equal(
    profileDisplayName({
      username: 'bubby',
      preferredName: 'Prateek',
      name: 'Prateek Ranka',
    }),
    'bubby'
  )
  assert.equal(
    profileDisplayName({ username: null, preferredName: 'Esha', name: 'Apple Name' }),
    'Esha'
  )
  assert.equal(profileDisplayName({ username: 'You', name: null }), 'Member')
})
