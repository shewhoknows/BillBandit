export const LEDGER_CONTRACT_VERSION = 1
export const MINIMUM_CLIENT_BUILD = 1
export const DEFAULT_ROLLOUT_COHORT = 'control'
export const LEDGER_ENFORCEMENT_ENABLED = false

export const LEDGER_AUTHORITY_MODES = {
  API: 'api',
  CLOUDKIT: 'cloudkit',
  LOCAL: 'local',
  UNKNOWN: 'unknown',
} as const

export type LedgerAuthorityMode =
  (typeof LEDGER_AUTHORITY_MODES)[keyof typeof LEDGER_AUTHORITY_MODES]

export const LEDGER_MIGRATION_STATES = {
  NOT_STARTED: 'not_started',
  IN_PROGRESS: 'in_progress',
  COMPLETE: 'complete',
  FAILED: 'failed',
  BLOCKED: 'blocked',
} as const

export type LedgerMigrationState =
  (typeof LEDGER_MIGRATION_STATES)[keyof typeof LEDGER_MIGRATION_STATES]

export type LedgerGateOutcome =
  | 'supported'
  | 'unsupported_client'
  | 'migration_required'
  | 'blocked'

export type LedgerGateConfig = {
  contractVersion: number
  minimumClientBuild: number
  authorityMode: LedgerAuthorityMode
  migrationState: LedgerMigrationState
  rolloutCohort: string
}

export type LedgerGateInput = {
  clientBuild?: number | string | null
  clientVersion?: number | string | null
  clientContractVersion?: number | string | null
  contractVersion?: number | string | null
  minimumClientBuild?: number | string | null
  minimumClientVersion?: number | string | null
  authorityMode?: unknown
  serverAuthorityMode?: unknown
  migrationState?: unknown
  rolloutCohort?: string | null
  config?: Partial<LedgerGateConfig>
}

export type LedgerGateDecision = {
  outcome: LedgerGateOutcome
  status: LedgerGateOutcome
  reasonCode: string
  allowed: boolean
  readOnly: boolean
  migrationRequired: boolean
  enforcementEnabled: false
  contractVersion: number
  minimumClientBuild: number
  rolloutCohort: string
  authorityMode: LedgerAuthorityMode
  migrationState: LedgerMigrationState
  clientBuild: number | null
  clientContractVersion: number | null
}

export type LedgerCapabilities = {
  contractVersion: number
  minimumClientBuild: number
  migrationRequired: boolean
  readOnly: boolean
  rolloutCohort: string
  gate: {
    outcome: LedgerGateOutcome
    reasonCode: string
    allowed: boolean
    enforcementEnabled: false
  }
}

export type ClientCapabilityHeaders = {
  clientBuild: string | null
  clientContractVersion: string | null
}

function parseInteger(value: unknown): number | null {
  if (typeof value === 'number') {
    return Number.isSafeInteger(value) && value >= 0 ? value : null
  }
  if (typeof value !== 'string' || !/^\d+$/.test(value.trim())) return null
  const parsed = Number(value)
  return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : null
}

function normalizeAuthorityMode(value: unknown): LedgerAuthorityMode {
  if (typeof value !== 'string') return LEDGER_AUTHORITY_MODES.UNKNOWN
  switch (value.trim().toLowerCase().replace(/-/g, '_')) {
    case 'api':
    case 'api_authoritative':
    case 'server':
    case 'server_authoritative':
      return LEDGER_AUTHORITY_MODES.API
    case 'cloudkit':
      return LEDGER_AUTHORITY_MODES.CLOUDKIT
    case 'local':
      return LEDGER_AUTHORITY_MODES.LOCAL
    default:
      return LEDGER_AUTHORITY_MODES.UNKNOWN
  }
}

