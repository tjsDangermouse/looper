import booleanPointInPolygon from '@turf/boolean-point-in-polygon'
import type { Feature, Polygon } from 'geojson'
import { parseLeg, GraphHopperError, type GraphHopperLeg } from '../src/graphhopper.js'
import type { CustomModel } from '../src/loops/avoidance.js'
import { EARTH_RADIUS_METRES, haversine, toRadians, type LngLat } from '../src/loops/geo.js'
import { mulberry32 } from '../src/loops/random.js'
import type { RoutePurpose } from '../src/loops/metrics.js'

/**
 * A pedestrian network that fits in a test.
 *
 * There is no GraphHopper in CI and no OSM extract in a unit test, so the
 * benchmark needs something with the properties that actually matter: real
 * nodes, real edges, a real shortest-path search, and a real answer to "how
 * much longer is the walk than the crow flies". A straight line multiplied by
 * 1.5 has none of those — it cannot have a chokepoint, cannot have a
 * cul-de-sac, and cannot tell you whether avoiding a corridor costs a block or
 * six kilometres.
 *
 * These networks are small and hand-built, and they are *not* a claim about
 * any real place. What they are is deterministic, cheap, and structurally
 * honest: a grid behaves like a grid, a single bridge behaves like a single
 * bridge, and the difference shows up in the numbers.
 *
 * Responses are emitted as GraphHopper's own JSON and parsed with the
 * service's own `parseLeg`, so the benchmark exercises the real response path
 * — including path details — rather than a hand-made object that can drift
 * away from what the engine actually sends.
 */

export type NetworkEdge = { id: number; a: number; b: number; lengthMetres: number }

export type Network = {
  id: string
  origin: LngLat
  nodes: LngLat[]
  edges: NetworkEdge[]
  /** Edge ids leaving each node. */
  adjacency: number[][]
}

/** Inverse of the equirectangular projection the quality engine measures in. */
export function pointAt(origin: LngLat, eastMetres: number, northMetres: number): LngLat {
  return [
    origin[0] + (eastMetres / (EARTH_RADIUS_METRES * Math.cos(toRadians(origin[1])))) / toRadians(1),
    origin[1] + (northMetres / EARTH_RADIUS_METRES) / toRadians(1),
  ]
}

class NetworkBuilder {
  private readonly index = new Map<string, number>()
  readonly nodes: LngLat[] = []
  readonly edges: NetworkEdge[] = []

  constructor(private readonly origin: LngLat) {}

  node(eastMetres: number, northMetres: number): number {
    const key = `${Math.round(eastMetres)},${Math.round(northMetres)}`
    const existing = this.index.get(key)
    if (existing !== undefined) return existing
    const id = this.nodes.length
    this.nodes.push(pointAt(this.origin, eastMetres, northMetres))
    this.index.set(key, id)
    return id
  }

  link(a: number, b: number) {
    if (a === b) return
    const lengthMetres = haversine(this.nodes[a], this.nodes[b])
    if (lengthMetres <= 0) return
    this.edges.push({ id: this.edges.length, a, b, lengthMetres })
  }

  build(id: string): Network {
    const adjacency: number[][] = this.nodes.map(() => [])
    for (const edge of this.edges) {
      adjacency[edge.a].push(edge.id)
      adjacency[edge.b].push(edge.id)
    }
    return { id, origin: this.origin, nodes: this.nodes, edges: this.edges, adjacency }
  }
}

/** The Isle of Man, so fixtures and live routes are measured at one latitude. */
export const BENCH_ORIGIN: LngLat = [-4.4816, 54.1506]

/**
 * A dense town grid. Every junction connects four ways, which is the easiest
 * ground a loop generator ever gets: any bearing works, and detour over crow
 * flight is the Manhattan factor and nothing worse.
 */
export function denseGrid(spacing = 90, half = 34, origin = BENCH_ORIGIN): Network {
  const builder = new NetworkBuilder(origin)
  const at = (x: number, y: number) => builder.node(x * spacing, y * spacing)
  for (let x = -half; x <= half; x++) {
    for (let y = -half; y <= half; y++) {
      if (x < half) builder.link(at(x, y), at(x + 1, y))
      if (y < half) builder.link(at(x, y), at(x, y + 1))
    }
  }
  return builder.build('dense-grid')
}

