import { createHash } from 'node:crypto'
import type { CustomModel } from './loops/avoidance.js'
import type { LngLat } from './loops/geo.js'
import { GraphHopperClient, GraphHopperError, parseLeg, type GraphHopperLeg, type ModelHandle } from './graphhopper.js'
import type { BoundaryTrace } from './loops/metrics.js'

/**
 * The Node side of the Looper↔engine boundary.
 *
 * Phase 2 measured where the time Looper attributes to "the engine" actually
 * goes, and the search was 4% of it. The two largest addressable items were
 * both restatement rather than work: 5.6 MB of request bodies, nine tenths of
 * it corridor polygons the engine had already been given, and — inside
 * GraphHopper — turning those same polygons into a weighting again, which cost
 * more across the workload than the graph search did.
 *
 * So this module does two things and deliberately nothing else. It gives a
 * corridor a *name*, so a request can refer to ground already described rather
 * than describing it again; and it remembers the answer to a question already
 * asked, so an identical request is not asked twice. Neither changes what is
 * routed, which candidate is offered, or what any leg comes back as. The
 * algorithm above this file cannot tell it is here.
 */

/** How a corridor polygon and a whole model are named. Content, hashed, truncated. */
const digest = (value: string) => createHash('sha1').update(value).digest('hex').slice(0, 16)

/**
 * Identities are computed once per object, not once per call.
 *
 * `buildAvoidanceAreas` returns fresh objects every time it runs, so this is
 * not the whole story and the content hash below is what actually does the
 * work — but the same model object is handed to a leg and then to that leg's
 * retries, and hashing a twelve-polygon corridor set three times to learn the
 * same thing is exactly the sort of restatement this file exists to stop.
 */
const modelIdentities = new WeakMap<object, ModelIdentity | null>()
const areaIdentities = new WeakMap<object, string>()

export type ModelIdentity = {
  /** Names this model: the ordered corridors, the strength, and nothing else. */
  id: string
  /** The corridors, in the order the model's own condition names them. */
  areaIds: string[]
  areas: unknown[]
  multiplyBy?: string
  distanceInfluence?: number
}

/**
 * What the facade can rebuild from a handle, and what it cannot.
 *
 * Looper builds exactly two shapes of custom model — a corridor set at one of
 * two strengths, and the bare lower-bound model — and the handle protocol
 * knows how to reconstruct those two. Anything else is sent in full, as
 * before. This is not a fallback to a *different* model: it is the same model,
 * carried the old way, and it is the only honest answer for a shape the far
 * side was not told how to rebuild.
 */
export function identify(model: CustomModel | undefined): ModelIdentity | null {
  if (!model) return null
  const cached = modelIdentities.get(model)
  if (cached !== undefined) return cached
  const identity = compute(model)
  modelIdentities.set(model, identity)
  return identity
}

function compute(model: CustomModel): ModelIdentity | null {
  const statements = model.priority ?? []
  const features = model.areas?.features ?? []
  if (statements.length > 1) return null
  if (statements.length === 1 && features.length === 0) return null
  if (statements.length === 0 && features.length > 0) return null

  let multiplyBy: string | undefined
  const areaIds: string[] = []
  if (statements.length === 1) {
    const statement = statements[0]
    const keys = Object.keys(statement)
    if (keys.length !== 2 || !keys.includes('if') || !keys.includes('multiply_by')) return null
    // The condition has to be the one `avoidanceCustomModel` writes, naming
    // every corridor once, in order. If it is anything else the far side would
    // rebuild a different rule, so the model travels whole instead.
    const expected = features.map((_, index) => `in_looper_avoid_${index}`).join(' || ')
    if (statement.if !== expected) return null
    multiplyBy = statement.multiply_by
    for (const feature of features) {
      let areaId = areaIdentities.get(feature)
      if (areaId === undefined) {
        if (feature.type !== 'Feature' || feature.geometry?.type !== 'Polygon') return null
        areaId = `a${digest(JSON.stringify(feature.geometry))}`
        areaIdentities.set(feature, areaId)
      }
      areaIds.push(areaId)
    }
  }

  return {
    id: `m${digest(`${areaIds.join(',')}|${multiplyBy ?? ''}|${model.distance_influence ?? ''}`)}`,
    areaIds,
    areas: features,
    multiplyBy,
    distanceInfluence: model.distance_influence,
  }
}

/**
 * One generation's worth of corridors, as far as this process knows.
 *
 * The scope tracks what the facade has *acknowledged*, not what has been sent
 * to it. The difference matters and was measured: marking a corridor known the
 * moment a request carrying it is dispatched lets a second call reference it
 * while the first is still in flight, and if the two are processed out of order
 * — which happened to 1.4% of calls — the second is answered `unknown_handle`
 * and has to be asked again. Waiting instead costs nothing but a few duplicate
 * descriptions during a fan-out, because registration is idempotent: two legs
 * that reach a new corridor together both describe it, and the second costs the
 * facade a map lookup.
 *
 * The retry survives anyway, because a scope can also be lost for reasons no
 * bookkeeping predicts — an evicted generation, a restarted facade. It says
 * the model again in full. It never routes under a different one.
 */
