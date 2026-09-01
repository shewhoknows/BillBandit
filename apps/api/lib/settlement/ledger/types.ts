import type { CanonicalAmount } from '../money/canonical'
import type { SettlementMode } from '@prisma/client'

export type ParticipantRef = {
  id: string
  userId: string
  displayName: string
  status: 'ACTIVE' | 'DEPARTED'
}

export type ObligationComponent = {
  key: string
  expenseId: string
  splitId: string
  debtorParticipantId: string
  creditorParticipantId: string
  amount: CanonicalAmount
}

export type AllocationPath = {
  payerParticipantId: string
  recipientParticipantId: string
  flowMinorUnits: bigint
  obligationComponentKeys: string[]
}

export type AllocationSnapshot = {
  settlementVersion: number
  mode: SettlementMode
  algorithmVersion: number
  amount: CanonicalAmount
  paths: AllocationPath[]
}

export type SettlementRecord = {
  id: string
  payerParticipantId: string
  recipientParticipantId: string
  amount: CanonicalAmount
  mode: SettlementMode
  createdAt: Date
  reversed: boolean
  snapshot: AllocationSnapshot | null
}

export type PlanTransfer = {
  planTransferId: string
  payerParticipantId: string
  recipientParticipantId: string
  amount: CanonicalAmount
  mode: SettlementMode
}

export type ParticipantNetBalance = {
  participantId: string
  currencyCode: string
  currencyExponent: number
  netMinorUnits: bigint
}

export type GroupLedgerInput = {
  groupId: string
  settlementVersion: number
  simplifyDebts: boolean
  participants: ParticipantRef[]
  expenses: Array<{
    id: string
    paidByUserId: string
    currency: string
    splits: Array<{ id: string; userId: string; amountMinorUnits: bigint; currencyExponent: number }>
    amountMinorUnits: bigint
    currencyExponent: number
  }>
  settlements: SettlementRecord[]
}
