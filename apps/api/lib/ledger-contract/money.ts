import { getCurrencyExponent, normalizeCurrencyCode } from '../settlement/money/registry'
import type { Money } from './types'

export type LedgerMoneyErrorCode =
  | 'INVALID_MONEY'
  | 'UNSUPPORTED_CURRENCY'
  | 'CURRENCY_MISMATCH'

export class LedgerMoneyError extends Error {
  constructor(
    public readonly code: LedgerMoneyErrorCode,
    message: string
  ) {
    super(message)
    this.name = 'LedgerMoneyError'
  }
}

const MINOR_UNITS_PATTERN = /^(0|-?[1-9]\d*)$/
const CURRENCY_CODE_PATTERN = /^[A-Z]{3}$/

function invalidMoney(message: string): never {
  throw new LedgerMoneyError('INVALID_MONEY', message)
}

function canonicalMinorUnits(value: unknown): string {
  if (typeof value !== 'string' || !MINOR_UNITS_PATTERN.test(value)) {
    return invalidMoney('minorUnits must be a canonical signed integer string')
  }
  return value
}

function canonicalCurrencyCode(value: unknown): string {
  if (typeof value !== 'string' || !CURRENCY_CODE_PATTERN.test(value)) {
    return invalidMoney('currencyCode must be an uppercase ISO 4217-style code')
  }
  if (getCurrencyExponent(value) === null) {
    throw new LedgerMoneyError('UNSUPPORTED_CURRENCY', `Unsupported currency: ${value}`)
  }
  return value
}

function canonicalExponent(value: unknown, currencyCode: string): number {
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0 || value > 9) {
    return invalidMoney('currencyExponent must be an integer from 0 through 9')
  }
  const registered = getCurrencyExponent(currencyCode)
  if (registered === null) {
    throw new LedgerMoneyError('UNSUPPORTED_CURRENCY', `Unsupported currency: ${currencyCode}`)
  }
  if (registered !== value) {
    return invalidMoney(
      `currencyExponent ${value} does not match ${currencyCode}'s registered exponent ${registered}`
    )
  }
  return value
}

function moneyRecord(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    return invalidMoney('money must be an object')
  }
  return value as Record<string, unknown>
}

/** Parse a JSON money value and reject numeric minor units or exponent drift. */
export function parseMoney(value: unknown): Money {
  const record = moneyRecord(value)
  const minorUnits = canonicalMinorUnits(record.minorUnits)
  const currencyCode = canonicalCurrencyCode(record.currencyCode)
  const currencyExponent = canonicalExponent(record.currencyExponent, currencyCode)
  return { minorUnits, currencyCode, currencyExponent }
}

export const assertMoney = parseMoney
export const assertExactMoney = parseMoney

/** Construct money without accepting a floating-point major-unit value. */
export function createMoney(
  minorUnits: string | bigint,
  currencyCode: string,
  currencyExponent?: number
): Money {
  if (typeof minorUnits !== 'string' && typeof minorUnits !== 'bigint') {
    return invalidMoney('minorUnits must be a string or bigint')
  }
  const normalizedCode = normalizeCurrencyCode(currencyCode)
  const registeredExponent = getCurrencyExponent(normalizedCode)
  if (registeredExponent === null) {
    throw new LedgerMoneyError('UNSUPPORTED_CURRENCY', `Unsupported currency: ${normalizedCode}`)
  }
  const result = {
    minorUnits: minorUnits.toString(),
    currencyCode: normalizedCode,
    currencyExponent: currencyExponent ?? registeredExponent,
  }
  return parseMoney(result)
}

export function moneyToBigInt(value: Money): bigint {
  return BigInt(parseMoney(value).minorUnits)
}

function assertSameCurrency(a: Money, b: Money): [Money, Money] {
  const left = parseMoney(a)
  const right = parseMoney(b)
  if (
    left.currencyCode !== right.currencyCode ||
    left.currencyExponent !== right.currencyExponent
  ) {
    throw new LedgerMoneyError(
      'CURRENCY_MISMATCH',
      `Cannot combine ${left.currencyCode} and ${right.currencyCode} without an explicit conversion`
    )
  }
  return [left, right]
}

export function moneyEquals(a: Money, b: Money): boolean {
  const left = parseMoney(a)
  const right = parseMoney(b)
  return (
    left.currencyCode === right.currencyCode &&
    left.currencyExponent === right.currencyExponent &&
    left.minorUnits === right.minorUnits
  )
}

export function addMoney(a: Money, b: Money): Money {
  const [left, right] = assertSameCurrency(a, b)
  return createMoney(moneyToBigInt(left) + moneyToBigInt(right), left.currencyCode, left.currencyExponent)
}

export function subtractMoney(a: Money, b: Money): Money {
  const [left, right] = assertSameCurrency(a, b)
  return createMoney(moneyToBigInt(left) - moneyToBigInt(right), left.currencyCode, left.currencyExponent)
}

export function negateMoney(value: Money): Money {
  const money = parseMoney(value)
  return createMoney(-moneyToBigInt(money), money.currencyCode, money.currencyExponent)
}

export function compareMoney(a: Money, b: Money): -1 | 0 | 1 {
  const [left, right] = assertSameCurrency(a, b)
  const leftMinorUnits = moneyToBigInt(left)
  const rightMinorUnits = moneyToBigInt(right)
  if (leftMinorUnits < rightMinorUnits) return -1
  if (leftMinorUnits > rightMinorUnits) return 1
  return 0
}

export function isZeroMoney(value: Money): boolean {
  return moneyToBigInt(parseMoney(value)) === 0n
}

/**
 * Aggregate only within a currency. The sorted result makes balance output
 * deterministic and deliberately prevents accidental mixed-currency netting.
 */
export function aggregateMoneyByCurrency(values: readonly Money[]): Money[] {
  const totals = new Map<string, Money>()
  for (const value of values) {
    const money = parseMoney(value)
    const key = `${money.currencyCode}:${money.currencyExponent}`
    const existing = totals.get(key)
    totals.set(key, existing ? addMoney(existing, money) : money)
  }
  return Array.from(totals.values()).sort(
    (a, b) =>
      a.currencyCode.localeCompare(b.currencyCode) || a.currencyExponent - b.currencyExponent
  )
}

export function formatExactMoney(value: Money): string {
  const money = parseMoney(value)
  const minorUnits = moneyToBigInt(money)
  const negative = minorUnits < 0n
  const absolute = negative ? -minorUnits : minorUnits
  if (money.currencyExponent === 0) {
    return `${money.currencyCode} ${negative ? '-' : ''}${absolute.toString()}`
  }
  const factor = 10n ** BigInt(money.currencyExponent)
  const whole = absolute / factor
  const fraction = (absolute % factor).toString().padStart(money.currencyExponent, '0')
  return `${money.currencyCode} ${negative ? '-' : ''}${whole.toString()}.${fraction}`
}