function normalizeMigrationState(value: unknown): LedgerMigrationState {
  if (typeof value !== 'string') return LEDGER_MIGRATION_STATES.BLOCKED
  switch (value.trim().toLowerCase().replace(/-/g, '_')) {
    case 'not_started':
    case 'pending':
      return LEDGER_MIGRATION_STATES.NOT_STARTED
    case 'in_progress':
    case 'migrating':
    case 'migration_in_progress':
      return LEDGER_MIGRATION_STATES.IN_PROGRESS
    case 'complete':
    case 'completed':
    case 'done':
    case 'ready':
      return LEDGER_MIGRATION_STATES.COMPLETE
    case 'failed':
    case 'error':
      return LEDGER_MIGRATION_STATES.FAILED
    case 'blocked':
    case 'rollback':
    case 'rolled_back':
      return LEDGER_MIGRATION_STATES.BLOCKED
    default:
      return LEDGER_MIGRATION_STATES.BLOCKED
  }
}

function normalizeCohort(value: unknown): string {
  if (typeof value !== 'string') return DEFAULT_ROLLOUT_COHORT
  const cohort = value.trim().toLowerCase()
  return /^[a-z0-9][a-z0-9._-]{0,63}$/.test(cohort) ? cohort : DEFAULT_ROLLOUT_COHORT
}

function envValue(env: NodeJS.ProcessEnv, names: string[]): string | undefined {
  return names.map((name) => env[name]).find((value) => value !== undefined)
}

export function getLedgerGateConfig(env: NodeJS.ProcessEnv = process.env): LedgerGateConfig {
  const contractVersionValue = envValue(env, ['LEDGER_CONTRACT_VERSION'])
  const minimumClientBuildValue = envValue(env, [
    'LEDGER_MINIMUM_CLIENT_BUILD',
    'MINIMUM_CLIENT_BUILD',
  ])
  const contractVersion =
    contractVersionValue === undefined
      ? LEDGER_CONTRACT_VERSION
      : parseInteger(contractVersionValue) ?? 0
  const minimumClientBuild =
    minimumClientBuildValue === undefined
      ? MINIMUM_CLIENT_BUILD
      : parseInteger(minimumClientBuildValue) ?? 0

  return {
    contractVersion,
    minimumClientBuild,
    authorityMode: normalizeAuthorityMode(
      envValue(env, ['LEDGER_AUTHORITY_MODE', 'LEDGER_AUTHORITY']) ?? LEDGER_AUTHORITY_MODES.API
    ),
    migrationState: normalizeMigrationState(
      envValue(env, ['LEDGER_MIGRATION_STATE', 'LEDGER_MIGRATION_STATUS']) ??
        LEDGER_MIGRATION_STATES.NOT_STARTED
    ),
    rolloutCohort: normalizeCohort(
      envValue(env, ['LEDGER_ROLLOUT_COHORT', 'LEDGER_COHORT']) ?? DEFAULT_ROLLOUT_COHORT
    ),
  }
}

function resolveConfig(input: LedgerGateInput): { config: LedgerGateConfig; valid: boolean } {
  const environment = getLedgerGateConfig()
  const supplied = input.config ?? {}
  const contractRaw = supplied.contractVersion ?? input.contractVersion ?? environment.contractVersion
  const minimumBuildRaw =
    supplied.minimumClientBuild ??
    input.minimumClientBuild ??
    input.minimumClientVersion ??
    environment.minimumClientBuild
  const contractVersion = parseInteger(contractRaw)
  const minimumClientBuild = parseInteger(minimumBuildRaw)
  const authorityMode = normalizeAuthorityMode(
    supplied.authorityMode ?? input.authorityMode ?? input.serverAuthorityMode ?? environment.authorityMode
  )
  const migrationState = normalizeMigrationState(
    supplied.migrationState ?? input.migrationState ?? environment.migrationState
  )
  const rolloutCohort = normalizeCohort(
    supplied.rolloutCohort ?? input.rolloutCohort ?? environment.rolloutCohort
  )

  return {
    config: {
      contractVersion: contractVersion ?? 0,
      minimumClientBuild: minimumClientBuild ?? 0,
      authorityMode,
      migrationState,
      rolloutCohort,
    },
    valid:
      contractVersion !== null &&
      contractVersion > 0 &&
      minimumClientBuild !== null &&
      minimumClientBuild > 0,
  }
}

