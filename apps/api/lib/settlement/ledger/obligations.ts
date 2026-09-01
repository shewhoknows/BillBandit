import type { CanonicalAmount } from '../money/canonical'
import type { GroupLedgerInput, ObligationComponent, ParticipantRef } from './types'

function participantForUser(participants: ParticipantRef[], userId: string): string | null {
  return participants.find((p) => p.userId === userId)?.id ?? null
}

export function buildObligationComponents(input: GroupLedgerInput): ObligationComponent[] {
  const components: ObligationComponent[] = []

  for (const expense of input.expenses) {
    const creditorId = participantForUser(input.participants, expense.paidByUserId)
    if (!creditorId) continue

    for (const split of expense.splits) {
      if (split.userId === expense.paidByUserId) continue
      const debtorId = participantForUser(input.participants, split.userId)
      if (!debtorId || debtorId === creditorId) continue

      const amount: CanonicalAmount = {
        currencyCode: expense.currency.toUpperCase(),
        currencyExponent: split.currencyExponent,
        minorUnits: split.amountMinorUnits,
      }

      components.push({
        key: `${expense.id}:${split.id}:${debtorId}:${creditorId}`,
        expenseId: expense.id,
        splitId: split.id,
        debtorParticipantId: debtorId,
        creditorParticipantId: creditorId,
        amount,
      })
    }
  }

  return components
}

export function aggregateComponents(components: ObligationComponent[]): Map<string, ObligationComponent & { keys: string[] }> {
  const map = new Map<string, ObligationComponent & { keys: string[] }>()

  for (const component of components) {
    const pairKey = [
      component.amount.currencyCode,
      component.debtorParticipantId,
      component.creditorParticipantId,
    ].join(':')

    const existing = map.get(pairKey)
    if (!existing) {
      map.set(pairKey, { ...component, keys: [component.key] })
      continue
    }

    existing.amount = {
      ...existing.amount,
      minorUnits: existing.amount.minorUnits + component.amount.minorUnits,
    }
    existing.keys.push(component.key)
  }

  return map
}

export function netReciprocalObligations(
  aggregated: Map<string, ObligationComponent & { keys: string[] }>
): Map<string, ObligationComponent & { keys: string[] }> {
  const byPair = new Map<string, ObligationComponent & { keys: string[] }>()

  for (const [, component] of Array.from(aggregated.entries())) {
    const forwardKey = `${component.amount.currencyCode}:${component.debtorParticipantId}:${component.creditorParticipantId}`
    const reverseKey = `${component.amount.currencyCode}:${component.creditorParticipantId}:${component.debtorParticipantId}`

    const reverse = byPair.get(reverseKey)
    if (reverse && reverse.debtorParticipantId === component.creditorParticipantId) {
      const net = component.amount.minorUnits - reverse.amount.minorUnits
      if (net > 0n) {
        byPair.delete(reverseKey)
        byPair.set(forwardKey, {
          ...component,
          amount: { ...component.amount, minorUnits: net },
          keys: [...component.keys, ...reverse.keys],
        })
      } else if (net < 0n) {
        reverse.amount = { ...reverse.amount, minorUnits: -net }
        reverse.keys = [...reverse.keys, ...component.keys]
      } else {
        byPair.delete(reverseKey)
      }
      continue
    }

    const existing = byPair.get(forwardKey)
    if (existing) {
      existing.amount = {
        ...existing.amount,
        minorUnits: existing.amount.minorUnits + component.amount.minorUnits,
      }
      existing.keys.push(...component.keys)
    } else {
      byPair.set(forwardKey, { ...component })
    }
  }

  return byPair
}
