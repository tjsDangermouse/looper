/**
 * P5-P11 — bounded closed-walk search over the request-local graph.
 *
 * The object being searched is the walk. A state is a partial closed walk out
 * of the start: where it has got to, how far it has come, which physical edges
 * it has spent, and enough incremental geometry to say whether the shape is
 * going anywhere. Nothing here routes; a retained walk is handed to
 * GraphHopper afterwards, and the gate that judges it is Looper's own.
 *
 * The pruning is the exported field's own network distance home. That value is
 * the exact shortest walkable distance from a node back to the routing start,
 * so `distanceUsed + home[node]` is a true lower bound on what the walk can
 * still finish at, and a state failing the upper distance bound on it can be
 * discarded without losing a single admissible walk.
 */
import { bearingBetween, projector, type Metric } from '../../src/loops/geo.js'
import { MAX_DISTANCE_ERROR } from '../../src/loops/quality.js'
import { INITIAL_BEARING_FRACTION, INITIAL_BEARING_METRES, bearingOctant } from '../../src/loops/diversity.js'
import type { SearchGraph } from './graph.mjs'

/**
 * P11's diversity axis, and deliberately the same one the offer selector uses:
 * the compass octant the walk has committed to by the time it is a few hundred
 * metres out. Seeding families on the first arc out of the door is useless
 * where the start sits mid-street and there are only two of them — which is
 * three of the four fixtures.
 */
export function familyAxis(graph: SearchGraph) {
  const distance = Math.min(INITIAL_BEARING_METRES, graph.targetMetres * INITIAL_BEARING_FRACTION)
  const octant = new Int8Array(graph.lon.length)
  for (let node = 0; node < octant.length; node++) {
    octant[node] = bearingOctant(bearingBetween(graph.startPoint, [graph.lon[node], graph.lat[node]]))
  }
  return { commitAt: distance, octant }
}

// ------------------------------------------------------- geometry precompute

export type EdgeGeometry = {
  /** Shoelace contribution of traversing `from -> to`, in the start's frame. */
  twiceArea: number
  /** Geometric length of the drawn line, which is what the gate measures. */
  drawn: number
  minX: number; maxX: number; minY: number; maxY: number
  maxRadius: number
  points: Metric[]
}

export function edgeGeometry(graph: SearchGraph): EdgeGeometry[] {
  const project = projector(graph.startPoint)
  return graph.edges.map(edge => {
    const points = edge.geometry.map(project)
    let twiceArea = 0, drawn = 0, maxRadius = 0
    let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity
    for (let i = 0; i < points.length; i++) {
      const [x, y] = points[i]
      if (x < minX) minX = x
      if (x > maxX) maxX = x
      if (y < minY) minY = y
      if (y > maxY) maxY = y
      const radius = Math.hypot(x, y)
      if (radius > maxRadius) maxRadius = radius
      if (i + 1 < points.length) {
        const [nx, ny] = points[i + 1]
        twiceArea += x * ny - nx * y
        drawn += Math.hypot(nx - x, ny - y)
      }
    }
    return { twiceArea, drawn, minX, maxX, minY, maxY, maxRadius, points }
  })
}

// --------------------------------------------------------------- the objective

/**
 * P1, as the acceptance gate already defines it. Nothing here is a new quality
 * definition: the band is `MAX_DISTANCE_ERROR`, closure is the gate's own
 * requirement that the walk return to its start, and edge exhaustion is what
 * the gate's `out-and-back-spur` rule amounts to on a physical network — a
 * reverse retrace outside the doorstep window is fatal, so an admissible walk
 * simply may not spend a physical edge twice.
 */
export type Objective = {
  targetMetres: number
  minMetres: number
  maxMetres: number
}
export const objectiveFor = (targetMetres: number, tolerance = MAX_DISTANCE_ERROR): Objective => ({
  targetMetres,
  minMetres: targetMetres * (1 - tolerance),
  maxMetres: targetMetres * (1 + tolerance),
})

// --------------------------------------------------------------------- states

export type State = {
  node: number
  /** Metres from the routing start, including the stem out to the 2-core. */
  distance: number
  parent: number
  edge: number
  /** Which arc out of the root this walk began on; the diversity family. */
  family: number
  twiceArea: number
  drawn: number
  minX: number; maxX: number; minY: number; maxY: number
  maxRadius: number
  depth: number
}

