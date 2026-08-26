import type { LngLat } from './geo.js'
import type { CustomModel } from './avoidance.js'
import type { GraphHopperLeg } from '../graphhopper.js'

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
export type AreaTiming = { calls: number; ms: number }

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

  countCall(purpose: RoutePurpose, elapsedMs = 0, routedLegs = 1, avoidanceAreas = 0) {
    this.counts.set(purpose, (this.counts.get(purpose) ?? 0) + 1)
    this.routedLegs += routedLegs
    this.engineMs += elapsedMs
    const bucket = areaBucketFor(avoidanceAreas)
    const timing = this.areaTimings.get(bucket) ?? { calls: 0, ms: 0 }
    timing.calls++
    timing.ms += elapsedMs
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
        const timing = this.areaTimings.get(bucket) ?? { calls: 0, ms: 0 }
        return [bucket, { calls: timing.calls, ms: Math.round(timing.ms) }]
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
    try {
      return await route(points, customModel, purpose)
    } finally {
      metrics.countCall(purpose, now() - began, Math.max(1, points.length - 1), customModel?.areas?.features?.length ?? 0)
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
