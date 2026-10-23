import { Prisma, type PrismaClient } from '@prisma/client'
import { prisma } from '../prisma'
import { CURRENCY_EXPONENTS, getCurrencyExponent, normalizeCurrencyCode } from '../settlement/money/registry'

export const RATE_SOURCE = 'frankfurter.dev'
export const RATE_SOURCE_LABEL = 'Frankfurter reference rates'
/** Reference rates move once a day; refresh twice a day so a new day's rate appears by morning. */
export const RATE_MAX_AGE_MS = 12 * 60 * 60 * 1000

export type ProviderRate = { base: string; quote: string; rate: number; date: string }
export type RateFetcher = (base: string, quotes: string[]) => Promise<ProviderRate[]>

export type RateQuote = {
  quote: string
  quoteExponent: number
  rateDate: string
  /** Units of the quote currency that one unit of the base buys. */
  quotePerBase: string
  /** Units of the base currency that one unit of the quote buys. */
  basePerQuote: string
}

export type RatesResponse = {
  base: string
  baseExponent: number
  source: string
  fetchedAt: string | null
  stale: boolean
  rates: RateQuote[]
}

export class ExchangeRateUnavailableError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'ExchangeRateUnavailableError'
  }
}

export const frankfurterFetcher: RateFetcher = async (base, quotes) => {
  const url = new URL('https://api.frankfurter.dev/v2/rates')
  url.searchParams.set('base', base)
  url.searchParams.set('quotes', quotes.join(','))
  const response = await fetch(url, { headers: { Accept: 'application/json' }, cache: 'no-store' })
  if (!response.ok) throw new ExchangeRateUnavailableError(`Rate provider returned ${response.status} for ${base}`)
  const body: unknown = await response.json()
  if (!Array.isArray(body)) throw new ExchangeRateUnavailableError(`Rate provider sent an unexpected body for ${base}`)
  return body.flatMap((entry) => {
    if (!entry || typeof entry !== 'object') return []
    const { base: b, quote, rate, date } = entry as Record<string, unknown>
    if (typeof b !== 'string' || typeof quote !== 'string' || typeof rate !== 'number' || typeof date !== 'string') return []
    if (!Number.isFinite(rate) || rate <= 0) return []
    return [{ base: b.toUpperCase(), quote: quote.toUpperCase(), rate, date }]
  })
}

export function supportedRateCurrencies(): string[] {
  return Object.keys(CURRENCY_EXPONENTS).sort()
}

let inFlightRefresh: Promise<void> | null = null

/**
 * Fetches every supported base against every other supported currency, so each
 * direction keeps the provider's own precision instead of an inverted, rounded
 * figure. One refresh is shared by concurrent requests.
 */
export async function refreshExchangeRates(
  options: { db?: PrismaClient; fetcher?: RateFetcher; now?: Date } = {}
): Promise<void> {
  if (inFlightRefresh) return inFlightRefresh
  const db = options.db ?? prisma
  const fetcher = options.fetcher ?? frankfurterFetcher
  const now = options.now ?? new Date()
  const currencies = supportedRateCurrencies()
  inFlightRefresh = (async () => {
    const results = await Promise.allSettled(
      currencies.map((base) => fetcher(base, currencies.filter((quote) => quote !== base)))
    )
    const supported = new Set(currencies)
    const rows = results.flatMap((result) => (result.status === 'fulfilled' ? result.value : []))
      .filter((row) => supported.has(row.base) && supported.has(row.quote) && row.base !== row.quote)
    if (rows.length === 0) throw new ExchangeRateUnavailableError('No exchange rates could be fetched')
    await db.$transaction(
      rows.map((row) =>
        db.exchangeRate.upsert({
          where: { base_quote: { base: row.base, quote: row.quote } },
          create: {
            base: row.base,
            quote: row.quote,
            rate: new Prisma.Decimal(row.rate.toString()),
            rateDate: new Date(`${row.date}T00:00:00.000Z`),
            source: RATE_SOURCE,
            fetchedAt: now,
          },
          update: {
            rate: new Prisma.Decimal(row.rate.toString()),
            rateDate: new Date(`${row.date}T00:00:00.000Z`),
            source: RATE_SOURCE,
            fetchedAt: now,
          },
        })
      )
    )
  })().finally(() => {
    inFlightRefresh = null
  })
  return inFlightRefresh
}

function decimalString(value: Prisma.Decimal): string {
  return value.toFixed().replace(/(\.\d*?)0+$/, '$1').replace(/\.$/, '')
}

export async function getExchangeRates(
  rawBase: string,
  options: { db?: PrismaClient; fetcher?: RateFetcher; now?: Date } = {}
): Promise<RatesResponse> {
  const base = normalizeCurrencyCode(rawBase)
  const baseExponent = getCurrencyExponent(base)
  if (baseExponent === null) throw new ExchangeRateUnavailableError(`${base} is not a supported currency`)
  const db = options.db ?? prisma
  const now = options.now ?? new Date()
  const quotes = supportedRateCurrencies().filter((quote) => quote !== base)

  const load = () => db.exchangeRate.findMany({
    where: { OR: [{ base, quote: { in: quotes } }, { quote: base, base: { in: quotes } }] },
  })
  let rows = await load()
  const oldest = rows.reduce<Date | null>((min, row) => (min === null || row.fetchedAt < min ? row.fetchedAt : min), null)
  const complete = rows.length >= quotes.length * 2
  const fresh = oldest !== null && now.getTime() - oldest.getTime() < RATE_MAX_AGE_MS
  let refreshFailed = false
  if (!complete || !fresh) {
    try {
      await refreshExchangeRates({ db, fetcher: options.fetcher, now })
      rows = await load()
    } catch (error) {
      refreshFailed = true
      console.error('[exchange-rates] refresh failed; serving cached rates', error)
    }
  }

  const forward = new Map(rows.filter((row) => row.base === base).map((row) => [row.quote, row]))
  const reverse = new Map(rows.filter((row) => row.quote === base).map((row) => [row.base, row]))
  const rates: RateQuote[] = quotes.flatMap((quote) => {
    const out = forward.get(quote)
    const back = reverse.get(quote)
    if (!out && !back) return []
    const quotePerBase = out ? out.rate : new Prisma.Decimal(1).dividedBy(back!.rate)
    const basePerQuote = back ? back.rate : new Prisma.Decimal(1).dividedBy(out!.rate)
    const rateDate = (out ?? back)!.rateDate.toISOString().slice(0, 10)
    return [{
      quote,
      quoteExponent: CURRENCY_EXPONENTS[quote],
      rateDate,
      quotePerBase: decimalString(quotePerBase.toDecimalPlaces(12)),
      basePerQuote: decimalString(basePerQuote.toDecimalPlaces(12)),
    }]
  })
  if (rates.length === 0) throw new ExchangeRateUnavailableError(`No exchange rates are available for ${base}`)
  const newest = rows.reduce<Date | null>((max, row) => (max === null || row.fetchedAt > max ? row.fetchedAt : max), null)
  const oldestServed = rows.reduce<Date | null>((min, row) => (min === null || row.fetchedAt < min ? row.fetchedAt : min), null)
  return {
    base,
    baseExponent,
    source: RATE_SOURCE_LABEL,
    fetchedAt: newest?.toISOString() ?? null,
    stale: refreshFailed || oldestServed === null || now.getTime() - oldestServed.getTime() >= RATE_MAX_AGE_MS,
    rates,
  }
}
