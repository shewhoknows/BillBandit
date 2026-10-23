import { NextRequest, NextResponse } from 'next/server'
import { requireMobileSession } from '@/lib/mobile-auth'
import { ExchangeRateUnavailableError, getExchangeRates } from '@/lib/rates/exchange-rates'
import { isSupportedCurrency, normalizeCurrencyCode } from '@/lib/settlement/money/registry'

/** Reference rates for showing amounts in a person's own currency. Never used for ledger math. */
export async function GET(req: NextRequest) {
  const { session, response } = await requireMobileSession(req)
  if (!session) return response

  const { searchParams } = new URL(req.url)
  const base = normalizeCurrencyCode(searchParams.get('base') ?? session.user.defaultCurrency ?? 'INR')
  if (!isSupportedCurrency(base)) {
    return NextResponse.json({ error: 'UNSUPPORTED_CURRENCY', base }, { status: 400 })
  }

  try {
    const rates = await getExchangeRates(base)
    return NextResponse.json(rates, { headers: { 'Cache-Control': 'private, max-age=3600' } })
  } catch (error) {
    if (error instanceof ExchangeRateUnavailableError) {
      return NextResponse.json({ error: 'RATES_UNAVAILABLE', message: error.message }, { status: 503 })
    }
    console.error('[MOBILE GET /rates]', error)
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 })
  }
}
