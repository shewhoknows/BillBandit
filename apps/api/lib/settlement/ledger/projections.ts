import { buildPlanTransferId } from '../money/transfer-id'
import type { CanonicalAmount } from '../money/canonical'
import { aggregateComponents, buildObligationComponents, netReciprocalObligations } from './obligations'
import type {
  AllocationPath,
  AllocationSnapshot,
  GroupLedgerInput,
  ParticipantNetBalance,
  PlanTransfer,
  SettlementRecord,
} from './types'

type DirectedEdge = {
  debtorParticipantId: string
  creditorParticipantId: string
  capacity: bigint
  componentKeys: string[]
  currency: CanonicalAmount
}

function cloneEdges(edges: DirectedEdge[]): DirectedEdge[] {
  return edges.map((e) => ({ ...e, componentKeys: [...e.componentKeys] }))
}

function allocatePath(
  edges: DirectedEdge[],
  amount: CanonicalAmount,
  payerParticipantId: string,
  recipientParticipantId: string
): AllocationPath[] {
  const paths: AllocationPath[] = []
  let remaining = amount.minorUnits

  while (remaining > 0n) {
    const route = findShortestRoute(edges, amount.currencyCode, payerParticipantId, recipientParticipantId)
    if (!route || route.hops.length === 0) break

    let bottleneck = remaining
    for (const hop of route.hops) {
      const edge = edges.find(
        (e) =>
          e.debtorParticipantId === hop.from &&
          e.creditorParticipantId === hop.to &&
          e.capacity > 0n
      )
      if (!edge) {
        bottleneck = BigInt(0)
        break
      }
      if (edge.capacity < bottleneck) bottleneck = edge.capacity
    }
    if (bottleneck <= 0n) break

    for (const hop of route.hops) {
      const edge = edges.find(
        (e) =>
          e.debtorParticipantId === hop.from &&
          e.creditorParticipantId === hop.to
      )
      if (!edge) continue
      paths.push({
        payerParticipantId: hop.from,
        recipientParticipantId: hop.to,
        flowMinorUnits: bottleneck,
        obligationComponentKeys: [...edge.componentKeys],
      })
      edge.capacity -= bottleneck
    }
    remaining -= bottleneck
  }

  if (remaining > 0n) {
    paths.push({
      payerParticipantId: recipientParticipantId,
      recipientParticipantId: payerParticipantId,
      flowMinorUnits: remaining,
      obligationComponentKeys: ['residual-credit'],
    })
  }

  return paths
}

function findShortestRoute(
  edges: DirectedEdge[],
  currencyCode: string,
  start: string,
  end: string
): { hops: Array<{ from: string; to: string }> } | null {
  if (start === end) return null

  const queue: Array<{ node: string; path: string[] }> = [{ node: start, path: [start] }]
  const visited = new Set<string>([start])

  while (queue.length > 0) {
    const current = queue.shift()!
    const outgoing = edges
      .filter(
        (e) =>
          e.currency.currencyCode === currencyCode &&
          e.capacity > 0n &&
          e.debtorParticipantId === current.node
      )
      .sort((a, b) => a.creditorParticipantId.localeCompare(b.creditorParticipantId))

    for (const edge of outgoing) {
      const next = edge.creditorParticipantId
      if (visited.has(next)) continue
      const path = [...current.path, next]
      if (next === end) {
        const hops: Array<{ from: string; to: string }> = []
        for (let i = 0; i < path.length - 1; i++) {
          hops.push({ from: path[i], to: path[i + 1] })
        }
        return { hops }
      }
      visited.add(next)
      queue.push({ node: next, path })
    }
  }

  return null
}