export type SearchStats = {
  generated: number
  expanded: number
  prunedDistance: number
  prunedReuse: number
  prunedBeam: number
  prunedDominated: number
  peakFrontier: number
  completed: number
  wallMs: number
  storeSize: number
  /** Peak JS heap in use during the search, sampled once per band. */
  peakHeapBytes: number
}

export type Walk = {
  edges: number[]
  /** True where the super-edge was traversed `from -> to`. */
  forward: boolean[]
  metres: number
  family: number
  compactness: number
  bboxRatio: number
  maxRadius: number
}

/** Where the walk actually starts searching, and what the doorstep stem costs. */
export function rootOf(graph: SearchGraph): { root: number; stemMetres: number } {
  if (graph.arcs[graph.start]?.length) return { root: graph.start, stemMetres: 0 }
  let root = -1, best = Infinity
  for (let node = 0; node < graph.arcs.length; node++) {
    if (!graph.arcs[node].length) continue
    if (graph.home[node] < best) { best = graph.home[node]; root = node }
  }
  return { root, stemMetres: Number.isFinite(best) ? best : 0 }
}

/**
 * Shared machinery: the store of partial walks, the used-edge test, and the
 * shape summary a completed walk is measured on.
 */
export class Frontier {
  readonly store: State[] = []
  private readonly used: Uint32Array
  constructor(private readonly graph: SearchGraph) {
    this.used = new Uint32Array((graph.edges.length + 31) >> 5)
  }
  push(state: State) { this.store.push(state); return this.store.length - 1 }
  /** Mark every edge on the walk ending at `index`. Returns its depth. */
  mark(index: number): number {
    let depth = 0, at = index
    while (at >= 0) {
      const state = this.store[at]
      if (state.edge >= 0) { this.used[state.edge >> 5] |= 1 << (state.edge & 31); depth++ }
      at = state.parent
    }
    return depth
  }
  unmark(index: number) {
    let at = index
    while (at >= 0) {
      const state = this.store[at]
      if (state.edge >= 0) this.used[state.edge >> 5] &= ~(1 << (state.edge & 31))
      at = state.parent
    }
  }
  spent(edge: number) { return (this.used[edge >> 5] & (1 << (edge & 31))) !== 0 }
  set(edge: number) { this.used[edge >> 5] |= 1 << (edge & 31) }
  clear(edge: number) { this.used[edge >> 5] &= ~(1 << (edge & 31)) }
  /** The super-edge sequence of the walk ending at `index`, root first. */
  path(index: number): number[] {
    const edges: number[] = []
    let at = index
    while (at >= 0) { const state = this.store[at]; if (state.edge >= 0) edges.push(state.edge); at = state.parent }
    return edges.reverse()
  }
  walkOf(index: number, stemMetres: number): Walk {
    const state = this.store[index]
    const edges: number[] = [], forward: boolean[] = []
    let at = index
    while (at >= 0) {
      const step = this.store[at]
      if (step.edge >= 0) {
        edges.push(step.edge)
        forward.push(this.graph.edges[step.edge].from === this.store[step.parent].node)
      }
      at = step.parent
    }
    edges.reverse(); forward.reverse()
    const drawn = state.drawn
    const width = state.maxX - state.minX, height = state.maxY - state.minY
    return {
      edges, forward, metres: state.distance + stemMetres, family: state.family,
      compactness: drawn > 0 ? Math.min(1, 4 * Math.PI * Math.abs(state.twiceArea / 2) / drawn ** 2) : 0,
      bboxRatio: Math.min(width, height) > 0 ? Math.max(width, height) / Math.min(width, height) : Infinity,
      maxRadius: state.maxRadius,
    }
  }
}

const extend = (parent: State, parentIndex: number, arc: { edge: number; to: number; metres: number; forward: boolean }, geometry: EdgeGeometry, axis?: { commitAt: number; octant: Int8Array }): State => ({
  node: arc.to,
  distance: parent.distance + arc.metres,
  parent: parentIndex,
  edge: arc.edge,
  family: parent.family >= 0 || !axis ? parent.family
    : parent.distance + arc.metres >= axis.commitAt ? axis.octant[arc.to] : -1,
  twiceArea: parent.twiceArea + (arc.forward ? geometry.twiceArea : -geometry.twiceArea),
  drawn: parent.drawn + geometry.drawn,
  minX: Math.min(parent.minX, geometry.minX), maxX: Math.max(parent.maxX, geometry.maxX),
  minY: Math.min(parent.minY, geometry.minY), maxY: Math.max(parent.maxY, geometry.maxY),
  maxRadius: Math.max(parent.maxRadius, geometry.maxRadius),
  depth: parent.depth + 1,
})

