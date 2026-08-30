import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import { config } from './config.js'
import { ConcurrencyLimiter, LimiterBusyError } from './concurrencyLimiter.js'
import { GraphHopperClient, GraphHopperError } from './graphhopper.js'
import { GenerationScope, createBoundary } from './boundary.js'
import { coarseLocation, log } from './log.js'
import { createRateLimiter } from './http/rateLimit.js'
import { ValidationError, parseLoopRequest } from './http/validate.js'
import { generateLoops, type Diagnostics } from './loops/generate.js'
import { RequestMetrics } from './loops/metrics.js'
import { RouteCache, cacheKeyFor, type CacheContext } from './loops/cache.js'
import type { LngLat } from './loops/geo.js'
import { graphForLocation, REGION_BOUNDS, type RegionalGraph } from './regions.js'

/**
 * The Looper API.
 *
 *   POST /v1/loops   ask for walking loops from a point
 *   GET  /health     is the service, and the engine behind it, alive
 *
 * The app talks to this and to nothing else. No routing provider is named in
 * any response, and no engine error text reaches a browser.
 */

// Refresh requests include compact outlines of the three loops already shown,
// so the service can deliberately avoid them without accepting unbounded input.
const MAX_BODY_BYTES = 32 * 1024
const GENERIC_ERROR = 'Routes are unavailable right now. Please try again.'
const BUSY_ERROR = 'The route service is busy. Please try again in a moment.'
const UNSUPPORTED_LOCATION = 'Looper is not available for this location yet.'
/** How long a region's graph identity is trusted before the engine is asked again. */
const GRAPH_VERSION_TTL_MS = 5 * 60 * 1000

export function createApp(options: { graphhopper?: GraphHopperClient; regionalGraphs?: RegionalGraph[] } = {}): Server {
  const graphhopper = options.graphhopper ?? new GraphHopperClient(config.graphhopperIomUrl, config.graphhopperProfile, config.legTimeoutMs)
  const regionalGraphs = options.regionalGraphs ?? [
    { id: 'isle-of-man' as const, bounds: REGION_BOUNDS['isle-of-man'], graphhopper },
    { id: 'england' as const, bounds: REGION_BOUNDS.england, graphhopper: new GraphHopperClient(config.graphhopperEnglandUrl, config.graphhopperProfile, config.legTimeoutMs) },
  ]
  const limiter = createRateLimiter(config.rateLimitPerMinute)
  // Finished answers only, and only for as long as the map behind them is the
  // map they were generated from — see loops/cache.ts.
  const cache = new RouteCache({
    maxEntries: config.cacheMaxEntries,
    ttlMs: config.cacheTtlMs,
    emptyTtlMs: config.cacheEmptyTtlMs,
  })
  const graphVersions = new Map<string, { version: string; askedAt: number }>()
  // One ceiling per GraphHopper client, shared across every walker's request —
  // unlike `config.concurrency`, which only bounds one request's own fan-out.
  const engineLimiters = new WeakMap<GraphHopperClient, ConcurrencyLimiter>(
    regionalGraphs.map(graph => [graph.graphhopper, new ConcurrencyLimiter(config.graphhopperMaxConcurrency, config.graphhopperMaxQueue)]),
  )

  return createServer((request, response) => {
    void handle(request, response, regionalGraphs, limiter, engineLimiters, cache, graphVersions).catch(error => {
      log('error', 'unhandled', { error: String(error) })
      if (!response.headersSent) send(response, 500, { error: GENERIC_ERROR })
    })
  })
}