/**
 * Suburbia: a coarse through-road lattice with residential loops and blind
 * cul-de-sacs hung off it. The cul-de-sacs are the point — they are what
 * turns a well-aimed corner into a spur the walker has to walk twice.
 */
export function suburban(origin = BENCH_ORIGIN): Network {
  const builder = new NetworkBuilder(origin)
  const random = mulberry32(0x5_0b_ba)
  const spacing = 260
  const half = 12
  const at = (x: number, y: number) => builder.node(x * spacing, y * spacing)
  for (let x = -half; x <= half; x++) {
    for (let y = -half; y <= half; y++) {
      // Roughly one in seven through-links is simply not there, which is what
      // makes suburbia suburbia rather than a grid with bigger blocks.
      if (x < half && random() > 0.14) builder.link(at(x, y), at(x + 1, y))
      if (y < half && random() > 0.14) builder.link(at(x, y), at(x, y + 1))
    }
  }
  // Residential streets inside each block, one arm of which dead-ends.
  for (let x = -half; x < half; x++) {
    for (let y = -half; y < half; y++) {
      if (random() > 0.5) continue
      const junction = at(x, y)
      const midway = builder.node(x * spacing + spacing / 2, y * spacing + spacing / 3)
      builder.link(junction, midway)
      if (random() > 0.45) builder.link(midway, at(x + 1, y))
      else builder.link(midway, builder.node(x * spacing + spacing / 2, y * spacing + spacing / 3 + 70)) // cul-de-sac
    }
  }
  return builder.build('suburban')
}

/**
 * Rural: lanes every 700 m, a few of them missing, and footpaths between some
 * of the junctions. Loops exist here but there are not many of them, and the
 * ones there are have to be found rather than stumbled into.
 */
export function sparseRural(origin = BENCH_ORIGIN): Network {
  const builder = new NetworkBuilder(origin)
  const random = mulberry32(0x2_ea_11)
  const spacing = 700
  const half = 7
  const at = (x: number, y: number) => builder.node(x * spacing, y * spacing)
  for (let x = -half; x <= half; x++) {
    for (let y = -half; y <= half; y++) {
      if (x < half && random() > 0.3) builder.link(at(x, y), at(x + 1, y))
      if (y < half && random() > 0.3) builder.link(at(x, y), at(x, y + 1))
      // The occasional diagonal footpath across a field.
      if (x < half && y < half && random() > 0.75) builder.link(at(x, y), at(x + 1, y + 1))
    }
  }
  return builder.build('sparse-rural')
}

/**
 * A seafront. Everything south of the promenade is water, so half the compass
 * is unreachable from the start and any candidate aimed that way is wasted
 * work — which is exactly what network-aware seeding is meant to notice.
 */
export function coastal(origin = BENCH_ORIGIN): Network {
  const builder = new NetworkBuilder(origin)
  const spacing = 110
  const half = 28
  const at = (x: number, y: number) => builder.node(x * spacing, y * spacing)
  for (let x = -half; x <= half; x++) {
    for (let y = 0; y <= half; y++) {
      if (x < half) builder.link(at(x, y), at(x + 1, y))
      if (y < half) builder.link(at(x, y), at(x, y + 1))
    }
  }
  return builder.build('coastal')
}

/**
 * Two halves of a town with a river between them and one bridge. Any loop
 * that visits both banks walks the bridge twice; that is the ground, not a
 * defect in the walk, and it is the case the retrace gate has to judge
 * without being told.
 */
