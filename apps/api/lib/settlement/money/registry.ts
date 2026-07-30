export const CURRENCY_REGISTRY_VERSION = 1

/** Explicit versioned currency-exponent registry. No default exponent. */
export const CURRENCY_EXPONENTS: Readonly<Record<string, number>> = {
  USD: 2,
  EUR: 2,
  GBP: 2,
  JPY: 0,
  CAD: 2,
  AUD: 2,
  INR: 2,
  CNY: 2,
  BRL: 2,
  MXN: 2,
  KWD: 3,
  BHD: 3,
  OMR: 3,
}

export function normalizeCurrencyCode(code: string): string {
  return code.trim().toUpperCase()
}

export function getCurrencyExponent(code: string): number | null {
  const normalized = normalizeCurrencyCode(code)
  const exponent = CURRENCY_EXPONENTS[normalized]
  return exponent === undefined ? null : exponent
}

export function isSupportedCurrency(code: string): boolean {
  return getCurrencyExponent(code) !== null
}