export class GenerationScope {
  private readonly areasKnown = new Set<string>()
  private readonly modelsKnown = new Set<string>()
  areaRegistrations = 0
  modelDefinitions = 0
  modelReferences = 0
  rediscoveries = 0

  private constructor(readonly client: GraphHopperClient, readonly id: string) {}

  /**
   * Open a scope, or decide there is nothing to open one against.
   *
   * The shipped GraphHopper container does not know about handles and says so
   * by not advertising the capability; against it this returns undefined and
   * every request carries its model as it always has.
   */
  static async begin(client: GraphHopperClient, signal?: AbortSignal): Promise<GenerationScope | undefined> {
    try {
      const id = await client.beginGeneration(signal)
      return id ? new GenerationScope(client, id) : undefined
    } catch {
      // A facade that cannot open a scope is a facade Looper routes against
      // the old way. It is an optimisation; it is not allowed to be an outage.
      return undefined
    }
  }

  /**
   * What this call should say about its model: a handle, and only the parts of
   * the model the far side has not been told yet.
   */
  handleFor(identity: ModelIdentity, resend = false): ModelHandle {
    const register: Record<string, unknown> = {}
    for (let index = 0; index < identity.areaIds.length; index++) {
      const areaId = identity.areaIds[index]
      if (!resend && this.areasKnown.has(areaId)) continue
      register[areaId] = identity.areas[index]
      this.areaRegistrations++
    }
    this.modelReferences++
    if (!resend && this.modelsKnown.has(identity.id)) return { generation: this.id, id: identity.id }
    this.modelDefinitions++
    return {
      generation: this.id,
      id: identity.id,
      ...(Object.keys(register).length ? { register } : {}),
      define: {
        areas: identity.areaIds,
        ...(identity.multiplyBy === undefined ? {} : { multiply_by: identity.multiplyBy }),
        ...(identity.distanceInfluence === undefined ? {} : { distance_influence: identity.distanceInfluence }),
      },
    }
  }

  /**
   * The facade answered, so it has what that request carried.
   *
   * Called on a rejection as readily as on a route: a 400 "no path" is the
   * facade telling us it registered the corridors and then could not get
   * between two points, which is an ordinary walk-shaped outcome and not a
   * reason to describe the ground again.
   */
  acknowledge(identity: ModelIdentity): void {
    for (const areaId of identity.areaIds) this.areasKnown.add(areaId)
    this.modelsKnown.add(identity.id)
  }

  /** Everything this generation drew, dropped in one call. */
  async end(): Promise<void> {
    try {
      await this.client.endGeneration(this.id)
    } catch {
      // The facade evicts an idle generation on its own, so a failed goodbye
      // costs memory for a few minutes and nothing else. It is not worth
      // failing a walker's request over.
    }
  }
}

export type BoundaryStats = {
  calls: number
  routed: number
  memoHits: number
  memoJoins: number
  handleCalls: number
  areaRegistrations: number
  modelDefinitions: number
  modelReferences: number
  rediscoveries: number
  requestBytes: number
  responseBytes: number
  queueMs: number
  transportMs: number
  parseMs: number
  javaDispatchMs: number
  javaRouteMs: number
  javaSerializeMs: number
}

export type BoundaryOptions = {
  client: GraphHopperClient
  scope?: GenerationScope
  /** Whether an identical request may be answered from the one already asked. */
  memo: boolean
  /** How a call reaches the engine — the shared limiter, in production. */
  run: <T>(call: () => Promise<T>) => Promise<T>
  timeoutMs?: number
  signal?: AbortSignal
}

/**
 * The route function the generator is handed, and the counters behind it.
 *
 * Everything is scoped to one `generateLoops`: the memo is emptied when the
 * request ends, because a walk found for one walker is not an answer to
 * another's, and that is what `loops/cache.ts` is for.
 */