async function handle(
  request: IncomingMessage,
  response: ServerResponse,
  regionalGraphs: RegionalGraph[],
  limiter: ReturnType<typeof createRateLimiter>,
  engineLimiters: WeakMap<GraphHopperClient, ConcurrencyLimiter>,
  cache: RouteCache,
  graphVersions: Map<string, { version: string; askedAt: number }>,
) {
  applyCors(request, response)
  if (request.method === 'OPTIONS') { response.writeHead(204); response.end(); return }

  const path = new URL(request.url ?? '/', 'http://localhost').pathname
  if (path === '/health' && request.method === 'GET') return health(response, regionalGraphs[0].graphhopper)
  if (path !== '/v1/loops') return send(response, 404, { error: 'Not found.' })
  if (request.method !== 'POST') return send(response, 405, { error: 'Method not allowed.' })

  if (!limiter.take(clientKey(request))) {
    return send(response, 429, { error: 'Please wait a moment before finding more loops.' })
  }

  let body: unknown
  try {
    body = JSON.parse(await readBody(request))
  } catch {
    return send(response, 400, { error: 'Send a valid route request.' })
  }

  let parsed
  try {
    parsed = parseLoopRequest(body)
  } catch (error) {
    if (error instanceof ValidationError) return send(response, 400, { error: error.message })
    throw error
  }
  const regionalGraph = graphForLocation(regionalGraphs, parsed.start)
  if (!regionalGraph) return send(response, 400, { error: UNSUPPORTED_LOCATION })
  const engineLimiter = engineLimiters.get(regionalGraph.graphhopper)

  // One clock for the whole request. When it runs out every routing call still
  // in flight is cancelled rather than left running against the engine.
  const controller = new AbortController()
  const deadline = setTimeout(() => controller.abort(new Error('deadline')), config.requestTimeoutMs)
  request.on('close', () => controller.abort(new Error('client-gone')))
  const startedAt = Date.now()

  // The key has to name the graph the answer came from, or a rebuilt map keeps
  // serving routes over streets that moved. The engine is asked once per
  // region and the answer kept; a version we cannot establish disables the
  // cache for that region rather than guessing at one.
  let cacheKey: string | undefined
  if (config.flags.requestCache) {
    const graphVersion = await graphVersionFor(regionalGraph, graphVersions)
    if (graphVersion) {
      const context: CacheContext = {
        graphVersion,
        region: regionalGraph.id,
        profile: config.graphhopperProfile,
        profileVersion: config.profileVersion,
        flags: config.flags,
        generation: { candidateCount: config.candidateCount, concurrency: config.concurrency },
      }
      cacheKey = cacheKeyFor(parsed, context)
      const hit = cache.get(cacheKey)
      if (hit) {
        log('info', 'loops', {
          mode: parsed.mode,
          activity: parsed.activity ?? 'walking',
          km: parsed.distanceKm,
          minutes: parsed.durationMinutes,
          near: coarseLocation(parsed.start.lng, parsed.start.lat),
          region: regionalGraph.id,
          ms: Date.now() - startedAt,
          cache: 'hit',
          cacheAgeMs: hit.ageMs,
        })
        return send(response, 200, hit.value)
      }
    }
  }

  // Cost telemetry for this one request. Counters only — no coordinate ever
  // reaches it, so it is safe to log in production as it stands.
  const metrics = new RequestMetrics()

  // One scope per walker's request, opened before any leg is routed and
  // released in the `finally` below whatever happens to the request. Undefined
  // against an engine that does not keep corridors, which is every deployment
  // until one is pointed at a facade that does.
  const scope = config.boundary.modelRegistry
    ? await GenerationScope.begin(regionalGraph.graphhopper, controller.signal)
    : undefined
  const boundary = createBoundary({
    client: regionalGraph.graphhopper,
    scope,
    memo: config.boundary.routeMemo,
    timeoutMs: config.legTimeoutMs,
    signal: controller.signal,
    run: call => {
      if (!engineLimiter) return call()
      return engineLimiter.run(call, controller.signal).catch(error => {
        if (error instanceof LimiterBusyError) throw new GraphHopperError('Routing engine busy.', undefined, 'timeout')
        throw error
      })
    },
  })

  try {
    let diagnostics: Diagnostics | undefined
    const result = await generateLoops(parsed, {
      candidateCount: config.candidateCount,
      concurrency: config.concurrency,
      signal: controller.signal,
      metrics,
      flags: config.flags,
      onDiagnostics: value => { diagnostics = value },
      // One optional reachability probe per request, on a short leash of its
      // own: it is an optimisation, and an optimisation is not allowed to be
      // the slowest thing in the request.
      reachFrom: (point, distanceLimitMetres) =>
        regionalGraph.graphhopper.shortestPathTree(point, distanceLimitMetres, {
          signal: controller.signal,
          timeoutMs: config.networkProbeTimeoutMs,
        }),
      route: (points, customModel, _purpose, trace) => boundary.route(points as LngLat[], customModel, trace),
    })
    log('info', 'loops', {
      mode: parsed.mode,
      activity: parsed.activity ?? 'walking',
      km: parsed.distanceKm,
      minutes: parsed.durationMinutes,
      near: coarseLocation(parsed.start.lng, parsed.start.lat),
      region: regionalGraph.id,
      ms: Date.now() - startedAt,
      ...diagnostics,
      // Set after the spread: waypoint mode reports no `diagnostics` at all,
      // and the cost of a waypoint request is exactly what we want to see.
      cost: metrics.snapshot(),
      boundary: boundary.stats(),
      cache: cacheKey ? 'miss' : 'off',
    })
    // Stored only here, on the way to the walker: everything that failed,
    // timed out, or was abandoned took one of the paths below instead.
    if (cacheKey && !controller.signal.aborted) cache.set(cacheKey, result)
    // What the boundary cost, beside the answer rather than inside it: it is a
    // property of this call to the engine, not of the walk, and a cache hit
    // that did no boundary work should not report someone else's.
    return send(response, 200, result, { 'X-Looper-Boundary': JSON.stringify(boundary.stats()) })
  } catch (error) {
    if (controller.signal.aborted && request.destroyed) return
    if (error instanceof GraphHopperError) {
      log('warn', 'engine', { kind: error.kind, status: error.status, ms: Date.now() - startedAt })
      return send(response, 503, { error: error.kind === 'timeout' ? BUSY_ERROR : GENERIC_ERROR })
    }
    if (controller.signal.aborted) {
      log('warn', 'deadline', { ms: Date.now() - startedAt })
      return send(response, 503, { error: BUSY_ERROR })
    }
    log('error', 'loops-failed', { error: error instanceof Error ? error.message : String(error) })
    return send(response, 500, { error: GENERIC_ERROR })
  } finally {
    clearTimeout(deadline)
    // Every corridor this request drew, dropped in one call — including on the
    // paths that failed, timed out or were abandoned, which are exactly the
    // ones a scope would otherwise be left behind by.
    void boundary.end()
  }
}

