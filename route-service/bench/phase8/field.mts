/**
 * Phase 8 shared field/tree/anchor library.
 *
 * Everything here reads the exported bounded GraphHopper field. It builds no
 * routes: the shortest-path tree it reconstructs is the one GraphHopper's own
 * exploration settled, and every distance a candidate is finally judged on
 * still comes from GraphHopper's router.
 */
import { readFileSync } from 'node:fs'
import { bearingBetween, haversine, type LngLat } from '../../src/loops/geo.js'
import { MIN_LEG_SHARE } from '../../src/loops/quality.js'

export type Node = {
  node: number; lat: number; lon: number; networkMetres: number; degree: number
  parent: number; parentEdge: number
}
export type RawField = {
  name: string; targetMetres: number; limitMetres: number; nodesVisited: number
  edgesVisited: number; wallMs: number; heapDeltaBytes: number
  snappedLat: number; snappedLon: number; startNode: number; nodes: Node[]
}

export const STARTS = new Map<string, LngLat>([
  ['douglas-5km', [-4.4816, 54.1506]], ['douglas-3km', [-4.4816, 54.1506]],
  ['peel-5km', [-4.6947, 54.2247]], ['onchan-5km', [-4.4530, 54.1745]],
])

export const median = (values: number[]) => {
  if (!values.length) return 0
  const sorted = [...values].sort((a, b) => a - b)
  return sorted.length % 2 ? sorted[(sorted.length - 1) / 2] : (sorted[sorted.length / 2 - 1] + sorted[sorted.length / 2]) / 2
}
export const percentile = (values: number[], p: number) => {
  if (!values.length) return 0
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil(sorted.length * p) - 1))]
}
export const mean = (values: number[]) => values.length ? values.reduce((s, v) => s + v, 0) / values.length : 0
export const angleGap = (a: number, b: number) => Math.abs(((a - b + 540) % 360) - 180)
/** Signed turn from a to b, positive clockwise. */
export const signedTurn = (a: number, b: number) => ((b - a + 540) % 360) - 180

/** A field with parent links resolved into index space plus root-path helpers. */
export class Field {
  readonly name: string
  readonly targetMetres: number
  readonly limitMetres: number
  readonly wallMs: number
  readonly nodesVisited: number
  readonly edgesVisited: number
  readonly heapDeltaBytes: number
  readonly start: LngLat
  readonly nodes: Node[]
  private readonly byId = new Map<number, number>()

  constructor(raw: RawField) {
    this.name = raw.name; this.targetMetres = raw.targetMetres; this.limitMetres = raw.limitMetres
    this.wallMs = raw.wallMs; this.nodesVisited = raw.nodesVisited; this.edgesVisited = raw.edgesVisited
    this.heapDeltaBytes = raw.heapDeltaBytes
    this.start = STARTS.get(raw.name) ?? [raw.snappedLon, raw.snappedLat]
    this.nodes = raw.nodes
    this.nodes.forEach((node, index) => this.byId.set(node.node, index))
  }

  index(id: number) { return this.byId.get(id) ?? -1 }
  point(node: Node): LngLat { return [node.lon, node.lat] }
  bearing(node: Node) { return bearingBetween(this.start, this.point(node)) }
  crow(node: Node) { return haversine(this.start, this.point(node)) }

  /** Node ids from the root down to `node`, the tree path GraphHopper settled. */
  rootPath(node: Node): number[] {
    const path: number[] = []
    let current: number | undefined = node.node
    let guard = 0
    while (current !== undefined && current >= 0 && guard++ < this.nodes.length + 2) {
      path.push(current)
      const index = this.byId.get(current)
      if (index === undefined) break
      const parent = this.nodes[index].parent
      if (parent < 0) break
      current = parent
    }
    return path.reverse()
  }
  /** Parent edge ids along the same path; the physical corridor out of the start. */
  edgePath(node: Node): number[] {
    return this.rootPath(node).map(id => this.nodes[this.byId.get(id)!]?.parentEdge ?? -1).filter(edge => edge >= 0)
  }
}

/** Jackson writes snake_case, so both spellings are accepted on the way in. */
type WireNode = Partial<Node> & { node: number; lat: number; lon: number; network_metres?: number; parent_edge?: number }
export const loadFields = (url: URL) =>
  (JSON.parse(readFileSync(url, 'utf8')) as Array<Omit<RawField, 'nodes'> & { nodes: WireNode[] }>)
    .map(raw => new Field({
      ...raw,
      nodes: raw.nodes.map(node => ({
        node: node.node, lat: node.lat, lon: node.lon, degree: node.degree ?? 0,
        networkMetres: node.networkMetres ?? node.network_metres ?? 0,
        parent: node.parent ?? -1, parentEdge: node.parentEdge ?? node.parent_edge ?? -1,
      })),
    }))

// ---------------------------------------------------------------- anchor pool

/**
 * A deliberately small, deterministic anchor pool.
 *
 * Phase 7 chose anchors by pinning a start-distance shell, which fixed the
 * wrong quantity. Here the pool only has to *cover* the plausible band widely
 * enough that a sequence can be assembled at target scale; which radius each
 * anchor sits at is left to the sequence search. Selection is greedy
 * maximum-minimum spread in normalised (bearing, network-distance) space, so
 * angular coverage comes first and radial variety fills in after.
 */
