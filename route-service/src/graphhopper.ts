import type { LngLat } from './loops/geo.js'
import type { CustomModel } from './loops/avoidance.js'
import type { ClassSpan, EdgeSpan } from './loops/edges.js'

/**
 * The only thing that talks to GraphHopper.
 *
 * GraphHopper is used here as a pedestrian pathfinder and nothing more: point
 * to point, one leg at a time. Its round-trip algorithm is deliberately not
 * used — the shape of a Looper walk is decided by the loop generator, and the
 * quality engine has to be able to reject what comes back.
 */

export type GraphHopperStep = {
  instruction: string
  distanceMeters: number
  durationSeconds: number
  /** GraphHopper `sign`, kept raw for the quality engine. */
  sign?: number
  maneuver?: string
  road?: string
  roadClass?: string
  startIndex?: number
  endIndex?: number
}

export type GraphHopperLeg = {
  coordinates: LngLat[]
  distanceMeters: number
  durationSeconds: number
  steps: GraphHopperStep[]
  /**
   * Which network edge each stretch of the line ran on, when the engine
   * reported it. Absent is an ordinary outcome, not a fault: everything that
   * uses these has a geometric fallback.
   */
  edges?: EdgeSpan[]
  /**
   * Which road class each stretch of the line ran on, when the engine
   * reported it. Feeds the pavement-hop measure; absent is ordinary.
   */
  roadClasses?: ClassSpan[]
  /**
   * How many nodes the engine settled to answer this, from its own `hints`.
   *
   * Milliseconds say how long a call took; this says how much of the graph it
   * had to look at, which is the only thing that separates "the engine is
   * busy" from "the search is doing far more work than it should". A leg
   * answered by a working landmark heuristic settles a few thousand; one that
   * has fallen back to a bidirectional Dijkstra over the whole island settles
   * orders of magnitude more, at the same wall-clock cost per call under load.
   *
   * Optional because it is a hint rather than a contract, and nothing depends
   * on it: it is reported and never read by the algorithm.
   */
  visitedNodes?: number
}

export class GraphHopperError extends Error {
  constructor(message: string, readonly status?: number, readonly kind: 'unreachable' | 'timeout' | 'transport' | 'server' | 'handle' = 'server') {
    super(message)
    this.name = 'GraphHopperError'
  }
}

/**
 * A corridor set the engine has already been given, named rather than
 * restated. `register` and `define` appear only the first time this process
 * uses a handle; after that the id alone is the whole model.
 */
export type ModelHandle = {
  generation: string
  id: string
  register?: Record<string, unknown>
  define?: { areas: string[]; multiply_by?: string; distance_influence?: number }
}

export type RouteRequestOptions = {
  profile: string
  customModel?: CustomModel
  /** Sent instead of `customModel`, against a facade that understands handles. */
  modelHandle?: ModelHandle
  locale?: string
  timeoutMs?: number
  signal?: AbortSignal
}

/** What a leg cost at the boundary, alongside the leg itself. */
export type RouteResult = {
  payload: unknown
  requestBytes: number
  responseBytes: number
  /** Request written to response read, so it includes the engine's own time. */
  transportMs: number
  parseMs: number
  /** What the engine says it spent, when it says. Zero from a build that does not. */
  timing: { dispatchMs: number; routeMs: number; serializeMs: number }
}

/**
 * Split out from the fetch so the request shape can be asserted in tests
 * without a server. `ch.disable` is required for a per-request custom model,
 * and the graph is built without Contraction Hierarchies in any case.
 */
export function buildRouteBody(points: LngLat[], options: Pick<RouteRequestOptions, 'profile' | 'customModel' | 'locale' | 'modelHandle'>): Record<string, unknown> {
  const body: Record<string, unknown> = {
    points: points.map(([lng, lat]) => [lng, lat]),
    profile: options.profile,
    'ch.disable': true,
    points_encoded: false,
    instructions: true,
    elevation: false,
    calc_points: true,
    locale: options.locale ?? 'en',
    // street_name feeds the walk instructions. edge_id is what turns "these
    // two stretches pass within seventeen metres of each other" into "these
    // two stretches are the same piece of network" — see loops/edges.ts. It is
    // a built-in GraphHopper detail needing no encoded value, and a build that
    // does not return it simply falls back to geometry.
    details: ['street_name', 'road_class', 'edge_id'],
    snap_preventions: ['ferry'],
  }
  if (options.customModel) body.custom_model = options.customModel
  // A handle and a model are the same statement made two ways, so a body
  // carries one or the other and never both: two sources of truth for what is
  // being avoided is exactly the shape of bug this protocol must not have.
  if (options.modelHandle) body.looper_model = options.modelHandle
  return body
}

