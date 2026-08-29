import type { LngLat } from './geo.js'
import type { CustomModel } from './avoidance.js'
import { pavementReport } from './edges.js'
import type { GraphHopperLeg } from '../graphhopper.js'
import { appendFileSync } from 'node:fs'

/**
 * What one request actually cost.
 *
 * The generator's own `Diagnostics` answers "what did the walker get". This
 * answers "what did it take to get it": how many times the engine was asked,
 * what for, which candidates died and why, and where the wall clock went.
 * Both are internal — neither carries a coordinate, because a walker's start
 * point is their front door and a metric is not a reason to write it down.
 *
 * Every counter here is additive and order-independent, so a snapshot is the
 * same whatever order asynchronous work happened to finish in. That matters:
 * a benchmark that reports a different number depending on which promise won
 * a race is not a baseline, it is noise.
 */

/**
 * Why a particular engine call was made. Counting calls without this only
 * says the number is high; it never says which fixup is paying for it.
 */
export type RoutePurpose =
  /** The ordinary leg of an incrementally-built loop. */
  | 'leg'
  /** The one retry a leg gets when the strong avoidance penalty left it unroutable. */
  | 'leg-relaxed'
  /** The one retry a leg gets when the avoidance penalty made it absurdly long. */
  | 'leg-budget'
  /** Circling a short dead-end branch found inside a leg's own path. */
  | 'spike'
  /** Redoing two legs around a corner pulled back out of a cul-de-sac. */
  | 'join-pullback'
  /** The unpenalised ordered-waypoint route used as a feasibility floor. */
  | 'waypoint-direct'
  /** A leg of a waypoint candidate. */
  | 'waypoint-leg'
  /** A bounded local repair of a candidate that narrowly failed one gate. */
  | 'repair'
  /** The preliminary reachability probe, when network-aware seeding is on. */
  | 'network-summary'
  /** Cheap first-pass screening of a candidate skeleton. */
  | 'screen'
  /** Not attributed — a caller that did not say. */
  | 'other'

export const ROUTE_PURPOSES: readonly RoutePurpose[] = [
  'leg', 'leg-relaxed', 'leg-budget', 'spike', 'join-pullback',
  'waypoint-direct', 'waypoint-leg', 'repair', 'network-summary', 'screen', 'other',
] as const

/** Why the generator stopped dispatching work. */
export type EarlyStopReason =
  | 'none'
  /** Enough passing candidates had accumulated. */
  | 'passing-quota'
  /** The diversity selector could already fill three offers. */
  | 'diversity-satisfied'
  /** The batch simply ran out of attempts. */
  | 'exhausted'

/** The three speculative retries a leg can pay for, and whether they earned it. */
export type FixupKind = 'join-pullback' | 'leg-budget' | 'spike'

export type FixupTally = { attempted: number; kept: number }

/**
 * How long calls took, grouped by how many avoidance polygons they carried.
 *
 * Every leg after the first sends the ground already walked as custom-model
 * areas, and GraphHopper tests edges against those polygons *during* the
 * search — so the anti-retrace mechanism is not free, and the price is paid on
 * every call rather than once. The engine tops out around ninety foot-legs a
 * second, so if this shows latency climbing with polygon count then the areas
 * are the ceiling, and fewer or simpler ones buy more than any change to how
 * many calls are made.
 */
export const AREA_BUCKETS = ['0', '1-3', '4-7', '8+'] as const
export type AreaBucket = (typeof AREA_BUCKETS)[number]
export type AreaTiming = {
  calls: number
  ms: number
  /** Summed over the calls that reported one; see `MetricsSnapshot.visitedNodes`. */
  visitedNodes: number
  visitedNodeCalls: number
}

export const areaBucketFor = (count: number): AreaBucket =>
  count <= 0 ? '0' : count <= 3 ? '1-3' : count <= 7 ? '4-7' : '8+'

