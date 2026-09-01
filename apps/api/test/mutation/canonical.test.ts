import assert from 'node:assert/strict'
import test from 'node:test'
import {
  canonicalStringify,
  hashCanonicalRequest,
  parseMutationMoney,
  sumMutationMoney,
} from '../../lib/ledger/mutation'

test('canonical mutation hashes ignore object key order and preserve exact integers', () => {
  assert.equal(
    hashCanonicalRequest({ b: 2, a: { minorUnits: 100n, currencyCode: 'USD' } }),
    hashCanonicalRequest({ a: { currencyCode: 'USD', minorUnits: '100' }, b: 2 })
  )
  assert.notEqual(hashCanonicalRequest({ amount: '100' }), hashCanonicalRequest({ amount: '101' }))
  assert.equal(canonicalStringify({ z: undefined, a: [undefined, 1] }), '{"a":[null,1]}')
})

test('mutation money is exact and split totals use bigint arithmetic', () => {
  const first = parseMutationMoney({
    minorUnits: '100',
    currencyCode: 'USD',
    currencyExponent: 2,
  })
  const second = parseMutationMoney({
    minorUnits: 25n,
    currencyCode: 'USD',
    currencyExponent: 2,
  })
  assert.equal(sumMutationMoney([first, second])?.minorUnits, 125n)
  assert.throws(
    () => parseMutationMoney({ minorUnits: 100, currencyCode: 'USD', currencyExponent: 2 }),
    /minorUnits/
  )
  assert.throws(
    () => parseMutationMoney({ minorUnits: '1', currencyCode: 'KWD', currencyExponent: 2 }),
    /does not match/
  )
})