function applySettlement(edges: DirectedEdge[], settlement: SettlementRecord): void {
  if (settlement.reversed) return

  const paths = settlement.snapshot?.paths.length
    ? settlement.snapshot.paths
    : allocatePath(edges, settlement.amount, settlement.payerParticipantId, settlement.recipientParticipantId)

  for (const path of paths) {
    if (path.obligationComponentKeys[0] === 'residual-credit') continue
    const direct = edges.find(
      (e) =>
        e.debtorParticipantId === path.payerParticipantId &&
        e.creditorParticipantId === path.recipientParticipantId &&
        e.capacity > 0n
    )
    if (direct) {
      direct.capacity -= path.flowMinorUnits
      if (direct.capacity < 0n) direct.capacity = 0n
    }
  }
}

function buildInitialEdges(input: GroupLedgerInput): DirectedEdge[] {
  const components = buildObligationComponents(input)
  const aggregated = aggregateComponents(components)
  const netted = netReciprocalObligations(aggregated)

  return Array.from(netted.values()).map((c) => ({
    debtorParticipantId: c.debtorParticipantId,
    creditorParticipantId: c.creditorParticipantId,
    capacity: c.amount.minorUnits,
    componentKeys: c.keys,
    currency: c.amount,
  }))
}

function computeNetBalances(edges: DirectedEdge[]): ParticipantNetBalance[] {
  const map = new Map<string, ParticipantNetBalance>()

  const touch = (participantId: string, currency: CanonicalAmount, delta: bigint) => {
    const key = `${participantId}:${currency.currencyCode}`
    const existing = map.get(key)
    if (existing) {
      existing.netMinorUnits += delta
      return
    }
    map.set(key, {
      participantId,
      currencyCode: currency.currencyCode,
      currencyExponent: currency.currencyExponent,
      netMinorUnits: delta,
    })
  }

  for (const edge of edges) {
    if (edge.capacity <= 0n) continue
    touch(edge.debtorParticipantId, edge.currency, -edge.capacity)
    touch(edge.creditorParticipantId, edge.currency, edge.capacity)
  }

  return Array.from(map.values()).filter((b) => b.netMinorUnits !== 0n)
}

export function buildDirectPlan(input: GroupLedgerInput): PlanTransfer[] {
  const edges = cloneEdges(buildInitialEdges(input))
  const effective = [...input.settlements]
    .filter((s) => !s.reversed)
    .sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime() || a.id.localeCompare(b.id))

  for (const settlement of effective) {
    applySettlement(edges, settlement)
  }

  const transfers: PlanTransfer[] = []
  for (const edge of edges) {
    if (edge.capacity <= 0n) continue
    const amount: CanonicalAmount = { ...edge.currency, minorUnits: edge.capacity }
    transfers.push({
      planTransferId: buildPlanTransferId({
        groupId: input.groupId,
        settlementVersion: input.settlementVersion,
        mode: 'DIRECT',
        amount,
        payerParticipantId: edge.debtorParticipantId,
        recipientParticipantId: edge.creditorParticipantId,
      }),
      payerParticipantId: edge.debtorParticipantId,
      recipientParticipantId: edge.creditorParticipantId,
      amount,
      mode: 'DIRECT',
    })
  }

  return transfers.sort((a, b) => a.planTransferId.localeCompare(b.planTransferId))
}

