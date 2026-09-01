export async function register() {
  if (process.env.NEXT_RUNTIME === 'nodejs') {
    const { bootstrapSettlementOutbox } = await import('./lib/settlement/outbox/bootstrap')
    bootstrapSettlementOutbox()
  }
}
