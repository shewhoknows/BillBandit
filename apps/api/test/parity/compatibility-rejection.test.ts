import assert from 'node:assert/strict'
import test from 'node:test'
import { NextRequest } from 'next/server'
import { requireTestDatabaseUrl } from '../integration/ledger-harness'
import { legacySharedLedgerWriteResponse } from '../../lib/mobile-expenses'
import { LEDGER_AUTHORITY_MODES, LEDGER_MIGRATION_STATES, evaluateLedgerGate } from '../../lib/compatibility/ledger-gate'

test('legacy shared-ledger writes are rejected with a bounded read-only upgrade response', async () => {
  const response = legacySharedLedgerWriteResponse(
    new NextRequest('http://localhost/api/mobile/expenses', {
      headers: { 'x-client-build': '200', 'x-client-contract-version': '1' },
    }),
    'Exact-money ledger-v2 fields are required'
  )
  const body = await response.json()

  assert.equal(response.status, 409)
  assert.equal(body.error, 'LEDGER_V2_REQUIRED')
  assert.equal(body.readOnly, true)
  assert.equal(body.upgrade.contract, 'ledger-v2')
  assert.deepEqual(body.upgrade.fields, ['operationId', 'expectedRevision', 'amount.minorUnits'])
})

test('a client below the contract floor cannot enter a completed API ledger', () => {
  const decision = evaluateLedgerGate({
    clientBuild: 99,
    clientContractVersion: 1,
    config: {
      contractVersion: 2,
      minimumClientBuild: 100,
      authorityMode: LEDGER_AUTHORITY_MODES.API,
      migrationState: LEDGER_MIGRATION_STATES.COMPLETE,
      rolloutCohort: 'test',
    },
  })

  assert.equal(decision.outcome, 'unsupported_client')
  assert.equal(decision.allowed, false)
  assert.equal(decision.readOnly, true)
  assert.equal(decision.reasonCode, 'client_build_too_old')
})

test('the disposable harness rejects production-like database hosts before connecting', () => {
  const previous = process.env.TEST_DATABASE_URL
  process.env.TEST_DATABASE_URL = 'postgresql://user@db-production.example.com/billbandit_test'
  try {
    assert.throws(() => requireTestDatabaseUrl(), /production-like/)
  } finally {
    if (previous === undefined) delete process.env.TEST_DATABASE_URL
    else process.env.TEST_DATABASE_URL = previous
  }
})
