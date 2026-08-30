/**
 * P4 — the bounded search graph.
 *
 * Reads the exported request-scoped subgraph and turns it into something a
 * closed-walk search can move over cheaply. Two reductions are applied, and
 * both are exact rather than heuristic:
 *
 *   1. the 2-core. A rooted circuit cannot enter a dead end and come back out
 *      without retracing that edge in reverse, and P1 shows a reverse retrace
 *      is fatal to the acceptance gate outside the doorstep window. So every
 *      leaf can be peeled, repeatedly, without removing a single admissible
 *      walk. What is peeled is kept, because the stem out of the start may run
 *      through it.
 *   2. degree-2 contraction. A chain of degree-2 junctions offers no choice:
 *      entering it determines everything until the next real junction. Each
 *      chain becomes one super-edge carrying its own metres, its geometry and
 *      the physical edge ids underneath it, so repeated-ground accounting is
 *      unchanged and the search's depth falls by the length of the chains.
 */
import { readFileSync } from 'node:fs'
import { type LngLat } from '../../src/loops/geo.js'

export type RawSubgraph = {
  name: string; targetMetres: number; limitMetres: number; explorationShare: number
  wallMs: number; heapDeltaBytes: number; snappedLat: number; snappedLon: number
  startNode: number; nodeCount: number; edgeCount: number
  nodes: Array<[number, number, number, number, number]>
  edges: Array<[number, number, number, number, number, number, number[]?]>
}

/** One oriented move the search may make out of a node. */
export type Arc = {
  /** Index into `graph.edges` of the undirected super-edge this arc traverses. */
  edge: number
  /** Where the arc arrives. */
  to: number
  metres: number
  /** Bearing at the point of departure, degrees. Used for the u-turn test. */
  outBearing: number
  /** Bearing on arrival. */
  inBearing: number
  /** True when the arc runs the super-edge from its `from` end to its `to` end. */
  forward: boolean
}

export type SuperEdge = {
  from: number; to: number; metres: number
  /** Physical edge ids underneath, in `from -> to` order, with their metres. */
  physical: Array<[number, number]>
  /** Full geometry, `from` end first. */
  geometry: LngLat[]
  forward: boolean; backward: boolean
}

export type RawEdgeRecord = { a: number; b: number; metres: number; origin: number; forward: boolean; backward: boolean; geometry: LngLat[] }

export type SearchGraph = {
  name: string; targetMetres: number; limitMetres: number
  start: number
  startPoint: LngLat
  /** Node index space is compacted; `id[i]` is the original GraphHopper node. */
  id: Int32Array
  lon: Float64Array
  lat: Float64Array
  /** Shortest network distance from the routing start, in metres. Exact. */
  home: Float64Array
  edges: SuperEdge[]
  arcs: Arc[][]
  /** The unreduced edges, kept so the doorstep stem can be reconstructed. */
  rawEdges: RawEdgeRecord[]
  /** Predecessor node and raw edge on the shortest walk from the start. */
  parentNode: Int32Array
  parentRaw: Int32Array
  /** Nodes and edges before each reduction, for the cost table. */
  stats: {
    rawNodes: number; rawEdges: number
    coreNodes: number; coreEdges: number
    nodes: number; edges: number
    peeledNodes: number
    exportWallMs: number; buildWallMs: number
  }
}

export const bearing = (from: LngLat, to: LngLat) => {
  const φ1 = from[1] * Math.PI / 180, φ2 = to[1] * Math.PI / 180
  const Δλ = (to[0] - from[0]) * Math.PI / 180
  const y = Math.sin(Δλ) * Math.cos(φ2)
  const x = Math.cos(φ1) * Math.sin(φ2) - Math.sin(φ1) * Math.cos(φ2) * Math.cos(Δλ)
  return (Math.atan2(y, x) * 180 / Math.PI + 360) % 360
}

export const loadSubgraphs = (url: URL) => JSON.parse(readFileSync(url, 'utf8')) as RawSubgraph[]

