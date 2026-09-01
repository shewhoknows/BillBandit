import { NextRequest, NextResponse } from 'next/server'
import { emitLedgerEvent, LEDGER_EVENT_TYPES } from '../../../../lib/observability/ledger-events'
import {
  evaluateLedgerGate,
  LEDGER_ENFORCEMENT_ENABLED,
  readClientCapabilityHeaders,
} from '../../../../lib/compatibility/ledger-gate'

export async function GET(req: NextRequest) {
  const clientHeaders = readClientCapabilityHeaders(req.headers)
  const decision = evaluateLedgerGate(clientHeaders)

  emitLedgerEvent(LEDGER_EVENT_TYPES.GATE_DECISION, {
    authorityMode: decision.authorityMode,
    clientBuild: decision.clientBuild,
    clientContractVersion: decision.clientContractVersion,
    decision: decision.outcome,
    migrationRequired: decision.migrationRequired,
    migrationState: decision.migrationState,
    readOnly: decision.readOnly,
    reasonCode: decision.reasonCode,
    rolloutCohort: decision.rolloutCohort,
  })

  return NextResponse.json(
    {
      contractVersion: decision.contractVersion,
      minimumClientBuild: decision.minimumClientBuild,
      migrationRequired: decision.migrationRequired,
      readOnly: decision.readOnly,
      rolloutCohort: decision.rolloutCohort,
      gate: {
        outcome: decision.outcome,
        reasonCode: decision.reasonCode,
        allowed: decision.allowed,
        enforcementEnabled: LEDGER_ENFORCEMENT_ENABLED,
      },
    },
    {
      headers: {
        'Cache-Control': 'no-store',
        Pragma: 'no-cache',
        Expires: '0',
        Vary: 'X-Client-Build, X-Client-Contract-Version',
      },
    }
  )
}