/**
 * How promising a partial walk is: close it with a straight line home and ask
 * how round the result would be. It is the cheapest honest proxy for the gate's
 * own compactness, it needs only the running shoelace and bounding box, and it
 * is exactly the quantity Phase 8 could not see because it never held a walk.
 */
function promise(state: State, graph: SearchGraph, objective: Objective, root: number): number {
  const closing = graph.home[state.node] - graph.home[root]
  const perimeter = state.drawn + Math.max(0, closing)
  const area = Math.abs(state.twiceArea / 2)
  const shape = perimeter > 0 ? Math.min(1, 4 * Math.PI * area / perimeter ** 2) : 0
  // Distance still wanted, as a share of the target. A walk that can no longer
  // reach the band is worthless however round it is.
  const shortfall = Math.max(0, objective.minMetres - (state.distance + graph.home[state.node])) / objective.targetMetres
  return shape - shortfall
}

// ----------------------------------------------------------- S1: bounded DFS

export type SearchOptions = {
  objective: Objective
  /** Hard ceiling on states expanded, so an explosion is measured not suffered. */
  budget: number
  /** S2 only: how many partial walks survive each distance band. */
  beam?: number
  /** S2 only: width of a distance band, metres. */
  band?: number
  /** S2 only: at most this many survivors may sit on one node. */
  perNode?: number
  /** S2 only: guarantee each first-arc family this many survivors. */
  perFamily?: number
  /** Stop once this many closed walks have been found. */
  wanted?: number
  /** Ignore closures below this compactness; the gate's own floor by default. */
  minCompactness?: number
  /** S3: enter the 2-core here rather than at the nearest node to the start. */
  root?: number
  stemMetres?: number
}

/** Every 2-core node the walk could enter from, within a stem allowance. */
export function coreEntries(graph: SearchGraph, allowanceMetres: number): Array<{ root: number; stemMetres: number }> {
  const entries: Array<{ root: number; stemMetres: number }> = []
  for (let node = 0; node < graph.arcs.length; node++) {
    if (!graph.arcs[node].length) continue
    if (graph.home[node] <= allowanceMetres) entries.push({ root: node, stemMetres: graph.home[node] })
  }
  return entries.sort((a, b) => a.stemMetres - b.stemMetres)
}

const seedState = (root: number, stemMetres: number, family: number): State => ({
  node: root, distance: stemMetres, parent: -1, edge: -1, family,
  twiceArea: 0, drawn: 0, minX: 0, maxX: 0, minY: 0, maxY: 0, maxRadius: 0, depth: 0,
})

export function depthFirstSearch(graph: SearchGraph, options: SearchOptions): { walks: Walk[]; stats: SearchStats } {
  const began = performance.now()
  const geometry = edgeGeometry(graph)
  const { root, stemMetres } = rootOf(graph)
  const objective = options.objective
  const frontier = new Frontier(graph)
  const stats: SearchStats = { generated: 0, expanded: 0, prunedDistance: 0, prunedReuse: 0, prunedBeam: 0, prunedDominated: 0, peakFrontier: 0, completed: 0, wallMs: 0, storeSize: 0, peakHeapBytes: 0 }
  const walks: Walk[] = []
  const seed = frontier.push(seedState(root, stemMetres, -1))

  /**
   * Exhaustive except for the two bounds that cannot lose an admissible walk:
   * a physical edge already spent, and a state whose best possible finish is
   * already past the top of the band. The expansion budget is not a bound on
   * the problem, it is the instrument: what S1 is here to measure is how fast
   * the state count grows before either bound bites.
   */
  const visit = (index: number, depth: number): void => {
    if (stats.expanded >= options.budget || walks.length >= (options.wanted ?? Infinity)) return
    stats.expanded++
    stats.peakFrontier = Math.max(stats.peakFrontier, depth)
    const state = frontier.store[index]
    for (const arc of graph.arcs[state.node]) {
      if (frontier.spent(arc.edge)) { stats.prunedReuse++; continue }
      const distance = state.distance + arc.metres
      if (distance + graph.home[arc.to] > objective.maxMetres) { stats.prunedDistance++; continue }
      stats.generated++
      const child = extend(state, index, arc, geometry[arc.edge])
      if (child.family < 0) child.family = graph.arcs[root].indexOf(arc)
      const childIndex = frontier.push(child)
      if (arc.to === root) {
        const total = distance + stemMetres
        if (total >= objective.minMetres && total <= objective.maxMetres) {
          const walk = frontier.walkOf(childIndex, stemMetres)
          if (walk.compactness >= (options.minCompactness ?? 0)) { walks.push(walk); stats.completed++ }
        }
        continue
      }
      frontier.set(arc.edge)
      visit(childIndex, depth + 1)
      frontier.clear(arc.edge)
      if (stats.expanded >= options.budget) break
    }
  }
  visit(seed, 1)
  stats.wallMs = performance.now() - began
  stats.storeSize = frontier.store.length
  return { walks, stats }
}