export function createBoundary(options: BoundaryOptions) {
  const memo = new Map<string, { payload: Promise<unknown>; settled: boolean }>()
  const stats: BoundaryStats = {
    calls: 0, routed: 0, memoHits: 0, memoJoins: 0, handleCalls: 0,
    areaRegistrations: 0, modelDefinitions: 0, modelReferences: 0, rediscoveries: 0,
    requestBytes: 0, responseBytes: 0,
    queueMs: 0, transportMs: 0, parseMs: 0,
    javaDispatchMs: 0, javaRouteMs: 0, javaSerializeMs: 0,
  }

  const route = async (points: LngLat[], customModel: CustomModel | undefined, trace?: BoundaryTrace): Promise<GraphHopperLeg> => {
    stats.calls++
    const identity = identify(customModel)
    if (trace && identity) trace.modelId = identity.id

    // A model Looper knows the shape of gets a key from its handle; one it
    // does not gets a key from its whole self. Either way the key names
    // everything that could change the path — the points, in order, and the
    // model — and everything else in the request is fixed for the life of the
    // process by `buildRouteBody`.
    const key = options.memo
      ? `${JSON.stringify(points)}|${identity ? identity.id : customModel ? digest(JSON.stringify(customModel)) : ''}`
      : undefined

    if (key !== undefined) {
      const remembered = memo.get(key)
      if (remembered) {
        // Two identical requests in flight at once wait on one search rather
        // than racing to do it twice; one that has already landed is simply
        // read again. The same mechanism, counted apart because they say
        // different things about the generator: the second is duplication in
        // the algorithm, the first is duplication it has not noticed yet.
        if (remembered.settled) stats.memoHits++
        else stats.memoJoins++
        if (trace) trace.memo = remembered.settled ? 'hit' : 'join'
        // Re-parsing rather than sharing the leg: callers trim and join what
        // they are given, and a shared object would let one candidate's
        // tidying reach another's walk.
        return parseLeg(await remembered.payload)
      }
    }

    const call = async (handle: ModelHandle | undefined) => {
      const result = await options.client.route(points, {
        customModel: handle ? undefined : customModel,
        modelHandle: handle,
        signal: options.signal,
        timeoutMs: options.timeoutMs,
      })
      stats.routed++
      stats.requestBytes += result.requestBytes
      stats.responseBytes += result.responseBytes
      stats.transportMs += result.transportMs
      stats.parseMs += result.parseMs
      stats.javaDispatchMs += result.timing.dispatchMs
      stats.javaRouteMs += result.timing.routeMs
      stats.javaSerializeMs += result.timing.serializeMs
      if (trace) {
        trace.requestBytes = result.requestBytes
        trace.responseBytes = result.responseBytes
        trace.transportMs = round(result.transportMs)
        trace.engineRouteMs = round(result.timing.routeMs)
      }
      return result.payload
    }

    const work = async () => {
      const began = performance.now()
      const acquired = { at: 0 }
      const payload = await options.run(async () => {
        acquired.at = performance.now()
        const scope = options.scope
        const handle = scope && identity ? scope.handleFor(identity) : undefined
        if (handle) stats.handleCalls++
        try {
          const answered = await call(handle)
          if (handle) scope!.acknowledge(identity!)
          return answered
        } catch (error) {
          if (!(error instanceof GraphHopperError)) throw error
          // A refusal is still an answer, and an answer means the facade read
          // the request and kept what it carried. A timeout or a dead socket
          // means no such thing, so those leave the corridors unacknowledged
          // and the next call describes them again.
          const facadeAnswered = error.kind === 'unreachable' || error.kind === 'server'
          if (error.kind !== 'handle') { if (handle && facadeAnswered) scope!.acknowledge(identity!); throw error }
          // It does not have what we thought it had. Say all of it again, once,
          // rather than routing under something else.
          stats.rediscoveries++
          if (trace) trace.rediscovered = true
          const answered = await call(scope!.handleFor(identity!, true))
          scope!.acknowledge(identity!)
          return answered
        }
      })
      if (trace) {
        trace.queueMs = round(acquired.at - began)
        trace.memo = key === undefined ? undefined : 'miss'
      }
      stats.queueMs += acquired.at - began
      return payload
    }

    if (key === undefined) return parseLeg(await work())
    const entry = { payload: work(), settled: false }
    memo.set(key, entry)
    try {
      const payload = await entry.payload
      entry.settled = true
      return parseLeg(payload)
    } catch (error) {
      // A failure is not an answer. Leaving it memoised would turn one
      // transport blip into a candidate that can never be routed.
      if (memo.get(key) === entry) memo.delete(key)
      throw error
    }
  }

  return {
    route,
    stats: (): BoundaryStats => {
      const scope = options.scope
      return {
        ...stats,
        areaRegistrations: scope?.areaRegistrations ?? 0,
        modelDefinitions: scope?.modelDefinitions ?? 0,
        modelReferences: scope?.modelReferences ?? 0,
        queueMs: Math.round(stats.queueMs),
        transportMs: Math.round(stats.transportMs),
        parseMs: Math.round(stats.parseMs),
        javaDispatchMs: Math.round(stats.javaDispatchMs),
        javaRouteMs: Math.round(stats.javaRouteMs),
        javaSerializeMs: Math.round(stats.javaSerializeMs),
      }
    },
    end: async () => { await options.scope?.end() },
  }
}

const round = (value: number) => Math.round(value * 100) / 100
