import { createHash } from 'crypto'
import type { CanonicalAmount } from './canonical'

export type TransferIdInput = {
  groupId: string
  settlementVersion: number
  mode: 'DIRECT' | 'SIMPLIFIED'
  amount: CanonicalAmount
  payerParticipantId: string
  recipientParticipantId: string
}

export function buildPlanTransferId(input: TransferIdInput): string {
  const canonical = [
    'settle-up:v2',
    input.groupId,
    String(input.settlementVersion),
    input.mode,
    input.amount.currencyCode,
    String(input.amount.currencyExponent),
    input.amount.minorUnits.toString(),
    input.payerParticipantId,
    input.recipientParticipantId,
  ].join('\n')

  return createHash('sha256').update(canonical).digest('base64url')
}