export function buildSearchGraph(raw: RawSubgraph): SearchGraph {
  const began = performance.now()
  const index = new Map<number, number>()
  raw.nodes.forEach((node, i) => index.set(node[0], i))
  const n = raw.nodes.length
  const lon = Float64Array.from(raw.nodes.map(node => node[1]))
  const lat = Float64Array.from(raw.nodes.map(node => node[2]))
  const home = Float64Array.from(raw.nodes.map(node => node[3]))
  const id = Int32Array.from(raw.nodes.map(node => node[0]))
  const start = index.get(raw.startNode) ?? 0

  // Undirected adjacency over the raw edges. Parallel edges and self loops are
  // kept: a pair of parallel ways between the same two junctions is a genuine
  // two-way-round, and a self loop is a genuine small circuit.
  const rawEdges: RawEdgeRecord[] = []
  for (const [, origin, from, to, metres, flags, geometry] of raw.edges) {
    const a = index.get(from), b = index.get(to)
    if (a === undefined || b === undefined) continue
    const points: LngLat[] = []
    if (geometry) for (let i = 0; i + 1 < geometry.length; i += 2) points.push([geometry[i], geometry[i + 1]])
    if (points.length < 2) { points.length = 0; points.push([lon[a], lat[a]], [lon[b], lat[b]]) }
    rawEdges.push({ a, b, metres, origin, forward: (flags & 1) !== 0, backward: (flags & 2) !== 0, geometry: points })
  }

  const incident: number[][] = Array.from({ length: n }, () => [])
  rawEdges.forEach((edge, i) => { incident[edge.a].push(i); if (edge.b !== edge.a) incident[edge.b].push(i) })

  // The start-rooted shortest-path tree over the unreduced edges. The field
  // already carries the distances; what is wanted here is the ancestry, so the
  // stem from the door out to the 2-core can be drawn rather than guessed.
  const parentNode = new Int32Array(n).fill(-1)
  const parentRaw = new Int32Array(n).fill(-1)
  // The field already carries every settled node's shortest distance from the
  // start, so the tree it came from can be read back in one pass rather than
  // searched for again: a node's parent is the neighbour whose own distance
  // plus the edge between them is the node's distance.
  for (let node = 0; node < n; node++) {
    if (node === start) continue
    for (const e of incident[node]) {
      const edge = rawEdges[e]
      const other = edge.a === node ? edge.b : edge.a
      if (!(edge.a === other ? edge.forward : edge.backward)) continue
      if (Math.abs(home[other] + edge.metres - home[node]) > 0.2) continue
      parentNode[node] = other
      parentRaw[node] = e
      break
    }
  }

  // ------------------------------------------------------------- 2-core peel
  const alive = new Uint8Array(rawEdges.length).fill(1)
  const degree = Int32Array.from(incident.map(list => list.length))
  const queue: number[] = []
  for (let node = 0; node < n; node++) if (degree[node] <= 1) queue.push(node)
  let peeled = 0
  while (queue.length) {
    const node = queue.pop()!
    if (degree[node] > 1) continue
    if (degree[node] === 1) peeled++
    for (const e of incident[node]) {
      if (!alive[e]) continue
      alive[e] = 0
      const other = rawEdges[e].a === node ? rawEdges[e].b : rawEdges[e].a
      degree[node]--
      if (other !== node) { degree[other]--; if (degree[other] <= 1) queue.push(other) }
    }
  }
  const coreEdges = rawEdges.filter((_, i) => alive[i])
  const coreNodes = new Set<number>()
  for (const edge of coreEdges) { coreNodes.add(edge.a); coreNodes.add(edge.b) }

  // ------------------------------------------------------- degree-2 contract
  const coreIncident: number[][] = Array.from({ length: n }, () => [])
  rawEdges.forEach((edge, i) => {
    if (!alive[i]) return
    coreIncident[edge.a].push(i)
    if (edge.b !== edge.a) coreIncident[edge.b].push(i)
  })
  const junction = (node: number) => coreIncident[node].length !== 2 || node === start
  const usedEdge = new Uint8Array(rawEdges.length)
  const edges: SuperEdge[] = []
  const pushChain = (first: number, from: number) => {
    let current = first, at = from
    const physical: Array<[number, number]> = []
    const geometry: LngLat[] = []
    let metres = 0, forward = true, backward = true
    for (;;) {
      const edge = rawEdges[current]
      usedEdge[current] = 1
      const runsForward = edge.a === at
      const next = runsForward ? edge.b : edge.a
      const points = runsForward ? edge.geometry : [...edge.geometry].reverse()
      physical.push([edge.origin, edge.metres])
      metres += edge.metres
      forward &&= runsForward ? edge.forward : edge.backward
      backward &&= runsForward ? edge.backward : edge.forward
      for (const point of points) if (!geometry.length || geometry[geometry.length - 1] !== point) geometry.push(point)
      at = next
      if (junction(next)) break
      const onward = coreIncident[next].find(candidate => candidate !== current && !usedEdge[candidate])
      if (onward === undefined) break
      current = onward
    }
    edges.push({ from, to: at, metres, physical, geometry, forward, backward })
  }
  for (let node = 0; node < n; node++) {
    if (!coreNodes.has(node) || !junction(node)) continue
    for (const e of coreIncident[node]) if (!usedEdge[e]) pushChain(e, node)
  }
  // A ring of degree-2 nodes touching no junction at all: rare, but it is a
  // perfectly good circuit and must not be dropped.
  for (let e = 0; e < rawEdges.length; e++) if (alive[e] && !usedEdge[e]) pushChain(e, rawEdges[e].a)

  // ------------------------------------------------------------------- arcs
  const arcs: Arc[][] = Array.from({ length: n }, () => [])
  edges.forEach((edge, i) => {
    const line = edge.geometry
    const outFrom = bearing(line[0], line[1] ?? line[0])
    const inTo = bearing(line[line.length - 2] ?? line[0], line[line.length - 1])
    if (edge.forward) arcs[edge.from].push({ edge: i, to: edge.to, metres: edge.metres, outBearing: outFrom, inBearing: inTo, forward: true })
    if (edge.backward) arcs[edge.to].push({ edge: i, to: edge.from, metres: edge.metres, outBearing: (inTo + 180) % 360, inBearing: (outFrom + 180) % 360, forward: false })
  })

  return {
    name: raw.name, targetMetres: raw.targetMetres, limitMetres: raw.limitMetres,
    start, startPoint: [raw.snappedLon, raw.snappedLat], id, lon, lat, home, edges, arcs,
    rawEdges, parentNode, parentRaw,
    stats: {
      rawNodes: raw.nodes.length, rawEdges: rawEdges.length,
      coreNodes: coreNodes.size, coreEdges: coreEdges.length,
      nodes: new Set(edges.flatMap(edge => [edge.from, edge.to])).size, edges: edges.length,
      peeledNodes: peeled, exportWallMs: raw.wallMs, buildWallMs: performance.now() - began,
    },
  }
}