export type PoolOptions = { size: number; innerShare?: number; outerShare?: number; minDegree?: number; separationShare?: number }
export function anchorPool(field: Field, options: PoolOptions): Node[] {
  const { size } = options
  // The band is not a tuned shell. Its floor is the acceptance gate's own
  // minimum leg share — an anchor nearer than that can never be a legal
  // corner — and its ceiling is simply how far the field was explored.
  const inner = (options.innerShare ?? MIN_LEG_SHARE) * field.targetMetres
  const outer = (options.outerShare ?? 1) * field.limitMetres
  const minDegree = options.minDegree ?? 3
  const separationShare = options.separationShare ?? 0.06
  const band = Math.max(1, outer - inner)
  let eligible = field.nodes.filter(node => node.degree >= minDegree && node.networkMetres >= inner && node.networkMetres <= outer)
  if (eligible.length < size) eligible = field.nodes.filter(node => node.degree >= 2 && node.networkMetres >= inner && node.networkMetres <= outer)
  if (!eligible.length) return []
  const feature = (node: Node) => ({ bearing: field.bearing(node), radial: (node.networkMetres - inner) / band })
  const spread = (a: Node, b: Node) => {
    const fa = feature(a), fb = feature(b)
    return angleGap(fa.bearing, fb.bearing) / 180 + Math.abs(fa.radial - fb.radial) * 0.35
  }
  // Deterministic seed: highest degree, then nearest the band centre, then id.
  const seed = [...eligible].sort((a, b) =>
    b.degree - a.degree
    || Math.abs(a.networkMetres - (inner + outer) / 2) - Math.abs(b.networkMetres - (inner + outer) / 2)
    || a.node - b.node)[0]
  // The separation floor keeps anchors from being near-duplicates. Where the
  // network cannot host `size` anchors that far apart it is relaxed rather
  // than silently returning a short pool, so sparse fixtures still get a
  // workable pool without a fixture-specific constant.
  let chosen: Node[] = []
  for (const share of [separationShare, separationShare / 2, separationShare / 4]) {
    const separation = share * field.targetMetres
    chosen = [seed]
    while (chosen.length < size) {
      let best: Node | undefined, bestScore = -Infinity
      for (const node of eligible) {
        if (chosen.some(prior => prior.node === node.node)) continue
        if (chosen.some(prior => haversine(field.point(prior), field.point(node)) < separation)) continue
        const score = Math.min(...chosen.map(prior => spread(prior, node))) + Math.min(4, node.degree) * 0.02
        if (score > bestScore || (score === bestScore && best && node.node < best.node)) { bestScore = score; best = node }
      }
      if (!best) break
      chosen.push(best)
    }
    if (chosen.length >= size) break
  }
  // Selection order is kept, not bearing order: the greedy is incremental, so
  // the first K entries are exactly the pool of size K. One probe capture at
  // the largest size therefore serves every smaller size in P16.
  return chosen
}

// ------------------------------------------------------------ tree ancestry

export type Ancestry = {
  sharedMetres: number; divergence: number; toA: number; toB: number
  sharedFraction: number; treeMetres: number; sharedEdges: number
}
/** Lowest common ancestor in the start-rooted shortest-path tree, and its metrics. */
export function ancestry(field: Field, a: Node, b: Node): Ancestry {
  const pathA = field.rootPath(a), pathB = field.rootPath(b)
  let shared = 0
  while (shared < pathA.length && shared < pathB.length && pathA[shared] === pathB[shared]) shared++
  const lcaId = pathA[Math.max(0, shared - 1)]
  const lca = field.nodes[field.index(lcaId)]
  const sharedMetres = lca?.networkMetres ?? 0
  const edgesA = field.edgePath(a), edgesB = field.edgePath(b)
  let sharedEdges = 0
  while (sharedEdges < edgesA.length && sharedEdges < edgesB.length && edgesA[sharedEdges] === edgesB[sharedEdges]) sharedEdges++
  const toA = a.networkMetres - sharedMetres, toB = b.networkMetres - sharedMetres
  return {
    sharedMetres, divergence: lcaId, toA, toB,
    sharedFraction: 2 * sharedMetres / Math.max(1, a.networkMetres + b.networkMetres),
    treeMetres: toA + toB, sharedEdges,
  }
}

// -------------------------------------------------------------- estimators

export type PairFeatures = {
  crow: number; tree: number; sharedFraction: number; sharedMetres: number
  sharedEdges: number; bearingA: number; bearingB: number; turn: number
}
export const pairFeatures = (field: Field, a: Node, b: Node): PairFeatures => {
  const tie = ancestry(field, a, b)
  return {
    crow: haversine(field.point(a), field.point(b)), tree: tie.treeMetres,
    sharedFraction: tie.sharedFraction, sharedMetres: tie.sharedMetres, sharedEdges: tie.sharedEdges,
    bearingA: field.bearing(a), bearingB: field.bearing(b),
    turn: signedTurn(field.bearing(a), field.bearing(b)),
  }
}

/**
 * The tree path A->LCA->B is a real walkable path, so `tree` is a true upper
 * bound on the network distance and `crow` a true lower bound. E2 is the
 * midpoint of that proven bracket; E2g its geometric mean. Neither is fitted.
 * E3 scales crow by the request's own measured field stretch, which is
 * request-scoped rather than a constant.
 */
export const ESTIMATORS = {
  E0: (f: PairFeatures) => f.crow,
  E1: (f: PairFeatures) => f.tree,
  E2: (f: PairFeatures) => (f.crow + Math.max(f.crow, f.tree)) / 2,
  E2g: (f: PairFeatures) => Math.sqrt(f.crow * Math.max(f.crow, f.tree)),
} as const
export type EstimatorName = keyof typeof ESTIMATORS | 'E3'
export const estimate = (name: EstimatorName, f: PairFeatures, stretch: number) =>
  name === 'E3' ? f.crow * stretch : ESTIMATORS[name](f)

/** Median network/crow ratio of the pool itself: cheap, request-scoped, no constant. */
export const fieldStretch = (field: Field, pool: Node[]) =>
  median(pool.map(node => node.networkMetres / Math.max(1, field.crow(node))))