export function bridgeChokepoint(origin = BENCH_ORIGIN): Network {
  const builder = new NetworkBuilder(origin)
  const spacing = 100
  const half = 22
  const riverNorth = 300
  const riverSouth = -300
  const at = (x: number, y: number) => builder.node(x * spacing, y * spacing)
  const dry = (y: number) => y * spacing > riverNorth || y * spacing < riverSouth
  for (let x = -half; x <= half; x++) {
    for (let y = -half; y <= half; y++) {
      if (!dry(y)) continue
      if (x < half) builder.link(at(x, y), at(x + 1, y))
      if (y < half && dry(y + 1)) builder.link(at(x, y), at(x, y + 1))
    }
  }
  // The one bridge, at x = 0, joining the innermost dry row on each side.
  // It must land on rows the grid loop actually built, or the two banks are
  // not connected at all and the fixture stops being a chokepoint fixture.
  const firstDryNorth = Math.floor(riverNorth / spacing) + 1
  const firstDrySouth = Math.ceil(riverSouth / spacing) - 1
  builder.link(at(0, firstDrySouth), at(0, firstDryNorth))
  return builder.build('bridge-chokepoint')
}

export const NETWORKS: Record<string, () => Network> = {
  'dense-grid': () => denseGrid(),
  suburban,
  'sparse-rural': sparseRural,
  coastal,
  'bridge-chokepoint': bridgeChokepoint,
}

/** Walking speed the synthetic engine reports, matching the service's own estimate. */
const SPEED_METRES_PER_SECOND = 5000 / 3600

export type EngineStats = {
  calls: number
  byPurpose: Map<RoutePurpose, number>
  nodesVisited: number
  /**
   * Path searches performed, which is not the same number as HTTP calls: a
   * multi-point request is one call and several searches. Counting only calls
   * would make "put the whole ring in one request" look free, and it is not.
   */
  routedLegs: number
}

/**
 * A router over one synthetic network, shaped like the real client.
 *
 * Avoidance is modelled the way GraphHopper actually models it: a priority
 * multiplier folded into the weight denominator, so an area with priority
 * 0.05 costs twenty times its length to walk through and is avoided if
 * anything within twenty times the detour exists — and walked anyway if
 * nothing does. A hard block would make the benchmark lie about exactly the
 * cases (one bridge, one promenade) it exists to measure.
 */
export function syntheticEngine(network: Network) {
  const stats: EngineStats = { calls: 0, byPurpose: new Map(), nodesVisited: 0, routedLegs: 0 }
  const midpoints = network.edges.map(edge => midpoint(network.nodes[edge.a], network.nodes[edge.b]))

  const route = async (points: LngLat[], customModel: CustomModel | undefined, purpose: RoutePurpose = 'other'): Promise<GraphHopperLeg> => {
    stats.calls++
    stats.byPurpose.set(purpose, (stats.byPurpose.get(purpose) ?? 0) + 1)
    const priority = priorityPerEdge(network, midpoints, customModel)

    // Every point is honoured, not just the first and last: GraphHopper routes
    // a multi-point request as one path through all of them, and a benchmark
    // that quietly dropped the middle would make a whole strategy look cheap.
    const legs: Path[] = []
    for (let index = 1; index < points.length; index++) {
      stats.routedLegs++
      const leg = shortestPath(network, nearestNode(network, points[index - 1]), nearestNode(network, points[index]), priority, stats)
      if (!leg) throw new GraphHopperError('Connection between locations not found', 400, 'unreachable')
      legs.push(leg)
    }
    return parseLeg(toGraphHopperPayload(network, concatenatePaths(legs)))
  }

  /**
   * The synthetic stand-in for GraphHopper's shortest-path tree: every node
   * within the walking budget, with the network distance to it. Counted as an
   * engine call, because against a real engine that is exactly what it is.
   */
  const reachFrom = async (start: LngLat, distanceLimitMetres: number) => {
    stats.calls++
    stats.byPurpose.set('network-summary', (stats.byPurpose.get('network-summary') ?? 0) + 1)
    const from = nearestNode(network, start)
    const reached = reachableWithin(network, from, distanceLimitMetres, stats)
    return reached.length ? reached : undefined
  }

  return { route, reachFrom, stats }
}

