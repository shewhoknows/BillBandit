import assert from 'node:assert/strict'
import test from 'node:test'
import { NextRequest } from 'next/server'
import { GET as getCapabilities } from '../../app/api/mobile/capabilities/route'
import {
  evaluateLedgerGate,
  LEDGER_AUTHORITY_MODES,
  LEDGER_MIGRATION_STATES,
} from '../../lib/compatibility/ledger-gate'
import {
  createLedgerEvent,
  emitLedgerEvent,
  LEDGER_EVENT_TYPES,
} from '../../lib/observability/ledger-events'

const completeApiConfig = {
  contractVersion: 1,
  minimumClientBuild: 100,
  authorityMode: LEDGER_AUTHORITY_MODES.API,
  migrationState: LEDGER_MIGRATION_STATES.COMPLETE,
  rolloutCohort: 'pilot',
} as const

test('compatible client is supported deterministically', () => {
  const input = {
    clientBuild: 101,
    clientContractVersion: 1,
    config: completeApiConfig,
  }

  const first = evaluateLedgerGate(input)
  const second = evaluateLedgerGate(input)

  assert.deepEqual(first, second)
  assert.equal(first.outcome, 'supported')
  assert.equal(first.allowed, true)
  assert.equal(first.readOnly, false)
  assert.equal(first.migrationRequired, false)
  assert.equal(first.enforcementEnabled, false)
})

test('old client is read-only and unsupported', () => {
  const decision = evaluateLedgerGate({
    clientBuild: 99,
    clientContractVersion: 1,
    config: completeApiConfig,
  })

  assert.equal(decision.outcome, 'unsupported_client')
  assert.equal(decision.reasonCode, 'client_build_too_old')
  assert.equal(decision.allowed, false)
  assert.equal(decision.readOnly, true)
  assert.equal(decision.migrationRequired, false)
})

test('non-API authority fails closed', () => {
  const decision = evaluateLedgerGate({
    clientBuild: 101,
    config: {
      ...completeApiConfig,
      authorityMode: LEDGER_AUTHORITY_MODES.CLOUDKIT,
    },
  })

  assert.equal(decision.outcome, 'blocked')
  assert.equal(decision.reasonCode, 'authority_not_api')
  assert.equal(decision.allowed, false)
  assert.equal(decision.readOnly, true)
})

test('migration in progress requires migration and stays read-only', () => {
  const decision = evaluateLedgerGate({
    clientBuild: 101,
    config: {
      ...completeApiConfig,
      migrationState: LEDGER_MIGRATION_STATES.IN_PROGRESS,
    },
  })

  assert.equal(decision.outcome, 'migration_required')
  assert.equal(decision.reasonCode, 'migration_in_progress')
  assert.equal(decision.migrationRequired, true)
  assert.equal(decision.readOnly, true)
})

test('blocked migration fails closed even for a compatible client', () => {
  const decision = evaluateLedgerGate({
    clientBuild: 101,
    config: {
      ...completeApiConfig,
      migrationState: LEDGER_MIGRATION_STATES.BLOCKED,
    },
  })

  assert.equal(decision.outcome, 'blocked')
  assert.equal(decision.reasonCode, 'migration_blocked')
  assert.equal(decision.migrationRequired, true)
  assert.equal(decision.allowed, false)
})

test('ledger telemetry hashes identifiers and omits private and monetary values', () => {
  const event = createLedgerEvent(
    LEDGER_EVENT_TYPES.MUTATION,
    {
      accountId: 'acct-private-123',
      appleSubject: 'apple-subject-private-456',
      amount: '₹1,234.56',
      currencyCode: 'INR',
      email: 'alice@example.com',
      groupId: 'group-private-789',
      money: { minorUnits: '123456' },
      operationId: 'operation-private-999',
      queueDepth: 3,
      status: 'accepted',
      token: 'eyJ.private.token',
    },
    { occurredAt: '2026-08-03T00:00:00.000Z', hashSalt: 'test-only-salt' }
  )

  const serialized = JSON.stringify(event)
  assert.equal(event.occurredAt, '2026-08-03T00:00:00.000Z')
  assert.match(String(event.payload.accountId), /^sha256:/)
  assert.match(String(event.payload.groupId), /^sha256:/)
  assert.match(String(event.payload.operationId), /^sha256:/)
  assert.equal(event.payload.queueDepth, 3)
  assert.equal(event.payload.status, 'accepted')
  assert.equal('appleSubject' in event.payload, false)
  assert.equal('amount' in event.payload, false)
  assert.equal('currencyCode' in event.payload, false)
  assert.equal('email' in event.payload, false)
  assert.equal('money' in event.payload, false)
  assert.equal('token' in event.payload, false)
  assert.equal(serialized.includes('acct-private-123'), false)
  assert.equal(serialized.includes('apple-subject-private-456'), false)
  assert.equal(serialized.includes('alice@example.com'), false)
  assert.equal(serialized.includes('eyJ.private.token'), false)
  assert.equal(serialized.includes('₹1,234.56'), false)
  assert.equal(serialized.includes('123456'), false)
})

test('event emitter sends the same sanitized structured event to its sink', () => {
  const events: unknown[] = []
  const event = emitLedgerEvent(
    LEDGER_EVENT_TYPES.GATE_DECISION,
    { decision: 'supported', groupId: 'private-group', readOnly: false },
    (value) => events.push(value),
    { occurredAt: '2026-08-03T00:00:00.000Z' }
  )

  assert.equal(events.length, 1)
  assert.deepEqual(events[0], event)
  assert.equal(JSON.stringify(events[0]).includes('private-group'), false)
})

test('capability response is cache-disabled and contains no private ledger data', async () => {
  const request = new NextRequest('http://localhost/api/mobile/capabilities', {
    headers: {
      'x-client-build': '101',
      'x-client-contract-version': '1',
    },
  })
  const response = await getCapabilities(request)
  const body = await response.json()
  const serialized = JSON.stringify(body)

  assert.equal(response.headers.get('cache-control'), 'no-store')
  assert.equal(typeof body.contractVersion, 'number')
  assert.equal(typeof body.minimumClientBuild, 'number')
  assert.equal(typeof body.migrationRequired, 'boolean')
  assert.equal(typeof body.readOnly, 'boolean')
  assert.equal(typeof body.rolloutCohort, 'string')
  assert.equal(serialized.includes('alice@example.com'), false)
  assert.equal(serialized.includes('apple-subject-private-456'), false)
  assert.equal(serialized.includes('eyJ.private.token'), false)
  assert.equal(serialized.includes('₹1,234.56'), false)
})
