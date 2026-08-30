/**
 * Phase 8 compatibility graph and sequence search (P6, P7, P8, P9).
 *
 * The whole point of the phase is that loop scale is a property of the
 * sequence, not of any anchor's own start distance. So nothing here pins a
 * shell: anchors are connected by estimated anchor-to-anchor cost, and a
 * sequence is judged by the perimeter those edges add up to.
 */
import { compactness, haversine, type LngLat } from '../../src/loops/geo.js'
import { MAX_LEG_SHARE, MIN_COMPACTNESS, MIN_LEG_SHARE } from '../../src/loops/quality.js'
import { angleGap, median, pairFeatures, signedTurn, type Field, type Node, type PairFeatures } from './field.mjs'

export type Edge = {
  from: number; to: number; features: PairFeatures
  estimate: number; probed: number | null; cost: number; penalty: number
}
export type Compatibility = {
  pool: Node[]; stretch: number; probes: Array<[number, number]>
  edges: Map<string, Edge>; out: Map<number, Edge[]>
}
export type Sequence = {
  fixture: string; family: string; direction: 1 | -1; anchors: Node[]
  predicted: number; legs: number[]; penalty: number; rank: number; probedEdges: number
  shape: number; maxShare: number; minShare: number
}

const key = (a: number, b: number) => `${a}:${b}`

/**
 * Topological penalty for using A->B as a loop edge. Each term is a
 * redundancy or reversal risk, not a distance: distance is scored separately
 * by the perimeter, and mixing the two is how Phase 6 overstated its ceiling.
 */
function penalise(field: Field, a: Node, b: Node, features: PairFeatures, direction: 1 | -1) {
  const turn = signedTurn(features.bearingA, features.bearingB)
  const progression = turn * direction
  const separation = features.crow / field.targetMetres
  return features.sharedFraction * 2                                  // shared start-tree ancestry
    + Math.min(1, features.sharedEdges / 20) * 0.5                    // shared physical corridor out of the start
    + Math.max(0, 0.12 - separation) * 8                              // anchors too close together
    + (progression <= 0 ? 1.5 : 0)                                    // no rotational progress
    + angleGap(Math.abs(progression), 120) / 180                      // uneven three-corner spacing
}

/**
 * Sparse compatibility graph. Estimates are free, so sparsity is about
 * bounding the search and about which pairs are worth a real probe; each
 * anchor keeps only its best `fanout` successors in each rotational sense.
 */
export function buildCompatibility(
  field: Field, pool: Node[], probed: Map<string, number>, options: { fanout: number; probeBudget: number },
): Compatibility {
  const all: Edge[] = []
  for (const a of pool) for (const b of pool) {
    if (a.node === b.node) continue
    const features = pairFeatures(field, a, b)
    all.push({ from: a.node, to: b.node, features, estimate: 0, probed: null, cost: 0, penalty: 0 })
  }
  // Calibrate the estimator on a deterministic spread of probed pairs. This is
  // the one thing the probes buy: a request-scoped network stretch, after
  // which every remaining pair is estimated for nothing.
  const probes: Array<[number, number]> = []
  const undirected = all.filter(edge => edge.from < edge.to)
    .sort((x, y) => x.features.crow - y.features.crow || x.from - y.from || x.to - y.to)
  const step = Math.max(1, Math.floor(undirected.length / Math.max(1, options.probeBudget)))
  const sampled: Edge[] = []
  for (let index = 0; index < undirected.length && sampled.length < options.probeBudget; index += step) {
    const edge = undirected[index]
    const value = probed.get(key(edge.from, edge.to)) ?? probed.get(key(edge.to, edge.from))
    if (value === undefined) continue
    sampled.push(edge); probes.push([edge.from, edge.to])
  }
  const stretch = sampled.length
    ? median(sampled.map(edge => (probed.get(key(edge.from, edge.to)) ?? probed.get(key(edge.to, edge.from)))! / Math.max(1, edge.features.crow)))
    : median(pool.map(node => node.networkMetres / Math.max(1, field.crow(node))))

  const edges = new Map<string, Edge>()
  for (const edge of all) {
    const measured = probes.some(([a, b]) => (a === edge.from && b === edge.to) || (a === edge.to && b === edge.from))
      ? probed.get(key(edge.from, edge.to)) ?? probed.get(key(edge.to, edge.from)) ?? null
      : null
    edge.estimate = edge.features.crow * stretch
    edge.probed = measured ?? null
    edge.cost = measured ?? edge.estimate
    edges.set(key(edge.from, edge.to), edge)
  }
  const out = new Map<number, Edge[]>()
  for (const a of pool) {
    const ranked = pool.filter(b => b.node !== a.node).map(b => edges.get(key(a.node, b.node))!)
    const best = new Set<Edge>()
    for (const direction of [1, -1] as const) {
      const forward = ranked.filter(edge => signedTurn(edge.features.bearingA, edge.features.bearingB) * direction > 0)
        .map(edge => ({ edge, penalty: penalise(field, a, pool.find(n => n.node === edge.to)!, edge.features, direction) }))
        .sort((x, y) => x.penalty - y.penalty || x.edge.to - y.edge.to)
      // An ordered pair is admissible in exactly one rotational sense, so the
      // penalty is assigned rather than merged.
      for (const entry of forward.slice(0, options.fanout)) { entry.edge.penalty = entry.penalty; best.add(entry.edge) }
    }
    out.set(a.node, [...best])
  }
  return { pool, stretch, probes, edges, out }
}