/**
 * The doorstep stem: the walk from the routing start out to `node`, drawn on
 * the unreduced edges. Empty where the start is already in the 2-core.
 */
export function stemTo(graph: SearchGraph, node: number): { geometry: LngLat[]; physical: Array<[number, number]>; metres: number } {
  const steps: Array<{ edge: number; from: number }> = []
  let at = node
  let guard = 0
  while (at !== graph.start && graph.parentRaw[at] >= 0 && guard++ < graph.rawEdges.length + 2) {
    steps.push({ edge: graph.parentRaw[at], from: graph.parentNode[at] })
    at = graph.parentNode[at]
  }
  steps.reverse()
  const geometry: LngLat[] = []
  const physical: Array<[number, number]> = []
  let metres = 0
  for (const step of steps) {
    const edge = graph.rawEdges[step.edge]
    const points = edge.a === step.from ? edge.geometry : [...edge.geometry].reverse()
    for (const point of points) if (!geometry.length || geometry[geometry.length - 1][0] !== point[0] || geometry[geometry.length - 1][1] !== point[1]) geometry.push(point)
    physical.push([edge.origin, edge.metres])
    metres += edge.metres
  }
  return { geometry, physical, metres }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const graphs = loadSubgraphs(new URL('subgraphs.json', import.meta.url)).map(buildSearchGraph)
  console.log('| fixture | limit m | raw nodes | raw edges | 2-core nodes | 2-core edges | search nodes | search arcs | export ms | build ms |')
  console.log('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
  for (const graph of graphs) {
    const s = graph.stats
    const arcCount = graph.arcs.reduce((sum, list) => sum + list.length, 0)
    console.log(`| ${graph.name} | ${Math.round(graph.limitMetres)} | ${s.rawNodes} | ${s.rawEdges} | ${s.coreNodes} | ${s.coreEdges} | ${s.nodes} | ${arcCount} | ${s.exportWallMs.toFixed(2)} | ${s.buildWallMs.toFixed(1)} |`)
  }
  for (const graph of graphs) {
    const lengths = graph.edges.map(edge => edge.metres).sort((a, b) => a - b)
    const startArcs = graph.arcs[graph.start]?.length ?? 0
    console.log(`\n${graph.name}: start node ${graph.id[graph.start]} in 2-core=${startArcs > 0}, arcs at start ${startArcs}, `
      + `super-edge metres median ${lengths[lengths.length >> 1]?.toFixed(0)}, max ${lengths[lengths.length - 1]?.toFixed(0)}, `
      + `home max ${Math.max(...graph.home).toFixed(0)}`)
  }
}
