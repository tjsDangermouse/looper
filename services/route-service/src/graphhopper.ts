import type { LngLat } from './loops/geo.js'
import type { CustomModel } from './loops/avoidance.js'

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
}

export class GraphHopperError extends Error {
  constructor(message: string, readonly status?: number, readonly kind: 'unreachable' | 'timeout' | 'transport' | 'server' = 'server') {
    super(message)
    this.name = 'GraphHopperError'
  }
}

export type RouteRequestOptions = {
  profile: string
  customModel?: CustomModel
  locale?: string
  timeoutMs?: number
  signal?: AbortSignal
}

/**
 * Split out from the fetch so the request shape can be asserted in tests
 * without a server. `ch.disable` is required for a per-request custom model,
 * and the graph is built without Contraction Hierarchies in any case.
 */
export function buildRouteBody(points: LngLat[], options: Pick<RouteRequestOptions, 'profile' | 'customModel' | 'locale'>): Record<string, unknown> {
  const body: Record<string, unknown> = {
    points: points.map(([lng, lat]) => [lng, lat]),
    profile: options.profile,
    'ch.disable': true,
    points_encoded: false,
    instructions: true,
    elevation: false,
    calc_points: true,
    locale: options.locale ?? 'en',
    // street_name feeds the reversed-walk instructions; edge ids are a
    // supporting signal for repeat detection, with geometry still the truth.
    details: ['street_name', 'road_class'],
    snap_preventions: ['ferry'],
  }
  if (options.customModel) body.custom_model = options.customModel
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

  async route(points: LngLat[], options: Omit<RouteRequestOptions, 'profile'> = {}): Promise<GraphHopperLeg> {
    const body = buildRouteBody(points, { profile: this.profile, customModel: options.customModel, locale: options.locale })
    const payload = await this.post('/route', body, options.timeoutMs ?? this.defaultTimeoutMs, options.signal)
    return parseLeg(payload)
  }

  async info(timeoutMs = 3000): Promise<{ version?: string; profiles: string[]; bbox?: number[] }> {
    const response = await this.request('/info', { method: 'GET' }, timeoutMs)
    const data = (await response.json()) as any
    return { version: data?.version, profiles: (data?.profiles ?? []).map((p: any) => p?.name).filter(Boolean), bbox: data?.bbox }
  }

  private async post(path: string, body: unknown, timeoutMs: number, signal?: AbortSignal) {
    const response = await this.request(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }, timeoutMs, signal)
    return (await response.json()) as any
  }

  private async request(path: string, init: RequestInit, timeoutMs: number, signal?: AbortSignal): Promise<Response> {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(new Error('timeout')), timeoutMs)
    const onOuterAbort = () => controller.abort(signal?.reason)
    signal?.addEventListener('abort', onOuterAbort, { once: true })
    try {
      const response = await fetch(new URL(path, this.baseUrl), { ...init, signal: controller.signal })
      if (!response.ok) {
        const detail = await readMessage(response)
        // GraphHopper answers 400 for "there is no path between these points",
        // which for us is an ordinary outcome, not a fault.
        throw new GraphHopperError(detail, response.status, response.status === 400 ? 'unreachable' : 'server')
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

async function readMessage(response: Response): Promise<string> {
  try {
    const data = (await response.json()) as any
    return String(data?.message ?? `HTTP ${response.status}`)
  } catch {
    return `HTTP ${response.status}`
  }
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
  return {
    coordinates: coordinates.map(([lng, lat]: number[]) => [lng, lat] as LngLat),
    distanceMeters: Number(path.distance ?? 0),
    durationSeconds: Number(path.time ?? 0) / 1000,
    steps,
  }
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