/** Start -> A -> B -> C -> start, scored on the perimeter its own edges predict. */
export function searchSequences(field: Field, graph: Compatibility, options: { perFamily: number }): Sequence[] {
  const target = field.targetMetres
  const byId = new Map(graph.pool.map(node => [node.node, node]))
  const home = (node: Node) => node.networkMetres
  const found: Sequence[] = []
  for (const a of graph.pool) for (const direction of [1, -1] as const) {
    for (const first of graph.out.get(a.node) ?? []) {
      if (signedTurn(first.features.bearingA, first.features.bearingB) * direction <= 0) continue
      const b = byId.get(first.to)!
      for (const second of graph.out.get(b.node) ?? []) {
        if (second.to === a.node) continue
        if (signedTurn(second.features.bearingA, second.features.bearingB) * direction <= 0) continue
        const c = byId.get(second.to)!
        if (haversine(field.point(a), field.point(c)) < target * 0.08) continue
        const legs = [home(a), first.cost, second.cost, home(c)]
        const predicted = legs.reduce((sum, value) => sum + value, 0)
        const closing = pairFeatures(field, c, a)
        // The acceptance gate's own shape tests, applied to the cheap plan.
        // These are not new heuristics: `shapeless`, `leg-too-long` and
        // `leg-too-short` were the largest non-distance rejection classes, and
        // all three are decidable from the anchor polygon before any routing.
        const shape = compactness([field.start, field.point(a), field.point(b), field.point(c), field.start])
        const shares = legs.map(value => value / Math.max(1, predicted))
        const maxShare = Math.max(...shares), minShare = Math.min(...shares.slice(1, -1))
        // Hard gates, not scores: a plan that already fails `shapeless`,
        // `leg-too-long` or `leg-too-short` on its own polygon cannot pass
        // after routing, so it is never worth a GraphHopper call. Ranking
        // stays distance-first so shape never outbids scale.
        if (shape < MIN_COMPACTNESS || maxShare > MAX_LEG_SHARE || minShare < MIN_LEG_SHARE) continue
        const penalty = first.penalty + second.penalty
          + (signedTurn(field.bearing(c), field.bearing(a)) * direction <= 0 ? 1.5 : 0)
          + closing.sharedFraction
        found.push({
          fixture: field.name, family: `${Math.floor(field.bearing(a) / 30)}-${direction > 0 ? 'cw' : 'ccw'}`,
          direction, anchors: [a, b, c], predicted, legs, penalty, rank: 0,
          probedEdges: (first.probed === null ? 0 : 1) + (second.probed === null ? 0 : 1),
          shape, maxShare, minShare,
        })
      }
    }
  }
  // Rank primarily by target-distance error, with topology as the tie-break.
  const scored = found.map(sequence => ({
    sequence, score: Math.abs(sequence.predicted - target) / target + sequence.penalty * 0.02,
  })).sort((x, y) => x.score - y.score)
  const perFamily = new Map<string, Sequence[]>()
  const used = new Set<string>()
  for (const { sequence } of scored) {
    const list = perFamily.get(sequence.family) ?? []
    if (list.length >= options.perFamily) continue
    const signature = sequence.anchors.map(node => node.node).sort((x, y) => x - y).join(',') + sequence.direction
    if (used.has(signature)) continue
    used.add(signature)
    sequence.rank = list.length
    list.push(sequence)
    perFamily.set(sequence.family, list)
  }
  return [...perFamily.values()].flat().sort((x, y) => x.family.localeCompare(y.family) || x.rank - y.rank)
}

export const sequencePoints = (sequence: Sequence): LngLat[] => sequence.anchors.map(node => [node.lon, node.lat])