function reachableWithin(network: Network, from: number, limitMetres: number, stats: EngineStats) {
  const cost = new Float64Array(network.nodes.length).fill(Infinity)
  cost[from] = 0
  const queue = new BinaryHeap()
  queue.push(from, 0)
  const settled = new Uint8Array(network.nodes.length)
  const reached: Array<{ point: LngLat; networkMetres: number }> = []

  while (queue.size) {
    const node = queue.pop()!
    if (settled[node]) continue
    settled[node] = 1
    stats.nodesVisited++
    reached.push({ point: network.nodes[node], networkMetres: cost[node] })
    for (const edgeId of network.adjacency[node]) {
      const edge = network.edges[edgeId]
      const next = edge.a === node ? edge.b : edge.a
      if (settled[next]) continue
      const candidate = cost[node] + edge.lengthMetres
      if (candidate > limitMetres || candidate >= cost[next]) continue
      cost[next] = candidate
      queue.push(next, candidate)
    }
  }
  return reached
}

/** Several consecutive path searches presented as the one path they describe. */
function concatenatePaths(legs: Path[]): Path {
  if (legs.length === 1) return legs[0]
  const nodes: number[] = [...legs[0].nodes]
  const edges: number[] = [...legs[0].edges]
  let metres = legs[0].metres
  for (const leg of legs.slice(1)) {
    // The joining node is the same node twice; keep it once.
    nodes.push(...(nodes[nodes.length - 1] === leg.nodes[0] ? leg.nodes.slice(1) : leg.nodes))
    edges.push(...leg.edges)
    metres += leg.metres
  }
  return { nodes, edges, metres }
}

function midpoint(a: LngLat, b: LngLat): LngLat {
  return [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2]
}

function nearestNode(network: Network, point: LngLat): number {
  let best = 0
  let bestDistance = Infinity
  for (let index = 0; index < network.nodes.length; index++) {
    const distance = haversine(network.nodes[index], point)
    if (distance < bestDistance) { bestDistance = distance; best = index }
  }
  return best
}

/**
 * Which edges the custom model penalises. Bounding boxes first: a corridor
 * polygon covers a sliver of the network, and testing every edge against
 * every polygon ring outright is the difference between a benchmark that runs
 * and one that does not.
 */
function priorityPerEdge(network: Network, midpoints: LngLat[], customModel: CustomModel | undefined): Float64Array {
  const priority = new Float64Array(network.edges.length).fill(1)
  const areas = customModel?.areas?.features ?? []
  if (!areas.length) return priority
  const multipliers = new Map<string, number>()
  for (const rule of customModel?.priority ?? []) {
    const match = /^in_(\S+)$/.exec(String(rule.if ?? ''))
    if (match) multipliers.set(match[1], Number(rule.multiply_by))
  }

  for (const area of areas) {
    const id = String((area as Feature<Polygon> & { id?: string }).id ?? '')
    const multiplier = multipliers.get(id)
    if (multiplier === undefined || !Number.isFinite(multiplier)) continue
    const box = boundingBox(area)
    for (let index = 0; index < midpoints.length; index++) {
      const [lng, lat] = midpoints[index]
      if (lng < box[0] || lng > box[2] || lat < box[1] || lat > box[3]) continue
      if (booleanPointInPolygon([lng, lat], area)) priority[index] *= multiplier
    }
  }
  return priority
}

function boundingBox(area: Feature<Polygon>): [number, number, number, number] {
  let west = Infinity, south = Infinity, east = -Infinity, north = -Infinity
  for (const ring of area.geometry.coordinates) {
    for (const [lng, lat] of ring) {
      if (lng < west) west = lng
      if (lng > east) east = lng
      if (lat < south) south = lat
      if (lat > north) north = lat
    }
  }
  return [west, south, east, north]
}

type Path = { nodes: number[]; edges: number[]; metres: number }

/**
 * Dijkstra over `length / priority`, which is GraphHopper's own weight for a
 * custom model at constant speed. Zero priority means impassable.
 */