// ----------------------------------------------------------- S2: beam search

export function beamSearch(graph: SearchGraph, options: SearchOptions): { walks: Walk[]; stats: SearchStats } {
  const began = performance.now()
  const geometry = edgeGeometry(graph)
  const chosen = options.root !== undefined ? { root: options.root, stemMetres: options.stemMetres ?? graph.home[options.root] } : rootOf(graph)
  const { root, stemMetres } = chosen
  const objective = options.objective
  const beam = options.beam ?? 400
  const band = options.band ?? 100
  const perNode = options.perNode ?? 4
  const perFamily = options.perFamily ?? 0
  const frontier = new Frontier(graph)
  const axis = familyAxis(graph)
  const stats: SearchStats = { generated: 0, expanded: 0, prunedDistance: 0, prunedReuse: 0, prunedBeam: 0, prunedDominated: 0, peakFrontier: 0, completed: 0, wallMs: 0, storeSize: 0, peakHeapBytes: 0 }
  const walks: Walk[] = []

  const buckets = new Map<number, number[]>()
  const pushBucket = (index: number) => {
    const key = Math.floor(frontier.store[index].distance / band)
    const bucket = buckets.get(key)
    if (bucket) bucket.push(index)
    else buckets.set(key, [index])
  }
  // One seed per arc out of the root. The family a walk belongs to is not
  // decided here: it is whichever octant the walk has committed to once it is
  // clear of the door, which is the axis the offer selector judges on.
  graph.arcs[root].forEach(arc => {
    const seed = frontier.push(seedState(root, stemMetres, -1))
    const state = extend(frontier.store[seed], seed, arc, geometry[arc.edge], axis)
    if (state.distance + graph.home[arc.to] <= objective.maxMetres) pushBucket(frontier.push(state))
  })

  /**
   * Bands are drained rather than visited once. A super-edge is often shorter
   * than the band, so expanding a band produces states that belong to the same
   * band; dropping those would silently discard most of the search. Each pass
   * over a band applies the beam to whatever is currently in it, so the width
   * bounds the work per pass and the band still empties before the next one
   * starts. Termination is not in doubt: no walk may spend an edge twice, so
   * depth is bounded by the edge count.
   */
  const done = new Set<number>()
  for (;;) {
    let key: number | undefined
    for (const candidate of buckets.keys()) {
      if (done.has(candidate) || !buckets.get(candidate)!.length) continue
      if (key === undefined || candidate < key) key = candidate
    }
    if (key === undefined) break
    const bucket = buckets.get(key)!
    buckets.set(key, [])
    stats.peakFrontier = Math.max(stats.peakFrontier, bucket.length)
    stats.peakHeapBytes = Math.max(stats.peakHeapBytes, process.memoryUsage().heapUsed)
    // Rank, then keep: a per-node cap so one junction cannot flood the band,
    // and a per-family floor so a direction is never squeezed out entirely.
    const scored = bucket.map(index => ({ index, score: promise(frontier.store[index], graph, objective, root) }))
      .sort((a, b) => b.score - a.score)
    // Beam selection with a family quota. Ranking on shape alone converges:
    // at Douglas 5 km every closed walk a plain beam found sat in one compass
    // octant and overlapped the best of them by 89%, so the offer selector
    // could only ever take one. Splitting the width across the octants the
    // selector itself judges on is what makes the search produce three walks
    // rather than three readings of one.
    const kept: number[] = []
    const nodeCount = new Map<number, number>()
    const familyCount = new Map<number, number>()
    const present = new Set(scored.map(entry => frontier.store[entry.index].family))
    const quota = perFamily > 0 ? Math.max(1, Math.floor(beam / Math.max(1, present.size))) : Infinity
    const consider = (entry: { index: number; score: number }, limit: number, cap: number) => {
      const state = frontier.store[entry.index]
      const inFamily = familyCount.get(state.family) ?? 0
      if (inFamily >= limit) return false
      const onNode = nodeCount.get(state.node) ?? 0
      if (onNode >= cap) { stats.prunedDominated++; return false }
      nodeCount.set(state.node, onNode + 1)
      familyCount.set(state.family, inFamily + 1)
      kept.push(entry.index)
      return true
    }
    const taken = new Set<number>()
    for (const entry of scored) {
      if (kept.length >= beam) break
      if (consider(entry, quota, perNode)) taken.add(entry.index)
    }
    // Whatever width the quotas left unused goes to the best states overall.
    for (const entry of scored) {
      if (kept.length >= beam) break
      if (taken.has(entry.index)) continue
      consider(entry, Infinity, perNode)
    }
    stats.prunedBeam += bucket.length - kept.length
    for (const index of kept) {
      stats.expanded++
      frontier.mark(index)
      const state = frontier.store[index]
      for (const arc of graph.arcs[state.node]) {
        if (frontier.spent(arc.edge)) { stats.prunedReuse++; continue }
        const distance = state.distance + arc.metres
        if (distance + graph.home[arc.to] > objective.maxMetres) { stats.prunedDistance++; continue }
        stats.generated++
        const child = extend(state, index, arc, geometry[arc.edge], axis)
        const childIndex = frontier.push(child)
        if (arc.to === root) {
          const total = distance + stemMetres
          if (total >= objective.minMetres && total <= objective.maxMetres) {
            const walk = frontier.walkOf(childIndex, stemMetres)
            if (walk.compactness >= (options.minCompactness ?? 0)) { walks.push(walk); stats.completed++ }
          }
          continue
        }
        pushBucket(childIndex)
      }
      frontier.unmark(index)
      if (stats.expanded >= options.budget || walks.length >= (options.wanted ?? Infinity)) break
    }
    if (!buckets.get(key)!.length) done.add(key)
    if (stats.expanded >= options.budget || walks.length >= (options.wanted ?? Infinity)) break
  }
  stats.wallMs = performance.now() - began
  stats.storeSize = frontier.store.length
  return { walks, stats }
}