export function buildSimplifiedPlan(input: GroupLedgerInput): PlanTransfer[] {
  const edges = cloneEdges(buildInitialEdges(input))
  const effective = [...input.settlements]
    .filter((s) => !s.reversed)
    .sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime() || a.id.localeCompare(b.id))

  for (const settlement of effective) {
    applySettlement(edges, settlement)
  }

  const nets = computeNetBalances(edges)
  const byCurrency = new Map<string, ParticipantNetBalance[]>()
  for (const net of nets) {
    const list = byCurrency.get(net.currencyCode) ?? []
    list.push(net)
    byCurrency.set(net.currencyCode, list)
  }

  const transfers: PlanTransfer[] = []

  for (const [currencyCode, balances] of byCurrency) {
    const debtors = balances
      .filter((b) => b.netMinorUnits < 0n)
      .map((b) => ({ participantId: b.participantId, amount: -b.netMinorUnits, exponent: b.currencyExponent }))
      .sort((a, b) => (b.amount > a.amount ? 1 : b.amount < a.amount ? -1 : a.participantId.localeCompare(b.participantId)))

    const creditors = balances
      .filter((b) => b.netMinorUnits > 0n)
      .map((b) => ({ participantId: b.participantId, amount: b.netMinorUnits, exponent: b.currencyExponent }))
      .sort((a, b) => (b.amount > a.amount ? 1 : b.amount < a.amount ? -1 : a.participantId.localeCompare(b.participantId)))

    let di = 0
    let ci = 0
    while (di < debtors.length && ci < creditors.length) {
      const debtor = debtors[di]
      const creditor = creditors[ci]
      const flow = debtor.amount < creditor.amount ? debtor.amount : creditor.amount
      if (flow > 0n) {
        const amount: CanonicalAmount = {
          currencyCode,
          currencyExponent: debtor.exponent,
          minorUnits: flow,
        }
        transfers.push({
          planTransferId: buildPlanTransferId({
            groupId: input.groupId,
            settlementVersion: input.settlementVersion,
            mode: 'SIMPLIFIED',
            amount,
            payerParticipantId: debtor.participantId,
            recipientParticipantId: creditor.participantId,
          }),
          payerParticipantId: debtor.participantId,
          recipientParticipantId: creditor.participantId,
          amount,
          mode: 'SIMPLIFIED',
        })
      }
      debtor.amount -= flow
      creditor.amount -= flow
      if (debtor.amount === 0n) di++
      if (creditor.amount === 0n) ci++
    }
  }

  const aggregated = new Map<string, PlanTransfer>()
  for (const transfer of transfers) {
    const key = `${transfer.payerParticipantId}:${transfer.recipientParticipantId}:${transfer.amount.currencyCode}`
    const existing = aggregated.get(key)
    if (!existing) {
      aggregated.set(key, transfer)
      continue
    }
    existing.amount = {
      ...existing.amount,
      minorUnits: existing.amount.minorUnits + transfer.amount.minorUnits,
    }
    existing.planTransferId = buildPlanTransferId({
      groupId: input.groupId,
      settlementVersion: input.settlementVersion,
      mode: 'SIMPLIFIED',
      amount: existing.amount,
      payerParticipantId: existing.payerParticipantId,
      recipientParticipantId: existing.recipientParticipantId,
    })
  }

  return Array.from(aggregated.values()).sort((a, b) => a.planTransferId.localeCompare(b.planTransferId))
}

export function buildPlan(input: GroupLedgerInput): PlanTransfer[] {
  return input.simplifyDebts ? buildSimplifiedPlan(input) : buildDirectPlan(input)
}

export function computeParticipantNets(input: GroupLedgerInput): ParticipantNetBalance[] {
  const edges = cloneEdges(buildInitialEdges(input))
  const effective = [...input.settlements]
    .filter((s) => !s.reversed)
    .sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime() || a.id.localeCompare(b.id))
  for (const settlement of effective) applySettlement(edges, settlement)
  return computeNetBalances(edges)
}

export function allocateSettlementPaths(
  input: GroupLedgerInput,
  payerParticipantId: string,
  recipientParticipantId: string,
  amount: CanonicalAmount,
  mode: 'DIRECT' | 'SIMPLIFIED'
): AllocationSnapshot {
  const edges = cloneEdges(buildInitialEdges(input))
  const effective = [...input.settlements]
    .filter((s) => !s.reversed)
    .sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime() || a.id.localeCompare(b.id))
  for (const settlement of effective) applySettlement(edges, settlement)

  const paths = allocatePath(edges, amount, payerParticipantId, recipientParticipantId)
  return {
    settlementVersion: input.settlementVersion,
    mode,
    algorithmVersion: 1,
    amount,
    paths,
  }
}

export function planIsEmpty(transfers: PlanTransfer[]): boolean {
  return transfers.length === 0
}