/**
 * Which graph a region is serving, asked once and remembered. GraphHopper's
 * `/info` carries the engine version and the imported extract's bounding box;
 * together they change whenever the data behind the routes changes.
 */
async function graphVersionFor(graph: RegionalGraph, known: Map<string, { version: string; askedAt: number }>): Promise<string | undefined> {
  const remembered = known.get(graph.id)
  // Re-asked periodically rather than remembered for the life of the process:
  // a graph can be reimported under a running service, and a version fixed at
  // start-up would go on serving routes over streets that have since moved.
  if (remembered && Date.now() - remembered.askedAt < GRAPH_VERSION_TTL_MS) return remembered.version
  try {
    const info = await graph.graphhopper.info()
    const version = `${info.version ?? 'unknown'}:${(info.bbox ?? []).map(edge => edge.toFixed(4)).join(',')}`
    known.set(graph.id, { version, askedAt: Date.now() })
    return version
  } catch {
    // No version, no cache. Serving a route from a graph we cannot identify is
    // exactly the mistake the key exists to prevent.
    return undefined
  }
}

async function health(response: ServerResponse, graphhopper: GraphHopperClient) {
  try {
    const info = await graphhopper.info()
    const ready = info.profiles.includes(config.graphhopperProfile)
    return send(response, ready ? 200 : 503, {
      status: ready ? 'ok' : 'degraded',
      engine: { reachable: true, version: info.version, profile: config.graphhopperProfile, profiles: info.profiles, bbox: info.bbox },
    })
  } catch {
    return send(response, 503, { status: 'degraded', engine: { reachable: false } })
  }
}

function applyCors(request: IncomingMessage, response: ServerResponse) {
  const origin = request.headers.origin
  const allowed = config.corsOrigins.includes('*')
    ? '*'
    : origin && config.corsOrigins.includes(origin) ? origin : undefined
  if (allowed) {
    response.setHeader('Access-Control-Allow-Origin', allowed)
    if (allowed !== '*') response.setHeader('Vary', 'Origin')
  }
  response.setHeader('Access-Control-Allow-Methods', 'POST, GET, OPTIONS')
  response.setHeader('Access-Control-Allow-Headers', 'Content-Type')
  response.setHeader('Access-Control-Max-Age', '600')
}

const clientKey = (request: IncomingMessage) =>
  String(request.headers['x-forwarded-for'] ?? request.socket.remoteAddress ?? 'unknown').split(',')[0].trim()

function readBody(request: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let size = 0
    const chunks: Buffer[] = []
    request.on('data', (chunk: Buffer) => {
      size += chunk.length
      if (size > MAX_BODY_BYTES) { reject(new Error('body too large')); request.destroy(); return }
      chunks.push(chunk)
    })
    request.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    request.on('error', reject)
  })
}

function send(response: ServerResponse, status: number, payload: unknown, headers: Record<string, string> = {}) {
  const body = JSON.stringify(payload)
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body), 'Cache-Control': 'no-store', ...headers })
  response.end(body)
}