// ------------------------------------------------- S4: two meeting frontiers

/**
 * S4 — meet in the middle.
 *
 * One beam is grown to roughly half the target and then every pair of partial
 * walks ending on the same node is considered as a closure: run the first out
 * and the second back. The pair is admissible only if the two spend no
 * physical edge in common, which is the same constraint the single-frontier
 * search enforces along one path, checked once between two paths instead.
 *
 * It is included because on a sparse network the single frontier can be forced
 * to commit early; whether that actually costs anything is what the numbers
 * below answer.
 */
export function meetSearch(graph: SearchGraph, options: SearchOptions & { halfBand?: number; poolPerNode?: number }): { walks: Walk[]; stats: SearchStats } {
  const began = performance.now()
  const geometry = edgeGeometry(graph)
  const { root, stemMetres } = rootOf(graph)
  const objective = options.objective
  const beam = options.beam ?? 400
  const band = options.band ?? 100
  const perNode = options.perNode ?? 4
  const halfBand = options.halfBand ?? 0.12
  const poolPerNode = options.poolPerNode ?? 6
  const frontier = new Frontier(graph)
  const axis = familyAxis(graph)
  const stats: SearchStats = { generated: 0, expanded: 0, prunedDistance: 0, prunedReuse: 0, prunedBeam: 0, prunedDominated: 0, peakFrontier: 0, completed: 0, wallMs: 0, storeSize: 0, peakHeapBytes: 0 }

  // Half-walks: the same beam, stopped at half the target.
  const half = objective.targetMetres / 2
  const halves = new Map<number, number[]>()
  const buckets = new Map<number, number[]>()
  const pushBucket = (index: number) => {
    const key = Math.floor(frontier.store[index].distance / band)
    const bucket = buckets.get(key)
    if (bucket) bucket.push(index); else buckets.set(key, [index])
  }
  graph.arcs[root].forEach(arc => {
    const seed = frontier.push(seedState(root, stemMetres, -1))
    pushBucket(frontier.push(extend(frontier.store[seed], seed, arc, geometry[arc.edge], axis)))
  })
  const done = new Set<number>()
  for (;;) {
    let key: number | undefined
    for (const candidate of buckets.keys()) {
      if (done.has(candidate) || !buckets.get(candidate)!.length) continue
      if (key === undefined || candidate < key) key = candidate
    }
    if (key === undefined || key * band > half * (1 + halfBand)) break
    const bucket = buckets.get(key)!
    buckets.set(key, [])
    stats.peakFrontier = Math.max(stats.peakFrontier, bucket.length)
    const scored = bucket.map(index => ({ index, score: promise(frontier.store[index], graph, objective, root) })).sort((a, b) => b.score - a.score)
    // The same family quota the single-frontier beam uses. Without it both
    // halves of every meeting leave the door the same way and no pair is ever
    // edge-disjoint, which is how this prototype first measured as finding
    // nothing at all.
    const kept: number[] = []
    const nodeCount = new Map<number, number>()
    const familyCount = new Map<number, number>()
    const present = new Set(scored.map(entry => frontier.store[entry.index].family))
    const quota = Math.max(1, Math.floor(beam / Math.max(1, present.size)))
    const consider = (entry: { index: number }, limit: number) => {
      const state = frontier.store[entry.index]
      const inFamily = familyCount.get(state.family) ?? 0
      if (inFamily >= limit) return false
      const onNode = nodeCount.get(state.node) ?? 0
      if (onNode >= perNode) { stats.prunedDominated++; return false }
      nodeCount.set(state.node, onNode + 1)
      familyCount.set(state.family, inFamily + 1)
      kept.push(entry.index)
      return true
    }
    const taken = new Set<number>()
    for (const entry of scored) { if (kept.length >= beam) break; if (consider(entry, quota)) taken.add(entry.index) }
    for (const entry of scored) { if (kept.length >= beam) break; if (!taken.has(entry.index)) consider(entry, Infinity) }
    stats.prunedBeam += bucket.length - kept.length
    for (const index of kept) {
      const state = frontier.store[index]
      if (state.distance >= half * (1 - halfBand) && state.distance <= half * (1 + halfBand)) {
        // At most two half-walks per family on a meeting node. Without the
        // family limit the pool fills with near-identical variants — measured
        // at 67 shared edges out of 71 — and no pair is ever edge-disjoint.
        const pool = halves.get(state.node)
        if (!pool) halves.set(state.node, [index])
        else if (pool.length < poolPerNode && pool.filter(other => frontier.store[other].family === state.family).length < 2) pool.push(index)
      }
      stats.expanded++
      frontier.mark(index)
      for (const arc of graph.arcs[state.node]) {
        if (frontier.spent(arc.edge)) { stats.prunedReuse++; continue }
        const distance = state.distance + arc.metres
        if (distance + graph.home[arc.to] > objective.maxMetres) { stats.prunedDistance++; continue }
        stats.generated++
        pushBucket(frontier.push(extend(state, index, arc, geometry[arc.edge], axis)))
      }
      frontier.unmark(index)
      if (stats.expanded >= options.budget) break
    }
    if (!buckets.get(key)!.length) done.add(key)
    if (stats.expanded >= options.budget) break
  }

  // Join every disjoint pair meeting on the same node.
  const walks: Walk[] = []
  if (process.env.S4_DEBUG) {
    const firsts = new Map<number, number>()
    for (const pool of halves.values()) for (const index of pool) {
      const first = frontier.path(index)[0]
      firsts.set(first, (firsts.get(first) ?? 0) + 1)
    }
    console.log(`  S4 ${graph.name}: root arcs ${graph.arcs[root].map(arc => arc.edge).join(',')}, first super-edge of half-walks ${[...firsts].sort((a, b) => b[1] - a[1]).slice(0, 5).map(([e, c]) => `${e}:${c}`).join(' ')}`)
    const sizes = [...halves.values()].map(pool => pool.length)
    console.log(`  S4 ${graph.name}: meeting nodes ${halves.size}, pools >=2 ${sizes.filter(size => size >= 2).length}, largest ${Math.max(0, ...sizes)}`)
  }
  const words = (graph.edges.length + 31) >> 5
  const left = new Uint32Array(words)
  let outOfBand = 0, overlapping = 0, tried = 0
  for (const pool of halves.values()) {
    for (let i = 0; i < pool.length; i++) {
      left.fill(0)
      for (const edge of frontier.path(pool[i])) left[edge >> 5] |= 1 << (edge & 31)
      for (let j = 0; j < pool.length; j++) {
        if (i === j) continue
        const total = frontier.store[pool[i]].distance + frontier.store[pool[j]].distance - stemMetres + stemMetres
        tried++
        if (total < objective.minMetres || total > objective.maxMetres) { outOfBand++; continue }
        const other = frontier.path(pool[j])
        const sharedEdges = other.filter(edge => (left[edge >> 5] & (1 << (edge & 31))) !== 0)
        if (sharedEdges.length) {
          overlapping++
          if (process.env.S4_DEBUG && overlapping <= 3) {
            const mine = frontier.path(pool[i])
            console.log(`    pair: |i|=${mine.length} |j|=${other.length} shared=${sharedEdges.length} firstI=${mine[0]} firstJ=${other[0]} sharedHead=${sharedEdges.slice(0, 5)}`)
          }
          continue
        }
        const walk = joinHalves(graph, frontier, pool[i], pool[j], stemMetres, geometry)
        if (walk && walk.compactness >= (options.minCompactness ?? 0)) { walks.push(walk); stats.completed++ }
        if (walks.length >= (options.wanted ?? Infinity)) break
      }
      if (walks.length >= (options.wanted ?? Infinity)) break
    }
    if (walks.length >= (options.wanted ?? Infinity)) break
  }
  if (process.env.S4_DEBUG) console.log(`  S4 ${graph.name}: pairs tried ${tried}, out of band ${outOfBand}, overlapping ${overlapping}, joined ${walks.length}`)
  stats.wallMs = performance.now() - began
  stats.storeSize = frontier.store.length
  return { walks, stats }
}