function shortestPath(network: Network, from: number, to: number, priority: Float64Array, stats: EngineStats): Path | undefined {
  const count = network.nodes.length
  const cost = new Float64Array(count).fill(Infinity)
  const cameFromEdge = new Int32Array(count).fill(-1)
  const settled = new Uint8Array(count)
  cost[from] = 0
  const queue = new BinaryHeap()
  queue.push(from, 0)

  while (queue.size) {
    const node = queue.pop()!
    if (settled[node]) continue
    settled[node] = 1
    stats.nodesVisited++
    if (node === to) break
    for (const edgeId of network.adjacency[node]) {
      const edge = network.edges[edgeId]
      const next = edge.a === node ? edge.b : edge.a
      if (settled[next]) continue
      const factor = priority[edgeId]
      if (factor <= 0) continue
      const candidate = cost[node] + edge.lengthMetres / factor
      if (candidate >= cost[next]) continue
      cost[next] = candidate
      cameFromEdge[next] = edgeId
      queue.push(next, candidate)
    }
  }
  if (!Number.isFinite(cost[to])) return undefined

  const nodes: number[] = [to]
  const edges: number[] = []
  let metres = 0
  let cursor = to
  while (cursor !== from) {
    const edgeId = cameFromEdge[cursor]
    if (edgeId < 0) return undefined
    const edge = network.edges[edgeId]
    edges.push(edgeId)
    metres += edge.lengthMetres
    cursor = edge.a === cursor ? edge.b : edge.a
    nodes.push(cursor)
  }
  nodes.reverse()
  edges.reverse()
  return { nodes, edges, metres }
}

/** A pairing heap would be tidier; an array heap is fewer lines and fast enough. */
class BinaryHeap {
  private readonly nodes: number[] = []
  private readonly costs: number[] = []
  get size() { return this.nodes.length }

  push(node: number, cost: number) {
    this.nodes.push(node)
    this.costs.push(cost)
    let index = this.nodes.length - 1
    while (index > 0) {
      const parent = (index - 1) >> 1
      if (this.costs[parent] <= this.costs[index]) break
      this.swap(parent, index)
      index = parent
    }
  }

  pop(): number | undefined {
    if (!this.nodes.length) return undefined
    const top = this.nodes[0]
    const lastNode = this.nodes.pop()!
    const lastCost = this.costs.pop()!
    if (this.nodes.length) {
      this.nodes[0] = lastNode
      this.costs[0] = lastCost
      let index = 0
      for (;;) {
        const left = index * 2 + 1
        const right = left + 1
        let smallest = index
        if (left < this.nodes.length && this.costs[left] < this.costs[smallest]) smallest = left
        if (right < this.nodes.length && this.costs[right] < this.costs[smallest]) smallest = right
        if (smallest === index) break
        this.swap(smallest, index)
        index = smallest
      }
    }
    return top
  }

  private swap(a: number, b: number) {
    ;[this.nodes[a], this.nodes[b]] = [this.nodes[b], this.nodes[a]]
    ;[this.costs[a], this.costs[b]] = [this.costs[b], this.costs[a]]
  }
}

/**
 * GraphHopper's own response shape, including `edge_id` path details. The
 * service parses this with the same code it uses on a live answer, so a
 * benchmark cannot quietly diverge from production by inventing a friendlier
 * payload than the engine sends.
 */
function toGraphHopperPayload(network: Network, path: Path) {
  const coordinates = path.nodes.map(node => network.nodes[node])
  const edgeDetails: Array<[number, number, number]> = path.edges.map((edgeId, index) => [index, index + 1, edgeId])
  const instructions = path.edges.map((edgeId, index) => ({
    text: `Continue on lane ${edgeId}`,
    distance: network.edges[edgeId].lengthMetres,
    time: Math.round((network.edges[edgeId].lengthMetres / SPEED_METRES_PER_SECOND) * 1000),
    sign: 0,
    street_name: `Lane ${edgeId}`,
    interval: [index, index + 1],
  }))
  instructions.push({
    text: 'Arrive at destination',
    distance: 0,
    time: 0,
    sign: 4,
    street_name: '',
    interval: [coordinates.length - 1, coordinates.length - 1],
  })
  return {
    paths: [{
      points: { type: 'LineString', coordinates },
      distance: path.metres,
      time: Math.round((path.metres / SPEED_METRES_PER_SECOND) * 1000),
      instructions,
      details: {
        edge_id: edgeDetails,
        street_name: edgeDetails.map(([from, to, id]) => [from, to, `Lane ${id}`] as [number, number, string]),
        road_class: edgeDetails.map(([from, to]) => [from, to, 'residential'] as [number, number, string]),
      },
    }],
  }
}