const SIGNS: Record<number, string> = {
  [-98]: 'u-turn',
  [-8]: 'u-turn-left',
  [-7]: 'keep-left',
  [-3]: 'sharp-left',
  [-2]: 'turn-left',
  [-1]: 'slight-left',
  0: 'continue',
  1: 'slight-right',
  2: 'turn-right',
  3: 'sharp-right',
  4: 'finish',
  5: 'waypoint',
  6: 'roundabout',
  7: 'keep-right',
  8: 'u-turn-right',
}

export const maneuverName = (sign: number | undefined) => (sign === undefined ? undefined : SIGNS[sign] ?? 'continue')
/** The signs GraphHopper uses for a genuine turn-around. */
export const isUTurnSign = (sign: number | undefined) => sign === 8 || sign === -8 || sign === -98

export class GraphHopperClient {
  constructor(
    private readonly baseUrl: string,
    private readonly profile: string,
    private readonly defaultTimeoutMs = 8000,
  ) {}

  async route(points: LngLat[], options: Omit<RouteRequestOptions, 'profile'> = {}): Promise<RouteResult> {
    const body = buildRouteBody(points, {
      profile: this.profile,
      customModel: options.customModel,
      modelHandle: options.modelHandle,
      locale: options.locale,
    })
    return this.post('/route', body, options.timeoutMs ?? this.defaultTimeoutMs, options.signal)
  }

  /**
   * Open a scope for one generation's corridors, if this engine keeps them.
   *
   * Undefined means "this engine does not know about handles", which the
   * shipped GraphHopper container does not — so it is an ordinary answer and
   * not a failure. Anything else is a real fault and is thrown.
   */
  async beginGeneration(signal?: AbortSignal, timeoutMs = 3000): Promise<string | undefined> {
    let response: Response
    try {
      response = await this.request('/generation', { method: 'POST' }, timeoutMs, signal)
    } catch (error) {
      if (error instanceof GraphHopperError && error.status !== undefined && error.status < 500) return undefined
      throw error
    }
    const data = (await response.json()) as { generation?: string }
    return data?.generation
  }

  async endGeneration(generation: string, timeoutMs = 3000): Promise<void> {
    await this.request(`/generation/${encodeURIComponent(generation)}`, { method: 'DELETE' }, timeoutMs)
  }

  /**
   * How far the network goes from a point, within a walking budget.
   *
   * GraphHopper's shortest-path-tree endpoint, which is part of the standard
   * open-source server but is not guaranteed to be enabled on every build. It
   * is asked for as CSV, which is what it documents itself as returning, and
   * anything it answers that is not a table of numbers is treated as "this
   * build does not do this" rather than as an error worth propagating: every
   * caller has a path that works without it.
   */
  async shortestPathTree(
    point: LngLat,
    distanceLimitMetres: number,
    options: { timeoutMs?: number; signal?: AbortSignal } = {},
  ): Promise<Array<{ point: LngLat; networkMetres: number }> | undefined> {
    const query = new URLSearchParams({
      point: `${point[1]},${point[0]}`,
      profile: this.profile,
      distance_limit: String(Math.round(distanceLimitMetres)),
      time_limit: '0',
      columns: 'longitude,latitude,distance',
      reverse_flow: 'false',
    })
    try {
      const response = await this.request(`/spt?${query}`, { method: 'GET' }, options.timeoutMs ?? 4000, options.signal)
      return parseShortestPathTree(await response.text())
    } catch {
      // Not available, not reachable, or not answering in time. All three mean
      // the same thing to a caller that has to work without it.
      return undefined
    }
  }

  async info(timeoutMs = 3000): Promise<{ version?: string; profiles: string[]; bbox?: number[] }> {
    const response = await this.request('/info', { method: 'GET' }, timeoutMs)
    const data = (await response.json()) as any
    return { version: data?.version, profiles: (data?.profiles ?? []).map((p: any) => p?.name).filter(Boolean), bbox: data?.bbox }
  }

