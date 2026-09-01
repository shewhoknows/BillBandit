import { getCurrencyExponent, normalizeCurrencyCode } from './registry'

export type CanonicalAmount = {
  currencyCode: string
  currencyExponent: number
  minorUnits: bigint
}

export type MoneyConversionError =
  | { code: 'UNSUPPORTED_CURRENCY'; currencyCode: string }
  | { code: 'NONREPRESENTABLE'; currencyCode: string; floatText: string }

export function amountsEqual(a: CanonicalAmount, b: CanonicalAmount): boolean {
  return (
    a.currencyCode === b.currencyCode &&
    a.currencyExponent === b.currencyExponent &&
    a.minorUnits === b.minorUnits
  )
}

export function formatMinorUnits(amount: CanonicalAmount): string {
  const { minorUnits, currencyExponent } = amount
  const negative = minorUnits < BigInt(0)
  const abs = negative ? -minorUnits : minorUnits
  if (currencyExponent === 0) {
    return `${negative ? '-' : ''}${abs.toString()}`
  }
  const factor = BigInt(10) ** BigInt(currencyExponent)
  const whole = abs / factor
  const frac = abs % factor
  const fracStr = frac.toString().padStart(currencyExponent, '0')
  return `${negative ? '-' : ''}${whole.toString()}.${fracStr}`
}

export function parseDecimalToMinorUnits(
  floatText: string,
  currencyCode: string
): CanonicalAmount | MoneyConversionError {
  const normalized = normalizeCurrencyCode(currencyCode)
  const exponent = getCurrencyExponent(normalized)
  if (exponent === null) {
    return { code: 'UNSUPPORTED_CURRENCY', currencyCode: normalized }
  }

  const trimmed = floatText.trim()
  if (!/^-?\d+(\.\d+)?$/.test(trimmed)) {
    return { code: 'NONREPRESENTABLE', currencyCode: normalized, floatText: trimmed }
  }

  const negative = trimmed.startsWith('-')
  const unsigned = negative ? trimmed.slice(1) : trimmed
  const [wholePart, fracPart = ''] = unsigned.split('.')
  const paddedFrac = fracPart.padEnd(exponent, '0').slice(0, exponent)
  if (fracPart.length > exponent) {
    const remainder = fracPart.slice(exponent)
    if (/[1-9]/.test(remainder)) {
      return { code: 'NONREPRESENTABLE', currencyCode: normalized, floatText: trimmed }
    }
  }

  const minorStr = `${wholePart}${paddedFrac}`.replace(/^0+(?=\d)/, '') || '0'
  let minorUnits = BigInt(minorStr)
  if (negative) minorUnits = -minorUnits

  const roundTrip = formatMinorUnits({ currencyCode: normalized, currencyExponent: exponent, minorUnits })
  const normalizedInput = trimmed.includes('.')
    ? trimmed.replace(/\.?0+$/, '').replace(/\.$/, '')
    : trimmed
  const normalizedRoundTrip = roundTrip.replace(/\.?0+$/, '').replace(/\.$/, '')
  if (normalizedRoundTrip !== normalizedInput && roundTrip !== trimmed) {
    return { code: 'NONREPRESENTABLE', currencyCode: normalized, floatText: trimmed }
  }

  return { currencyCode: normalized, currencyExponent: exponent, minorUnits }
}

export function floatToMinorUnits(
  value: number,
  currencyCode: string
): CanonicalAmount | MoneyConversionError {
  // Read through database text representation for exact parsing
  const floatText = value.toFixed(10).replace(/\.?0+$/, '')
  return parseDecimalToMinorUnits(floatText.includes('.') ? floatText : `${floatText}`, currencyCode)
}

export function minorUnitsToFloat(amount: CanonicalAmount): number {
  const factor = 10 ** amount.currencyExponent
  return Number(amount.minorUnits) / factor
}
