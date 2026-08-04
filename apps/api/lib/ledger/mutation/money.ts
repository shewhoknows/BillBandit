import { parseMoney } from '../../ledger-contract/money'
import { LedgerMoneyError } from '../../ledger-contract/money'
import type { Money } from '../../ledger-contract/types'

export type CanonicalMutationMoney = {
  currencyCode: string
  currencyExponent: number
  minorUnits: bigint
}

export function parseMutationMoney(value: unknown, field = 'amount'): CanonicalMutationMoney {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new LedgerMoneyError('INVALID_MONEY', `${field} must use exact minor-unit money`)
  }

  const input = value as Record<string, unknown>
  const minorUnits = typeof input.minorUnits === 'bigint' ? input.minorUnits.toString() : input.minorUnits
  if (typeof minorUnits !== 'string') {
    throw new LedgerMoneyError('INVALID_MONEY', `${field}.minorUnits must be a string or bigint`)
  }

  const parsed = parseMoney({
    minorUnits,
    currencyCode: input.currencyCode,
    currencyExponent: input.currencyExponent,
  })
  return {
    currencyCode: parsed.currencyCode,
    currencyExponent: parsed.currencyExponent,
    minorUnits: BigInt(parsed.minorUnits),
  }
}

export function moneyFromParts(input: {
  minorUnits: string | bigint
  currencyCode: string
  currencyExponent: number
}): CanonicalMutationMoney {
  return parseMutationMoney(input)
}

export function sameMutationMoney(
  left: CanonicalMutationMoney,
  right: CanonicalMutationMoney
): boolean {
  return (
    left.currencyCode === right.currencyCode &&
    left.currencyExponent === right.currencyExponent &&
    left.minorUnits === right.minorUnits
  )
}

export function sumMutationMoney(values: readonly CanonicalMutationMoney[], field = 'splits'):
  | CanonicalMutationMoney
  | null {
  if (values.length === 0) return null
  const first = values[0]
  let total = 0n
  for (const value of values) {
    if (
      value.currencyCode !== first.currencyCode ||
      value.currencyExponent !== first.currencyExponent
    ) {
      throw new LedgerMoneyError('CURRENCY_MISMATCH', `${field} must use one currency`)
    }
    total += value.minorUnits
  }
  return { ...first, minorUnits: total }
}

/**
 * Legacy DOUBLE PRECISION columns are retained as a derived compatibility
 * mirror only. All validation and writes use the exact fields above.
 */
export function legacyMajorUnits(value: CanonicalMutationMoney): number {
  const major = Number(value.minorUnits) / 10 ** value.currencyExponent
  if (!Number.isFinite(major)) {
    throw new LedgerMoneyError('INVALID_MONEY', 'Exact amount cannot be mirrored to the legacy column')
  }
  return major
}

export function exactMoneyFields(value: CanonicalMutationMoney): {
  amountMinorUnits: bigint
  currencyExponent: number
  currency: string
} {
  return {
    amountMinorUnits: value.minorUnits,
    currencyExponent: value.currencyExponent,
    currency: value.currencyCode,
  }
}

export function asContractMoney(value: CanonicalMutationMoney): Money {
  return {
    minorUnits: value.minorUnits.toString(),
    currencyCode: value.currencyCode,
    currencyExponent: value.currencyExponent,
  }
}
