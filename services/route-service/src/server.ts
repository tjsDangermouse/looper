import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import { config } from './config.js'
import { GraphHopperClient, GraphHopperError } from './graphhopper.js'
import { coarseLocation, log } from './log.js'
import { createRateLimiter } from './http/rateLimit.js'
import { ValidationError, parseLoopRequest } from './http/validate.js'
import { generateLoops, type Diagnostics } from './loops/generate.js'
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

export function createApp(options: { graphhopper?: GraphHopperClient; regionalGraphs?: RegionalGraph[] } = {}): Server {
  const graphhopper = options.graphhopper ?? new GraphHopperClient(config.graphhopperIomUrl, config.graphhopperProfile, config.legTimeoutMs)
  const regionalGraphs = options.regionalGraphs ?? [
    { id: 'isle-of-man' as const, bounds: REGION_BOUNDS['isle-of-man'], graphhopper },
    { id: 'england' as const, bounds: REGION_BOUNDS.england, graphhopper: new GraphHopperClient(config.graphhopperEnglandUrl, config.graphhopperProfile, config.legTimeoutMs) },
  ]
  const limiter = createRateLimiter(config.rateLimitPerMinute)

  return createServer((request, response) => {
    void handle(request, response, regionalGraphs, limiter).catch(error => {
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

  // One clock for the whole request. When it runs out every routing call still
  // in flight is cancelled rather than left running against the engine.
  const controller = new AbortController()
  const deadline = setTimeout(() => controller.abort(new Error('deadline')), config.requestTimeoutMs)
  request.on('close', () => controller.abort(new Error('client-gone')))
  const startedAt = Date.now()

  try {
    let diagnostics: Diagnostics | undefined
    const result = await generateLoops(parsed, {
      candidateCount: config.candidateCount,
      concurrency: config.concurrency,
      signal: controller.signal,
      onDiagnostics: value => { diagnostics = value },
      route: (points, customModel) =>
        regionalGraph.graphhopper.route(points as LngLat[], { customModel, signal: controller.signal, timeoutMs: config.legTimeoutMs }),
    })
    log('info', 'loops', {
      mode: parsed.mode,
      km: parsed.distanceKm,
      minutes: parsed.durationMinutes,
      near: coarseLocation(parsed.start.lng, parsed.start.lat),
      region: regionalGraph.id,
      ms: Date.now() - startedAt,
      ...diagnostics,
    })
    return send(response, 200, result)
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

function send(response: ServerResponse, status: number, payload: unknown) {
  const body = JSON.stringify(payload)
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body), 'Cache-Control': 'no-store' })
  response.end(body)
}