  private async post(path: string, body: unknown, timeoutMs: number, signal?: AbortSignal): Promise<RouteResult> {
    const serialised = JSON.stringify(body)
    const began = performance.now()
    const response = await this.request(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: serialised,
    }, timeoutMs, signal)
    // Read as text and parsed here rather than through `response.json()`, so
    // that what the engine cost and what parsing its answer costs are two
    // numbers instead of one. Phase 2 needed them apart; so does this phase.
    const text = await response.text()
    const transportMs = performance.now() - began
    const parseBegan = performance.now()
    const payload = JSON.parse(text)
    return {
      payload,
      requestBytes: serialised.length,
      responseBytes: text.length,
      transportMs,
      parseMs: performance.now() - parseBegan,
      timing: parseTiming(response.headers.get('x-looper-timing')),
    }
  }

  private async request(path: string, init: RequestInit, timeoutMs: number, signal?: AbortSignal): Promise<Response> {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(new Error('timeout')), timeoutMs)
    const onOuterAbort = () => controller.abort(signal?.reason)
    signal?.addEventListener('abort', onOuterAbort, { once: true })
    try {
      const response = await fetch(new URL(path, this.baseUrl), { ...init, signal: controller.signal })
      if (!response.ok) {
        const { message, kind } = await readMessage(response)
        // GraphHopper answers 400 for "there is no path between these points",
        // which for us is an ordinary outcome, not a fault.
        throw new GraphHopperError(message, response.status, kind)
      }
      return response
    } catch (error) {
      if (error instanceof GraphHopperError) throw error
      const aborted = (error as Error)?.name === 'AbortError' || controller.signal.aborted
      throw new GraphHopperError(
        aborted ? 'Routing engine did not answer in time.' : `Routing engine unreachable: ${(error as Error)?.message ?? 'unknown'}`,
        undefined,
        aborted ? 'timeout' : 'transport',
      )
    } finally {
      clearTimeout(timer)
      signal?.removeEventListener('abort', onOuterAbort)
    }
  }
}

/**
 * `longitude,latitude,distance` with a header row. Rows that are not three
 * finite numbers are skipped rather than guessed at; a probe is a hint, and a
 * hint assembled from misread rows is worse than no hint.
 */
export function parseShortestPathTree(body: string): Array<{ point: LngLat; networkMetres: number }> | undefined {
  const lines = body.split('\n')
  const reached: Array<{ point: LngLat; networkMetres: number }> = []
  for (const line of lines) {
    const fields = line.split(',')
    if (fields.length < 3) continue
    const lng = Number(fields[0])
    const lat = Number(fields[1])
    const metres = Number(fields[2])
    if (!Number.isFinite(lng) || !Number.isFinite(lat) || !Number.isFinite(metres)) continue
    if (Math.abs(lng) > 180 || Math.abs(lat) > 90 || metres < 0) continue
    reached.push({ point: [lng, lat], networkMetres: metres })
  }
  return reached.length ? reached : undefined
}

async function readMessage(response: Response): Promise<{ message: string; kind: GraphHopperError['kind'] }> {
  const fallback = response.status === 400 ? 'unreachable' : 'server'
  try {
    const data = (await response.json()) as any
    // A handle the engine no longer holds is its own kind of failure: it means
    // "say the model again", and it must never be read as "there is no path".
    const kind = data?.looper_error === 'unknown_handle' ? 'handle' : fallback
    return { message: String(data?.message ?? `HTTP ${response.status}`), kind }
  } catch {
    return { message: `HTTP ${response.status}`, kind: fallback }
  }
}

/** `dispatch=203,route=1773,serialize=1532`, in microseconds. Absent is zero. */
function parseTiming(header: string | null): RouteResult['timing'] {
  const timing = { dispatchMs: 0, routeMs: 0, serializeMs: 0 }
  if (!header) return timing
  for (const part of header.split(',')) {
    const [name, value] = part.split('=')
    const ms = Number(value) / 1000
    if (!Number.isFinite(ms)) continue
    if (name === 'dispatch') timing.dispatchMs = ms
    else if (name === 'route') timing.routeMs = ms
    else if (name === 'serialize') timing.serializeMs = ms
  }
  return timing
}