export type MetricsSnapshot = {
  graphhopperCalls: number
  callsByPurpose: Record<RoutePurpose, number>
  /**
   * Path searches asked for, which is not the same as HTTP calls: one
   * multi-point request is one call and several searches. Combining points
   * into one request saves round trips, not the engine's own work.
   */
  routedLegs: number
  /** Wall time inside engine calls, summed across concurrent callers. */
  engineMs: number
  /**
   * Nodes the engine settled, summed over the calls that reported a count.
   *
   * Milliseconds measure how long we waited; this measures how much of the
   * graph was searched, and only the second one can tell a slow engine from a
   * search doing far more work than it should. Divided by `visitedNodeCalls`
   * it is the per-leg search size, which is what says whether the landmark
   * heuristic is doing anything under a per-request custom model — the
   * question the whole avoidance design rests on and which nothing has ever
   * measured. Zero calls reporting means the build does not offer the hint.
   */
  visitedNodes: number
  visitedNodeCalls: number
  /**
   * How often the legs the engine returned changed between a dedicated
   * pedestrian way and a carriageway, per kilometre measured.
   *
   * Where OSM maps a pavement separately, a pavement and its own carriageway
   * weigh almost the same, so the router takes whichever is a few metres
   * shorter and the line crosses the road repeatedly. That is confusing to
   * look at and gives a spoken turn each time. Reported and never read by the
   * algorithm — it exists so the profile can be tuned against a number rather
   * than against screenshots.
   */
  pavementHops: number
  pavementHopMetres: number
  pavementHopsPerKm: number
  candidatesBuilt: number
  candidatesRouted: number
  candidatesPassed: number
  candidatesRejected: number
  rejectionReasons: Record<string, number>
  repairsAttempted: number
  repairsSucceeded: number
  repairBudgetExhausted: number
  discoveryBatches: number
  reaims: number
  earlyStop: EarlyStopReason
  fallbackRetracing: boolean
  cacheHits: number
  cacheMisses: number
  /**
   * How many candidates were measured on the network and how many fell back
   * to geometry. Until the second number is reliably zero in production, the
   * geometric path is not dead code.
   */
  overlapFromEdges: number
  overlapFromGeometry: number
  /**
   * Each fix-up reroutes speculatively and keeps the result only if it turned
   * out better. `attempted` minus `kept` is work the engine did for nothing —
   * the number that says whether a fix-up is worth what it costs.
   */
  fixups: Record<FixupKind, FixupTally>
  /** See AREA_BUCKETS. Engine time against avoidance-polygon count. */
  engineMsByAreas: Record<AreaBucket, AreaTiming>
  /** Populated once the offered set is known. */
  offered: OfferedMetrics | undefined
  totalMs: number
  candidateMs: { median: number; p95: number; max: number }
}

export type OfferedMetrics = {
  count: number
  medianDistanceErrorPercent: number
  maxDistanceErrorPercent: number
  medianRepeatedPercent: number
  maxRepeatedPercent: number
  totalUTurns: number
  /** The worst overlap between any two offered routes, measured geometrically. */
  maxPairSharedPercent: number
  /**
   * The same, measured on the network. Reported alongside rather than instead:
   * the two disagreeing is the interesting signal, and one number that
   * silently changes meaning with a flag is not a benchmark.
   */
  maxPairSharedEdgePercent: number | undefined
}

export class RequestMetrics {
  private readonly counts = new Map<RoutePurpose, number>()
  private readonly rejections = new Map<string, number>()
  private readonly candidateDurations: number[] = []
  private routedLegs = 0
  private engineMs = 0
  private visitedNodes = 0
  /** Calls that reported one, which is not every call — see `visitedNodes`. */
  private visitedNodeCalls = 0
  private pavementHops = 0
  private pavementHopMetres = 0
  private candidatesBuilt = 0
  private candidatesRouted = 0
  private candidatesPassed = 0
  private repairsAttempted = 0
  private repairsSucceeded = 0
  private repairBudgetExhausted = 0
  private discoveryBatches = 0
  private reaims = 0
  private cacheHits = 0
  private cacheMisses = 0
  private overlapFromEdges = 0
  private overlapFromGeometry = 0
  private readonly fixups = new Map<FixupKind, FixupTally>()
  private readonly areaTimings = new Map<AreaBucket, AreaTiming>()
  private earlyStop: EarlyStopReason = 'none'
  private fallbackRetracing = false
  private offered: OfferedMetrics | undefined
  private readonly startedAt: number

  constructor(private readonly now: () => number = () => Date.now()) {
    this.startedAt = now()
  }

  countCall(purpose: RoutePurpose, elapsedMs = 0, routedLegs = 1, avoidanceAreas = 0, visitedNodes?: number, pavement?: { hops: number; measuredMetres: number }) {
    this.counts.set(purpose, (this.counts.get(purpose) ?? 0) + 1)
    this.routedLegs += routedLegs
    this.engineMs += elapsedMs
    if (pavement) {
      this.pavementHops += pavement.hops
      this.pavementHopMetres += pavement.measuredMetres
    }
    if (visitedNodes !== undefined) {
      this.visitedNodes += visitedNodes
      this.visitedNodeCalls++
    }
    const bucket = areaBucketFor(avoidanceAreas)
    const timing = this.areaTimings.get(bucket) ?? { calls: 0, ms: 0, visitedNodes: 0, visitedNodeCalls: 0 }
    timing.calls++
    timing.ms += elapsedMs
    if (visitedNodes !== undefined) {
      timing.visitedNodes += visitedNodes
      timing.visitedNodeCalls++
    }
    this.areaTimings.set(bucket, timing)
  }