/** Out along one half-walk, back along the other reversed. */
function joinHalves(graph: SearchGraph, frontier: Frontier, outIndex: number, backIndex: number, stemMetres: number, geometry: EdgeGeometry[]): Walk | undefined {
  const outward = orientedPath(graph, frontier, outIndex)
  const inward = orientedPath(graph, frontier, backIndex)
  if (!outward || !inward) return undefined
  const edges = [...outward.edges, ...inward.edges.slice().reverse()]
  const forward = [...outward.forward, ...inward.forward.slice().reverse().map(value => !value)]
  let twiceArea = 0, drawn = 0, maxRadius = 0
  let minX = 0, maxX = 0, minY = 0, maxY = 0, metres = 0
  edges.forEach((edge, i) => {
    const shape = geometry[edge]
    twiceArea += forward[i] ? shape.twiceArea : -shape.twiceArea
    drawn += shape.drawn
    metres += graph.edges[edge].metres
    minX = Math.min(minX, shape.minX); maxX = Math.max(maxX, shape.maxX)
    minY = Math.min(minY, shape.minY); maxY = Math.max(maxY, shape.maxY)
    maxRadius = Math.max(maxRadius, shape.maxRadius)
  })
  const width = maxX - minX, height = maxY - minY
  return {
    edges, forward, metres: metres + 2 * stemMetres, family: frontier.store[outIndex].family,
    compactness: drawn > 0 ? Math.min(1, 4 * Math.PI * Math.abs(twiceArea / 2) / drawn ** 2) : 0,
    bboxRatio: Math.min(width, height) > 0 ? Math.max(width, height) / Math.min(width, height) : Infinity,
    maxRadius,
  }
}

function orientedPath(graph: SearchGraph, frontier: Frontier, index: number): { edges: number[]; forward: boolean[] } | undefined {
  const edges: number[] = [], forward: boolean[] = []
  let at = index
  while (at >= 0) {
    const step = frontier.store[at]
    if (step.edge >= 0) {
      edges.push(step.edge)
      forward.push(graph.edges[step.edge].from === frontier.store[step.parent].node)
    }
    at = step.parent
  }
  edges.reverse(); forward.reverse()
  return { edges, forward }
}