function buildDecision(
  outcome: LedgerGateOutcome,
  reasonCode: string,
  config: LedgerGateConfig,
  clientBuild: number | null,
  clientContractVersion: number | null,
  migrationRequired = false
): LedgerGateDecision {
  return {
    outcome,
    status: outcome,
    reasonCode,
    allowed: outcome === 'supported',
    readOnly: outcome !== 'supported',
    migrationRequired,
    enforcementEnabled: LEDGER_ENFORCEMENT_ENABLED,
    contractVersion: config.contractVersion,
    minimumClientBuild: config.minimumClientBuild,
    rolloutCohort: config.rolloutCohort,
    authorityMode: config.authorityMode,
    migrationState: config.migrationState,
    clientBuild,
    clientContractVersion,
  }
}

export function evaluateLedgerGate(input: LedgerGateInput = {}): LedgerGateDecision {
  const { config, valid } = resolveConfig(input)
  const clientBuild = parseInteger(input.clientBuild ?? input.clientVersion)
  const clientContractVersion = parseInteger(input.clientContractVersion)

  if (!valid) {
    return buildDecision(
      'blocked',
      'invalid_server_configuration',
      config,
      clientBuild,
      clientContractVersion
    )
  }

  if (config.authorityMode !== LEDGER_AUTHORITY_MODES.API) {
    return buildDecision(
      'blocked',
      'authority_not_api',
      config,
      clientBuild,
      clientContractVersion
    )
  }

  if (config.migrationState === LEDGER_MIGRATION_STATES.FAILED) {
    return buildDecision(
      'blocked',
      'migration_failed',
      config,
      clientBuild,
      clientContractVersion,
      true
    )
  }

  if (config.migrationState === LEDGER_MIGRATION_STATES.BLOCKED) {
    return buildDecision(
      'blocked',
      'migration_blocked',
      config,
      clientBuild,
      clientContractVersion,
      true
    )
  }

  if (config.migrationState !== LEDGER_MIGRATION_STATES.COMPLETE) {
    return buildDecision(
      'migration_required',
      config.migrationState === LEDGER_MIGRATION_STATES.IN_PROGRESS
        ? 'migration_in_progress'
        : 'migration_not_started',
      config,
      clientBuild,
      clientContractVersion,
      true
    )
  }

  if (clientBuild === null) {
    return buildDecision(
      'unsupported_client',
      'client_build_missing',
      config,
      clientBuild,
      clientContractVersion
    )
  }

  if (clientBuild < config.minimumClientBuild) {
    return buildDecision(
      'unsupported_client',
      'client_build_too_old',
      config,
      clientBuild,
      clientContractVersion
    )
  }

  if (clientContractVersion !== null && clientContractVersion < config.contractVersion) {
    return buildDecision(
      'unsupported_client',
      'client_contract_too_old',
      config,
      clientBuild,
      clientContractVersion
    )
  }

  if (clientContractVersion !== null && clientContractVersion > config.contractVersion) {
    return buildDecision(
      'blocked',
      'client_contract_too_new',
      config,
      clientBuild,
      clientContractVersion
    )
  }

  return buildDecision('supported', 'supported', config, clientBuild, clientContractVersion)
}

export const getLedgerGateDecision = evaluateLedgerGate

export function readClientCapabilityHeaders(
  headers: Pick<Headers, 'get'>
): ClientCapabilityHeaders {
  const firstHeader = (names: string[]): string | null => {
    for (const name of names) {
      const value = headers.get(name)
      if (value !== null && value.trim() !== '') return value.trim()
    }
    return null
  }

  return {
    clientBuild: firstHeader([
      'x-client-build',
      'x-billbandit-client-build',
      'x-mobile-client-build',
    ]),
    clientContractVersion: firstHeader([
      'x-client-contract-version',
      'x-ledger-contract-version',
      'x-contract-version',
    ]),
  }
}

export function buildLedgerCapabilities(input: LedgerGateInput = {}): LedgerCapabilities {
  const decision = evaluateLedgerGate(input)
  return {
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
  }
}

export const isLedgerClientSupported = (input: LedgerGateInput = {}) =>
  evaluateLedgerGate(input).allowed