  countCandidateBuilt() { this.candidatesBuilt++ }
  countCandidateRouted() { this.candidatesRouted++ }
  countCandidatePassed() { this.candidatesPassed++ }
  countRejection(reason: string) { this.rejections.set(reason, (this.rejections.get(reason) ?? 0) + 1) }
  countRepairAttempt() { this.repairsAttempted++ }
  countRepairSuccess() { this.repairsSucceeded++ }
  countRepairBudgetExhausted() { this.repairBudgetExhausted++ }
  countDiscoveryBatch() { this.discoveryBatches++ }
  countReaim() { this.reaims++ }
  countCacheHit() { this.cacheHits++ }
  countCacheMiss() { this.cacheMisses++ }
  countFixup(kind: FixupKind, kept: boolean) {
    const tally = this.fixups.get(kind) ?? { attempted: 0, kept: 0 }
    tally.attempted++
    if (kept) tally.kept++
    this.fixups.set(kind, tally)
  }

  countOverlapSource(source: 'edges' | 'geometry') {
    if (source === 'edges') this.overlapFromEdges++
    else this.overlapFromGeometry++
  }
  recordCandidateMs(ms: number) { this.candidateDurations.push(ms) }
  recordEarlyStop(reason: EarlyStopReason) { this.earlyStop = reason }
  recordFallbackRetracing(used: boolean) { this.fallbackRetracing = used }
  recordOffered(offered: OfferedMetrics) { this.offered = offered }

  /** Times one candidate without the caller having to hold a stopwatch. */
  async timeCandidate<T>(work: () => Promise<T>): Promise<T> {
    const began = this.now()
    try {
      return await work()
    } finally {
      this.recordCandidateMs(this.now() - began)
    }
  }

  snapshot(): MetricsSnapshot {
    const callsByPurpose = {} as Record<RoutePurpose, number>
    let graphhopperCalls = 0
    for (const purpose of ROUTE_PURPOSES) {
      const count = this.counts.get(purpose) ?? 0
      callsByPurpose[purpose] = count
      graphhopperCalls += count
    }
    const rejectionReasons: Record<string, number> = {}
    for (const reason of [...this.rejections.keys()].sort()) rejectionReasons[reason] = this.rejections.get(reason)!
    const rejected = [...this.rejections.values()].reduce((sum, count) => sum + count, 0)

    return {
      graphhopperCalls,
      callsByPurpose,
      routedLegs: this.routedLegs,
      engineMs: Math.round(this.engineMs),
      pavementHops: this.pavementHops,
      pavementHopMetres: this.pavementHopMetres,
      pavementHopsPerKm: this.pavementHopMetres > 0 ? (this.pavementHops * 1000) / this.pavementHopMetres : 0,
      visitedNodes: this.visitedNodes,
      visitedNodeCalls: this.visitedNodeCalls,
      candidatesBuilt: this.candidatesBuilt,
      candidatesRouted: this.candidatesRouted,
      candidatesPassed: this.candidatesPassed,
      candidatesRejected: rejected,
      rejectionReasons,
      repairsAttempted: this.repairsAttempted,
      repairsSucceeded: this.repairsSucceeded,
      repairBudgetExhausted: this.repairBudgetExhausted,
      discoveryBatches: this.discoveryBatches,
      reaims: this.reaims,
      earlyStop: this.earlyStop,
      fallbackRetracing: this.fallbackRetracing,
      cacheHits: this.cacheHits,
      cacheMisses: this.cacheMisses,
      overlapFromEdges: this.overlapFromEdges,
      overlapFromGeometry: this.overlapFromGeometry,
      fixups: {
        'join-pullback': this.fixups.get('join-pullback') ?? { attempted: 0, kept: 0 },
        'leg-budget': this.fixups.get('leg-budget') ?? { attempted: 0, kept: 0 },
        spike: this.fixups.get('spike') ?? { attempted: 0, kept: 0 },
      },
      engineMsByAreas: Object.fromEntries(AREA_BUCKETS.map(bucket => {
        const timing = this.areaTimings.get(bucket) ?? { calls: 0, ms: 0, visitedNodes: 0, visitedNodeCalls: 0 }
        return [bucket, {
          calls: timing.calls,
          ms: Math.round(timing.ms),
          visitedNodes: timing.visitedNodes,
          visitedNodeCalls: timing.visitedNodeCalls,
        }]
      })) as Record<AreaBucket, AreaTiming>,
      offered: this.offered,
      totalMs: Math.round(this.now() - this.startedAt),
      candidateMs: percentiles(this.candidateDurations),
    }
  }
}

/**
 * Wrap a router so every call it makes is counted against a purpose. The
 * wrapper is transparent: same arguments, same result, same thrown errors —
 * a failed call still cost the engine the work, so it is still counted.
 */