export function parseLeg(payload: any): GraphHopperLeg {
  const path = payload?.paths?.[0]
  const coordinates = path?.points?.coordinates
  if (!path || !Array.isArray(coordinates) || coordinates.length < 2) {
    throw new GraphHopperError('Routing engine returned no path.', undefined, 'unreachable')
  }
  const streets: Array<[number, number, string]> = path?.details?.street_name ?? []
  const roadClasses: Array<[number, number, string]> = path?.details?.road_class ?? []
  const steps: GraphHopperStep[] = (path.instructions ?? []).map((instruction: any) => ({
    instruction: String(instruction?.text ?? ''),
    distanceMeters: Number(instruction?.distance ?? 0),
    durationSeconds: Number(instruction?.time ?? 0) / 1000,
    sign: typeof instruction?.sign === 'number' ? instruction.sign : undefined,
    maneuver: maneuverName(instruction?.sign),
    road: roadNameFor(instruction, streets),
    roadClass: detailFor(instruction, roadClasses),
    startIndex: instruction?.interval?.[0],
    endIndex: instruction?.interval?.[1],
  }))
  const edges = parseEdgeSpans(path?.details?.edge_id, coordinates.length)
  const classSpans = parseClassSpans(roadClasses, coordinates.length)
  // GraphHopper reports this beside the paths rather than inside one, and
  // spells it with a dot in the key. A build that does not report it is not a
  // build that is broken.
  const visited = Number(payload?.hints?.['visited_nodes.sum'])
  return {
    coordinates: coordinates.map(([lng, lat]: number[]) => [lng, lat] as LngLat),
    distanceMeters: Number(path.distance ?? 0),
    durationSeconds: Number(path.time ?? 0) / 1000,
    steps,
    ...(edges ? { edges } : {}),
    ...(classSpans ? { roadClasses: classSpans } : {}),
    ...(Number.isFinite(visited) ? { visitedNodes: visited } : {}),
  }
}

/**
 * GraphHopper reports a path detail as `[startIndex, endIndex, value]` triples
 * indexing into the returned line. Anything that is not a well-formed triple
 * pointing at a real stretch of that line is dropped: a detail we cannot trust
 * is missing data, and missing data has a fallback. A detail we half-trust
 * produces a wrong number that looks like a right one.
 */
function parseEdgeSpans(details: unknown, pointCount: number): EdgeSpan[] | undefined {
  if (!Array.isArray(details) || !details.length) return undefined
  const spans: EdgeSpan[] = []
  for (const entry of details) {
    if (!Array.isArray(entry) || entry.length < 3) continue
    const [startIndex, endIndex, id] = entry
    if (typeof startIndex !== 'number' || typeof endIndex !== 'number' || typeof id !== 'number') continue
    if (!Number.isInteger(startIndex) || !Number.isInteger(endIndex) || !Number.isInteger(id)) continue
    if (startIndex < 0 || endIndex >= pointCount || endIndex <= startIndex) continue
    spans.push({ id, startIndex, endIndex })
  }
  return spans.length ? spans : undefined
}

/**
 * The same triples as `parseEdgeSpans`, kept as spans rather than collapsed
 * onto instructions. A step's road class answers "what am I turning onto";
 * these answer "what did the walk actually run on, and where" — which is what
 * counting pavement hops needs, since a hop happens mid-step as often as at
 * one. Malformed triples are dropped on the same principle: half-trusted data
 * produces a wrong number that looks like a right one.
 */
function parseClassSpans(details: Array<[number, number, string]>, pointCount: number): ClassSpan[] | undefined {
  if (!Array.isArray(details) || !details.length) return undefined
  const spans: ClassSpan[] = []
  for (const entry of details) {
    if (!Array.isArray(entry) || entry.length < 3) continue
    const [startIndex, endIndex, value] = entry
    if (typeof startIndex !== 'number' || typeof endIndex !== 'number') continue
    if (typeof value !== 'string' || !value) continue
    if (!Number.isInteger(startIndex) || !Number.isInteger(endIndex)) continue
    if (startIndex < 0 || endIndex >= pointCount || endIndex <= startIndex) continue
    spans.push({ value, startIndex, endIndex })
  }
  return spans.length ? spans : undefined
}

function detailFor(instruction: any, details: Array<[number, number, string]>): string | undefined {
  const from = instruction?.interval?.[0]
  if (typeof from !== 'number') return undefined
  return details.find(([start, end]) => from >= start && from < end)?.[2] || undefined
}

/**
 * `street_name` on the instruction is the road being turned *onto*, which is
 * what the walk screen reads out. Path details are the fallback when the
 * instruction has none.
 */
function roadNameFor(instruction: any, streets: Array<[number, number, string]>): string | undefined {
  const direct = instruction?.street_name
  if (typeof direct === 'string' && direct && direct !== '-') return direct
  return detailFor(instruction, streets)
}