/**
 * A JSONL record of every engine call, written only when `LOOPER_TRACE_FILE`
 * names a file.
 *
 * The counters above say what a request cost in aggregate. This says what each
 * individual call was: which class of custom model it carried, how big the
 * corridor set was, what it cost and how much graph it settled. It exists so
 * that engine experiments can be replayed against the real workload rather
 * than against fixtures chosen by hand, and it is off unless asked for —
 * appending a line per call is cheap, but "cheap" is not "free" and production
 * is not a benchmark.
 */
const TRACE_FILE = process.env.LOOPER_TRACE_FILE
/**
 * Whether each traced call also carries the points and custom model it was
 * made with, so the corpus can be replayed against a bare engine. Separate
 * from the trace itself because the corridors dominate the file size — a
 * twelve-area model is tens of kilobytes — and most questions do not need it.
 */
const TRACE_BODIES = process.env.LOOPER_TRACE_BODIES === '1'

/**
 * Which weighting a call actually asked for, from the model itself rather than
 * from the caller's intent. `purpose` says which fixup is paying; this says
 * what the engine was handed, which is what its search behaviour depends on.
 */
export type RequestClass = 'plain' | 'avoid-strong' | 'avoid-relaxed' | 'avoid-other' | 'lower-bound' | 'mixed'

export function classifyRequest(model: CustomModel | undefined): RequestClass {
  if (!model) return 'plain'
  const multiplier = model.priority?.[0]?.multiply_by
  const hasDistanceInfluence = model.distance_influence !== undefined
  if (multiplier === undefined) return hasDistanceInfluence ? 'lower-bound' : 'plain'
  if (hasDistanceInfluence) return 'mixed'
  const value = Number(multiplier)
  if (value === 0.05) return 'avoid-strong'
  if (value === 0.2) return 'avoid-relaxed'
  return 'avoid-other'
}

function trace(record: Record<string, unknown>) {
  if (!TRACE_FILE) return
  try {
    appendFileSync(TRACE_FILE, JSON.stringify(record) + '\n')
  } catch {
    // A benchmark's notebook is not allowed to break the thing it is watching.
  }
}

const COUNTED_BY = Symbol('looper.countedBy')
type Counted = { [COUNTED_BY]?: RequestMetrics }

export function countingRouter(
  route: (points: LngLat[], customModel: CustomModel | undefined, purpose?: RoutePurpose) => Promise<GraphHopperLeg>,
  metrics: RequestMetrics | undefined,
  now: () => number = () => Date.now(),
) {
  if (!metrics) return route
  // Waypoint mode generates ordinary loops by calling back into the generator
  // with the same options. Wrapping twice would count every call twice, which
  // is worse than not counting at all: a wrong number reads as a real one.
  if ((route as Counted)[COUNTED_BY] === metrics) return route
  const counted = async (points: LngLat[], customModel: CustomModel | undefined, purpose: RoutePurpose = 'other') => {
    const began = now()
    let visitedNodes: number | undefined
    let pavement: { hops: number; measuredMetres: number } | undefined
    try {
      const leg = await route(points, customModel, purpose)
      visitedNodes = leg.visitedNodes
      pavement = pavementReport(leg.coordinates, leg.roadClasses)
      return leg
    } finally {
      // A call that threw is still a call, and still cost the engine time. It
      // simply has no node count to report, which is what `undefined` says.
      const elapsed = now() - began
      metrics.countCall(purpose, elapsed, Math.max(1, points.length - 1), customModel?.areas?.features?.length ?? 0, visitedNodes, pavement)
      trace({
        purpose,
        class: classifyRequest(customModel),
        points: points.length,
        areas: customModel?.areas?.features?.length ?? 0,
        areaVertices: customModel?.areas?.features?.reduce((sum, f) => sum + (f.geometry.coordinates[0]?.length ?? 0), 0) ?? 0,
        ms: elapsed,
        visitedNodes,
        ...(TRACE_BODIES ? { points, model: customModel ?? null } : {}),
      })
    }
  }
  Object.defineProperty(counted, COUNTED_BY, { value: metrics, enumerable: false })
  return counted
}

export function percentiles(values: number[]): { median: number; p95: number; max: number } {
  if (!values.length) return { median: 0, p95: 0, max: 0 }
  const sorted = [...values].sort((a, b) => a - b)
  return {
    median: Math.round(quantile(sorted, 0.5)),
    p95: Math.round(quantile(sorted, 0.95)),
    max: Math.round(sorted[sorted.length - 1]),
  }
}

/** Nearest-rank, so a small sample never invents a value between two measurements. */
export function quantile(sorted: number[], fraction: number): number {
  if (!sorted.length) return 0
  const rank = Math.ceil(fraction * sorted.length)
  return sorted[Math.min(sorted.length - 1, Math.max(0, rank - 1))]
}
