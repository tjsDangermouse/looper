import { randomUUID } from 'node:crypto'
import type { LineString } from 'geojson'
import { GraphHopperError } from '../graphhopper.js'
import { DEFAULT_ATTEMPT_COUNT, generateLoopAttempts, spreadAcrossCompass, type LoopAttempt } from './candidates.js'
import { MAX_SHARED_FRACTION, bearingOctant, initialBearing as bearingOf, labelRoutes, selectDiverseRoutes, selectPreferredDiverseRoutes } from './diversity.js'
import { destination, distanceBetween, haversine, projector, type LngLat, type Metric } from './geo.js'
import { MAX_REPEATED_FRACTION, analyseRouteQuality, sharedCorridorMetres, type QualityReport, type QualityThresholds } from './quality.js'
import { LEG_BUDGET_SHARE, buildLoopIncrementally, joinAndTrimLegs, routeLegAttempt, type LegRouter, type RoutedCandidate, type RoutedLeg, type SequentialRoutingOptions } from './routing.js'
import { avoidanceCustomModel, shortestPathCustomModel } from './avoidance.js'
import { seedFor } from './random.js'
import { countingRouter, RequestMetrics, type MetricsSnapshot, type OfferedMetrics, type RoutePurpose } from './metrics.js'
import { measureTraversals, sharedEdgeMetres, type EdgeTraversal } from './edges.js'
import { withFlags, type AlgorithmFlags } from './flags.js'
import { paretoArchive, type Objectives } from './pareto.js'
import { DEFAULT_REPAIR_BUDGET, RepairBudget, RepairBudgetExhausted, repairPlanFor, type RepairBudgetLimits, type RepairPlan } from './repair.js'
import { longestRepeatedSection } from './edges.js'
import { findRepeatedCorridors, MIN_SHARED_RUN_METRES } from './quality.js'
import { normaliseBearing } from './geo.js'
import { biasAttemptsToNetwork, summariseNetwork, type NetworkSummary, type ReachedPoint } from './network.js'
import { allocateSlack, DEFAULT_ALLOCATION, fitsInPlan, planSegmentOptions, type SegmentOption } from './waypoints.js'
import { pickForRefinement, screenSkeleton, type ScreenVerdict } from './screening.js'
import { destination as pointAtBearing } from './geo.js'
import { targetMetresFor, targetSecondsFor, type LoopMode } from './units.js'

/**
 * The loop generator, end to end.
 *
 * Each attempt builds its own loop live — a leg at a time, self-correcting as
 * it goes against the distance budget — rather than guessing a whole shape
 * blind and finding out after the fact whether it worked. A finished loop is
 * still measured and either offered or thrown away. Nothing is offered to
 * fill a gap: three good loops, or two, or one, or an honest nothing.
 *
 * The shape itself is not fixed either. Some ground wants two turns — a
 * promenade, out one way and back another — and some wants four, threading a
 * housing estate. An attempt tries the simplest shape first and only reaches
 * for another corner if that one could not be made to work, rather than every
 * walk being forced into the same stencil regardless of what is underneath it.
 */
/**
 * Corner counts an attempt tries, and the order it tries them in.
 *
 * The loop stops at the first shape that passes, so the order is the cost: a
 * three-cornered ring is what most ground wants, and starting there rather
 * than at a two-legged there-and-back saves trying two shapes that were never
 * going to be the answer. Measured on the fixtures, that reordering alone is
 * 6% of all engine calls for no change to what is offered.
 *
 * The tail is what a bearing pays when *nothing* works — one and four are
 * still there because a promenade genuinely wants two legs and a housing
 * estate genuinely wants five, and dropping them costs a walk.
 */
const CORNER_COUNTS_TO_TRY = [3, 2, 1, 4]
/**
 * The narrow sweep: only the two shapes that answer most of the time.
 *
 * A quarter of all engine calls, measured, and it costs a walk in twenty and
 * some separation between the walks that remain. Whether that is a good trade
 * depends on the ground, so it is a flag rather than a decision.
 */
const NARROW_CORNER_COUNTS = [3, 2]
/** Fresh candidate batches tried before we honestly return fewer than three loops. */
const MAX_DISCOVERY_BATCHES = 3
/**
 * Once a batch has this many passing candidates, the remaining unstarted
 * attempts are skipped — a buffer above the three actually offered, since
 * diversity filtering can still discard some of them. Attempts already
 * dispatched (up to `concurrency` of them) finish anyway rather than being
 * cancelled mid-flight, which keeps this change from touching the routing
 * layer's own cancellation semantics.
 */
const EARLY_STOP_PASSING_COUNT = 5
/**
 * How many passing candidates beyond the three offered must exist before
 * diversity-aware stopping will stop. Three that the selector can just about
 * separate is a set with no room in it: one of them being edged out by the
 * exclusion filter, or by a better candidate arriving, leaves the walker with
 * two. One spare is enough to absorb that without paying for a whole batch.
 */
const EARLY_STOP_RESERVE = 1

export const NO_CLEAN_LOOP_WARNING =
  'We couldn’t find a clean loop of that length from here. Try a different distance or move the start point.'

/**
 * Shown when the only walks of the right length double back on themselves.
 * Some places have no circuit at all at a given distance — one road up a
 * valley, a headland, a village of cul-de-sacs — and a walk that returns the
 * way it came is a better answer than no walk, as long as nobody is misled
 * about what they are getting.
 */
export const RETRACES_WARNING =
  'There’s no clean loop of that length from here, so these walks retrace part of the way back.'

export type LoopRequest = {
  start: { lng: number; lat: number }
  mode: LoopMode
  distanceKm?: number
  durationMinutes?: number
  units: 'km' | 'mi'
  /** Activity selected by newer clients. Both currently use foot-accessible paths. */
  activity?: 'walking' | 'running'
  /** Personal average pace, normalised during request validation. */
  walkingPaceMinutesPerKm?: number
  variation?: number
  /** Loops already shown to the walker, excluded from a refresh. */
  exclude?: LngLat[][]
  /** Places the walker explicitly asked every offered loop to visit, in order. */
  waypoints?: Array<{ lng: number; lat: number }>
  overrides?: LoopOverrides
}

/**
 * Every quality, diversity and routing knob this generator tunes with,
 * gathered so the tuning panel can send whichever ones a walker is
 * experimenting with. Absent fields keep today's defaults. Never sent by
 * the ordinary "Find my loops" flow.
 */
export type LoopOverrides = {
  quality?: Partial<QualityThresholds>
  /** See MAX_SHARED_FRACTION in diversity.ts. */
  maxSharedFraction?: number
  /** See JOIN_TURN_THRESHOLD_DEGREES in routing.ts. */
  joinTurnThresholdDegrees?: number
  /** See WAYPOINT_PULLBACK_SCALE in routing.ts. */
  waypointPullbackScale?: number
  candidateCount?: number
}

export type LoopStep = {
  instruction: string
  distanceMeters: number
  durationSeconds: number
  maneuver?: string
  /** Extras the walk screen uses; harmless to ignore. */
  road?: string
  roadClass?: string
  startIndex?: number
  endIndex?: number
}

export type LoopRoute = {
  id: string
  label: string
  distanceMeters: number
  durationSeconds: number
  targetDifferencePercent: number
  geometry: LineString
  steps: LoopStep[]
  quality: {
    score: number
    repeatedMeters: number
    repeatedPercent: number
    uTurnCount: number
    compactness: number
  }
}

export type LoopResponse = { routes: LoopRoute[]; warning?: string; expectationExceeded?: boolean; diagnostics?: Diagnostics }

export type GenerateOptions = {
  route: LegRouter
  candidateCount?: number
  concurrency?: number
  signal?: AbortSignal
  /** Reported back to the caller for logging; never sent to a browser. */
  onDiagnostics?: (diagnostics: Diagnostics) => void
  /**
   * Where this request's cost is recorded. Supplied by the server and by the
   * benchmark harness; absent in unit tests that only care about the answer.
   */
  metrics?: RequestMetrics
  /** See DEFAULT_REPAIR_BUDGET. What all of one request's repairs may spend. */
  repairBudget?: Partial<RepairBudgetLimits>
  /**
   * How far the network reaches from a point, if the engine can say. Used to
   * aim candidates before any of them are dispatched. Returning undefined —
   * because the endpoint is absent, slow, or unreachable — is an ordinary
   * outcome and puts the generator back on the bearings it would have used.
   */
  reachFrom?: (start: LngLat, distanceLimitMetres: number) => Promise<ReachedPoint[] | undefined>
  /**
   * Which algorithm changes are switched on. Absent means today's behaviour,
   * so a test that does not mention a flag is testing the algorithm that is
   * actually in production.
   */
  flags?: Partial<AlgorithmFlags>
}

export type Diagnostics = {
  candidates: number
  routed: number
  passed: number
  offered: number
  rejections: Record<string, number>
  /** Which of the two allowed single retries was used, if any. */
  retry: Retry
  /** True when nothing clean existed and the walks offered double back. */
  retracing: boolean
  targetMetres: number
  /**
   * Where a waypoint request ended up, which is otherwise invisible: waypoint
   * mode has several ways of giving up and they all reach the walker as the
   * same sentence. Absent for ordinary loops, which only have one path.
   */
  stage?: WaypointStage
  /**
   * Where the backbone generator got to before handing over, when it did.
   * Without this the older generator's own outcome overwrites it and the
   * interesting failure — the one in the newer code — becomes invisible.
   */
  backboneStage?: WaypointStage
  /** Which gates killed the walks the backbone generator assembled. */
  backboneRejections?: Record<string, number>
  /**
   * How many of the walks it assembled had a plan that encloses any ground.
   * If this is zero the shape preference had nothing to prefer, and the
   * problem is where the shaping points are put rather than which are chosen.
   */
  backboneShapes?: { assembled: number; enclosing: number; best: number }
  /** What the request cost. Internal; the API contract allows extra fields. */
  metrics?: MetricsSnapshot
}

/**
 * The backbone generator declining to answer, and why. Deliberately not
 * `undefined`: a hand-over carries the reason, and the reason is the whole
 * point of having built the thing that gave up.
 */
type HandedOver = {
  handedOver: true
  stage: WaypointStage
  rejections: Record<string, number>
  shapes?: Diagnostics['backboneShapes']
}

const handOver = (
  stage: WaypointStage,
  rejections: Record<string, number>,
  shapes?: Diagnostics['backboneShapes'],
): HandedOver => ({ handedOver: true, stage, rejections: { ...rejections }, ...(shapes ? { shapes } : {}) })

const isHandedOver = (result: LoopResponse | HandedOver): result is HandedOver =>
  (result as HandedOver).handedOver === true

/** Every way a waypoint request can finish, named so a log line can say which. */
export type WaypointStage =
  /** An anchor the engine could not reach on foot at all. */
  | 'unreachable'
  /** The shortest ordered walk through the pins is longer than the plan allows. */
  | 'over-plan'
  /** The pins barely constrain anything; handed to the ordinary loop generator. */
  | 'doorstep-pin'
  /** The slack could not be spent to reach anything near the requested length. */
  | 'no-allocation'
  /** Walks were assembled and every one of them failed a quality gate. */
  | 'all-rejected'
  /** Built from the backbone, as intended. */
  | 'backbone'
  /** Ordinary loops that already passed the pins were reused. */
  | 'reused-natural'
  /** The older shaped-guide generator answered. */
  | 'legacy-guides'
  /** The older generator found nothing either. */
  | 'legacy-empty'

export type Retry = 'none' | 'duration' | 'radius' 

type Analysed = {
  candidate: RoutedCandidate
  report: QualityReport
  coordinates: LngLat[]
  quality: QualityReport['quality']
  bearing: number
  /** Present only when edge overlap is on and the engine reported edge ids. */
  traversals?: EdgeTraversal[]
  /** The shape this candidate was built with, so a repair can vary it. */
  cornerCount: number
  /** Set when this candidate is the result of a repair, for metrics and tests. */
  repairedBy?: RepairPlan['strategy']
}

/**
 * How many non-dominated candidates the archive keeps.
 *
 * Large enough that the diversity selector still has real choice — three
 * offers out of an archive of three is not a selection — and small enough that
 * the archive is doing something. Where it under-delivers, the selector falls
 * back to the whole pool rather than offering less.
 */
const PARETO_ARCHIVE_LIMIT = 12

/**
 * How far out the reachability probe walks, as a share of the target.
 *
 * Far enough to see whether a direction has a loop's worth of network in it,
 * and no further: the cost of a shortest-path tree grows with the area it
 * covers, and this has to stay cheaper than the candidates it saves.
 */
const NETWORK_PROBE_SHARE = 0.3

export async function generateLoops(request: LoopRequest, options: GenerateOptions): Promise<LoopResponse> {
  // Counting happens once per request, however deep the generator recurses:
  // waypoint mode asks for ordinary loops with these same options.
  const metrics = options.metrics
  const flags = withFlags(options.flags)
  options = { ...options, route: countingRouter(options.route, metrics), flags }
  const start: LngLat = [request.start.lng, request.start.lat]
  const variation = request.variation ?? 0
  const targetSeconds = targetSecondsFor(request)
  const firstTarget = targetMetresFor(request)
  const overrides = request.overrides
  const candidateCount = overrides?.candidateCount ?? options.candidateCount ?? DEFAULT_ATTEMPT_COUNT

  if (request.waypoints?.length) {
    return generateWaypointLoops(request, options, start, firstTarget, targetSeconds)
  }

  // One probe for the whole request, before any candidate is dispatched. It
  // costs one engine call and can save a batch of four-leg candidates aimed
  // into the sea. Its failure is not an error: `summary` simply stays absent.
  let summary: NetworkSummary | undefined
  if (flags.networkAwareSeeds && options.reachFrom) {
    const began = Date.now()
    const reached = await options.reachFrom(start, firstTarget * NETWORK_PROBE_SHARE)
    metrics?.countCall('network-summary', Date.now() - began)
    if (reached?.length) summary = summariseNetwork(start, reached)
  }

  const rejections: Record<string, number> = {}
  // One purse for the whole request, so a hard start point cannot spend a
  // repair budget per batch and quietly cost several times what it looks like.
  const repairs = new RepairBudget({ ...DEFAULT_REPAIR_BUDGET, ...options.repairBudget })
  const first = await attempt(firstTarget, firstTarget, variation)

  let passing = first.passing
  let extra: Analysed[] = []
  let retry: Retry = 'none'
  let targetMetres = firstTarget
  let candidateBatches = 1

  // Each attempt already self-corrects against the budget as it builds, so
  // this retry is now a last resort rather than the main way a candidate ever
  // lands near the right size: only reached when every attempt in the first
  // batch still missed, in which case the network stretches a crow-flies
  // target enough that even self-correction inside one loop cannot cover it,
  // and the whole batch is re-aimed once.
  if (passing.length < 3) {
    const durationMisses = targetSeconds ? first.analysed.filter(entry => entry.report.durationOnly) : []

    if (request.mode === 'time' && targetSeconds && durationMisses.length) {
      // Clean loops that took the wrong amount of time: the 5 km/h estimate was
      // wrong for this terrain, so re-aim the distance from what was measured.
      const observed = median(durationMisses.map(entry => durationFor(entry.candidate)))
      targetMetres = firstTarget * clampScale(targetSeconds / observed)
      const second = await attempt(targetMetres, targetMetres, variation)
      candidateBatches++
      metrics?.countReaim()
      retry = 'duration'
      extra = second.analysed
      passing = merge(passing, second.passing)
    } else if (first.analysed.length) {
      // The construction target was the wrong size for these streets: measure
      // what actually came back and resize once. A batch that is badly sized
      // fails in several ways at once, not only on length, so the estimate
      // comes from every candidate that routed rather than the near misses.
      // The target a walk is judged against never moves — that is what the
      // walker asked for.
      const observed = median(first.analysed.map(entry => entry.candidate.distanceMeters))
      const scale = clampScale(firstTarget / observed)
      if (Math.abs(scale - 1) > 0.05) {
        const second = await attempt(firstTarget * scale, firstTarget, variation)
        candidateBatches++
        metrics?.countReaim()
        retry = 'radius'
        extra = second.analysed
        passing = merge(passing, second.passing)
      }
    }
  }

  // Clean loops first. Only if there are none at all does Looper fall back to
  // walks of the right length that double back — never as a top-up alongside a
  // clean loop, which would quietly mix two different kinds of answer.
  let analysed = merge(first.analysed, extra)
  const choose = () => {
    const retracing = passing.length === 0
    const offerable = retracing ? analysed.filter(entry => entry.report.passesEssentials) : passing
    const maxShared = overrides?.maxSharedFraction ?? MAX_SHARED_FRACTION
    const fresh = request.exclude?.length
      ? offerable.filter(entry => request.exclude!.every(previous => sharedCorridorMetres(entry.coordinates, previous).fraction <= maxShared))
      : offerable
    if (!flags.paretoArchive) return selectDiverseRoutes(fresh.map(toSelectable), 3, maxShared)

    // The front keeps whatever is best at something, including the things the
    // weighted score would have traded away. The score then ranks what is
    // left, exactly as before — this decides what it gets to rank, not how.
    //
    // Taken per compass octant, not over the whole batch. Which way a walk
    // sets off is not one of the things being traded: a loop heading north can
    // be beaten on every count here by one heading east and still be the only
    // northern walk in the batch, and a front computed across the lot would
    // drop it before the selector ever saw it.
    const byOctant = new Map<number, Analysed[]>()
    for (const entry of fresh) {
      const octant = bearingOctant(entry.bearing)
      const group = byOctant.get(octant)
      if (group) group.push(entry)
      else byOctant.set(octant, [entry])
    }
    const archive = [...byOctant.keys()].sort((a, b) => a - b).flatMap(octant => paretoArchive(byOctant.get(octant)!, {
      limit: PARETO_ARCHIVE_LIMIT,
      objectives: objectivesOf,
      rank: entry => entry.quality.score,
    }))
    const fromArchive = selectDiverseRoutes(archive.map(toSelectable), 3, maxShared)
    if (fromArchive.length >= 3 || archive.length === fresh.length) return fromArchive
    // Three good walks beat a tidy filter. Where narrowing to the front costs
    // the walker a choice, the front is the thing that gives way.
    const fromEverything = selectDiverseRoutes(fresh.map(toSelectable), 3, maxShared)
    return fromEverything.length > fromArchive.length ? fromEverything : fromArchive
  }
  let chosen = choose()

  // One heuristic batch can miss perfectly good loops on a dense or uneven
  // network. Keep sampling fresh bearings until the walker has three distinct
  // choices, rather than making them press refresh to discover them.
  for (let batch = 1; chosen.length < 3 && batch < MAX_DISCOVERY_BATCHES; batch++) {
    const next = await attempt(targetMetres, targetMetres, variation + batch)
    candidateBatches++
    metrics?.countDiscoveryBatch()
    analysed = merge(analysed, next.analysed)
    passing = merge(passing, next.passing)
    chosen = choose()
  }

  const retracing = passing.length === 0
  const labels = labelRoutes(chosen.map(entry => ({ bearing: entry.bearing, distanceMeters: entry.source.candidate.distanceMeters })))

  const diagnostics: Diagnostics = {
    candidates: candidateCount * candidateBatches,
    routed: analysed.length,
    passed: passing.length,
    offered: chosen.length,
    rejections,
    retry,
    targetMetres,
    retracing: retracing && chosen.length > 0,
  }
  if (metrics) {
    metrics.recordFallbackRetracing(retracing && chosen.length > 0)
    metrics.recordOffered(measureOffered(chosen.map(entry => ({
      coordinates: entry.source.coordinates,
      distanceMeters: entry.source.candidate.distanceMeters,
      quality: entry.source.quality,
      traversals: entry.source.traversals,
    })), targetMetres))
    diagnostics.metrics = metrics.snapshot()
  }
  options.onDiagnostics?.(diagnostics)

  if (!chosen.length) return { routes: [], warning: NO_CLEAN_LOOP_WARNING, diagnostics }

  return {
    warning: retracing ? RETRACES_WARNING : undefined,
    diagnostics,
    routes: chosen.map((entry, position) => {
      const { candidate, quality } = entry.source
      const durationSeconds = durationFor(candidate)
      return {
        id: randomUUID(),
        label: labels[position],
        distanceMeters: Math.round(candidate.distanceMeters),
        durationSeconds: Math.round(durationSeconds),
        targetDifferencePercent: Math.round((candidate.distanceMeters / targetMetres - 1) * 100),
        geometry: { type: 'LineString', coordinates: candidate.coordinates } as LineString,
        steps: candidate.steps.map(step => ({
          instruction: step.instruction,
          distanceMeters: Math.round(step.distanceMeters),
          durationSeconds: Math.round(candidate.distanceMeters > 0 ? step.distanceMeters / candidate.distanceMeters * durationSeconds : step.durationSeconds),
          maneuver: step.maneuver,
          road: step.road,
          roadClass: step.roadClass,
          startIndex: step.startIndex,
          endIndex: step.endIndex,
        })),
        quality,
      }
    }),
  }

  /**
   * `constructionTarget` is what each attempt builds toward; `qualityTarget`
   * is what the finished loop is judged against. They differ only on the
   * rare radius retry below, where the build is re-aimed but the walker's
   * actual request is not.
   */
  async function attempt(constructionTarget: number, qualityTarget: number, candidateVariation: number): Promise<{ analysed: Analysed[]; passing: Analysed[] }> {
    const seed = seedFor([start[0], start[1]], qualityTarget, candidateVariation)
    const ordered = generateLoopAttempts(seed, candidateCount)
    // Stopping partway is only fair if what has been tried so far is spread
    // round the compass rather than being one quarter of it — so the stopping
    // rule implies the ordering, whether or not it was asked for separately.
    const spread = flags.spreadCandidateBearings || flags.diversityAwareEarlyStop
      ? spreadAcrossCompass(ordered)
      : ordered
    // Bearings with real network behind them go first. Nothing is removed —
    // see network.ts on why a probe never gets to veto a direction outright.
    let attempts = summary ? biasAttemptsToNetwork(spread, summary, qualityTarget) : spread
    let passingCount = 0
    const timed = (loopAttempt: LoopAttempt) => metrics
      ? metrics.timeCandidate(() => buildOne(loopAttempt))
      : buildOne(loopAttempt)

    if (flags.twoStageScreening) {
      const screened = await screenAttempts(attempts)
      // Screening is a proxy, and a proxy that liked nothing has told us
      // nothing. Better to pay the full price for the batch than to offer a
      // walker nothing on the word of a cheap approximation.
      if (screened.length) attempts = screened
    }

    if (!flags.diversityAwareEarlyStop) {
      const routed = await mapWithConcurrency(attempts, options.concurrency ?? 6, timed, () => passingCount >= EARLY_STOP_PASSING_COUNT)
      const analysed = routed.filter((entry): entry is Analysed => entry !== undefined)
      metrics?.recordEarlyStop(passingCount >= EARLY_STOP_PASSING_COUNT ? 'passing-quota' : 'exhausted')
      return { analysed, passing: analysed.filter(entry => entry.report.pass) }
    }

    /**
     * Stopping on what has finished so far would make the answer depend on
     * which routing calls happened to be quick, which is not an answer at all:
     * the same request would offer different walks on a busy afternoon than on
     * a quiet one. So the decision is taken on an unbroken *prefix* of the
     * attempts — every attempt up to some point, all of them finished — and
     * the prefix that first satisfies the selector is the same prefix however
     * the work interleaved.
     */
    const results = new Array<Analysed | undefined>(attempts.length)
    const finished = new Array<boolean>(attempts.length).fill(false)
    let settledPrefix = 0
    let stopAtPrefix = -1
    let stopReason: 'passing-quota' | 'diversity-satisfied' = 'passing-quota'

    await mapWithConcurrency(attempts, options.concurrency ?? 6, async loopAttempt => {
      const entry = await timed(loopAttempt)
      results[loopAttempt.index] = entry
      finished[loopAttempt.index] = true
      while (settledPrefix < attempts.length && finished[settledPrefix]) {
        settledPrefix++
        if (stopAtPrefix >= 0) continue
        const verdict = enoughAlready(results.slice(0, settledPrefix))
        if (verdict) {
          stopAtPrefix = settledPrefix
          stopReason = verdict
        }
      }
      return entry
    }, () => stopAtPrefix >= 0)

    // Attempts beyond the deciding prefix may well have finished — they were
    // already in flight — but keeping whichever of them won a race is exactly
    // the non-determinism this exists to remove.
    const usable = stopAtPrefix >= 0 ? results.slice(0, stopAtPrefix) : results
    const analysed = usable.filter((entry): entry is Analysed => entry !== undefined)
    metrics?.recordEarlyStop(stopAtPrefix >= 0 ? stopReason : 'exhausted')
    return { analysed, passing: analysed.filter(entry => entry.report.pass) }

    /**
     * Can this pool already give the walker three genuinely different walks?
     * Asked with the production selector's own preferred pass, so the
     * generator never stops on a set the selector will then refuse.
     */
    function enoughAlready(prefix: Array<Analysed | undefined>): 'passing-quota' | 'diversity-satisfied' | undefined {
      const passed = prefix.filter((entry): entry is Analysed => entry !== undefined && entry.report.pass)
      if (passed.length >= EARLY_STOP_PASSING_COUNT) return 'passing-quota'
      if (passed.length < 3 + EARLY_STOP_RESERVE) return undefined
      const maxShared = overrides?.maxSharedFraction ?? MAX_SHARED_FRACTION
      return selectPreferredDiverseRoutes(passed.map(toSelectable), 3, maxShared).length >= 3
        ? 'diversity-satisfied'
        : undefined
    }

    async function buildOne(loopAttempt: LoopAttempt): Promise<Analysed | undefined> {
      metrics?.countCandidateBuilt()
      let best: Analysed | undefined
      for (const cornerCount of flags.narrowCornerSweep ? NARROW_CORNER_COUNTS : CORNER_COUNTS_TO_TRY) {
        const entry = await buildAndAnalyse(loopAttempt, { cornerCount, targetScale: 1, bearingShift: 0 }, options.route)
        if (!entry) continue
        // A clean shape at this corner count: no need to try a fussier one.
        if (entry.report.pass) { best = entry; break }
        if (!best || entry.report.quality.score > best.report.quality.score) best = entry
      }

      // One bounded, aimed attempt for a candidate that failed exactly one
      // gate and failed it narrowly — rather than discarding it and paying for
      // a whole fresh batch that knows no more than this one did.
      if (best && !best.report.pass && flags.localRepair) {
        const repaired = await tryRepair(best, loopAttempt)
        if (repaired) best = repaired
      }

      if (best) {
        metrics?.countCandidateRouted()
        for (const reason of best.report.rejections) {
          rejections[reason] = (rejections[reason] ?? 0) + 1
          metrics?.countRejection(reason)
        }
      }
      if (best?.report.pass) {
        passingCount++
        metrics?.countCandidatePassed()
      }
      return best
    }

    /**
     * Route the bare ring for every bearing in one request each, drop the
     * hopeless, and hand back only the bearings worth building properly.
     */
    async function screenAttempts(candidates: LoopAttempt[]): Promise<LoopAttempt[]> {
      // A ring of circumference C has radius C / 2π; the network makes the
      // walk longer than the ring, so aiming at the raw radius overshoots.
      // The probe's own measurement is used where there is one.
      const stretch = summary?.medianStretch ?? 1.35
      const radius = constructionTarget / (2 * Math.PI) / Math.max(1, stretch)

      const results = await mapWithConcurrency(candidates, options.concurrency ?? 6, async candidate => {
        const turn = candidate.direction === 'clockwise' ? 1 : -1
        const corners = Array.from({ length: SCREEN_CORNER_COUNT }, (_, corner) =>
          pointAtBearing(start, radius, normaliseBearing(candidate.initialBearing + turn * corner * (360 / SCREEN_CORNER_COUNT))))
        try {
          options.signal?.throwIfAborted()
          // One request, the whole ring, no avoidance and no repair.
          const ring = await options.route([start, ...corners, start], undefined, 'screen')
          const verdict = screenSkeleton({
            attemptId: candidate.id,
            bearing: bearingOf(ring.coordinates, start),
            coordinates: ring.coordinates,
            distanceMeters: ring.distanceMeters,
          }, start, qualityTarget)
          if (!verdict.keep && verdict.reason) metrics?.countRejection(`screen-${verdict.reason}`)
          return { item: candidate, verdict }
        } catch (error) {
          if (error instanceof GraphHopperError && error.kind !== 'transport') {
            // The bare ring could not be routed at all. That is the cheapest
            // possible "no" and exactly what this stage is for.
            metrics?.countRejection('screen-unroutable')
            return { item: candidate, verdict: { keep: false, score: 0, octant: 0 } as ScreenVerdict }
          }
          throw error
        }
      })

      return pickForRefinement(results.filter(Boolean), REFINE_LIMIT).map((attempt, index) => ({ ...attempt, index }))
    }

    /** Build one shape from one attempt, and measure it. */
    async function buildAndAnalyse(
      loopAttempt: LoopAttempt,
      shape: { cornerCount: number; targetScale: number; bearingShift: number; preAvoid?: LngLat[][] },
      route: LegRouter,
    ): Promise<Analysed | undefined> {
      // Swinging with the direction of travel, so a repair to a clockwise loop
      // and the same repair to its mirror are the same repair.
      const turn = loopAttempt.direction === 'clockwise' ? 1 : -1
      const candidate = await buildLoopIncrementally(
        start,
        constructionTarget * shape.targetScale,
        normaliseBearing(loopAttempt.initialBearing + shape.bearingShift * turn),
        loopAttempt.direction,
        route,
        {
          // Generous: a candidate that overshoots is still evidence about how much
          // this network stretches a ring, and that evidence steers the retry.
          abandonAboveMetres: qualityTarget * 2.2,
          legBudgetMetres: qualityTarget * LEG_BUDGET_SHARE,
          joinTurnThresholdDegrees: overrides?.joinTurnThresholdDegrees,
          waypointPullbackScale: overrides?.waypointPullbackScale,
          onFixup: (kind, kept) => metrics?.countFixup(kind, kept),
          budgetDetourGate: flags.budgetDetourGate,
          pullbackTurnOnly: flags.pullbackTurnOnly,
          cornerCount: shape.cornerCount,
          preAvoidGeometries: shape.preAvoid,
          signal: options.signal,
        },
      )
      if (!candidate) return undefined
      const traversals = flags.edgeOverlap ? measureTraversals(candidate.coordinates, candidate.edges) : undefined
      const report = analyseRouteQuality({
        traversals,
        coordinates: candidate.coordinates,
        start,
        distanceMeters: candidate.distanceMeters,
        durationSeconds: durationFor(candidate),
        targetMetres: qualityTarget,
        targetSeconds,
        legDistances: candidate.legDistances,
        maneuverSigns: candidate.steps.map(step => step.sign),
        thresholds: overrides?.quality,
      })
      if (flags.edgeOverlap) metrics?.countOverlapSource(report.overlapSource)
      return {
        candidate,
        report,
        coordinates: candidate.coordinates,
        quality: report.quality,
        bearing: bearingOf(candidate.coordinates, start),
        traversals,
        cornerCount: shape.cornerCount,
      }
    }

    /**
     * One repair, if this candidate has earned one and the request can still
     * afford it. Returns the repaired candidate only when the repair actually
     * worked; a repair that produced something no better leaves the original
     * exactly as it was, so a failed repair costs calls and nothing else.
     */
    async function tryRepair(entry: Analysed, loopAttempt: LoopAttempt): Promise<Analysed | undefined> {
      const plan = repairPlanFor(entry.report, {
        thresholds: overrides?.quality,
        cornerCount: entry.cornerCount,
        longestRepeatedFraction: entry.candidate.distanceMeters > 0
          ? entry.report.longestReverseRunMetres / entry.candidate.distanceMeters
          : 0,
      })
      if (!plan) return undefined
      if (!repairs.mayAttempt(loopAttempt.id)) {
        metrics?.countRepairBudgetExhausted()
        return undefined
      }
      repairs.beginAttempt(loopAttempt.id)
      metrics?.countRepairAttempt()

      const budgeted: LegRouter = (points, customModel) => {
        if (!repairs.spendCall()) throw new RepairBudgetExhausted()
        return options.route(points, customModel, 'repair')
      }
      try {
        const rebuilt = await buildAndAnalyse(loopAttempt, {
          cornerCount: plan.cornerCount ?? entry.cornerCount,
          targetScale: plan.targetScale,
          bearingShift: plan.bearingShift,
          preAvoid: plan.avoidRepeatedSection ? repeatedGroundOf(entry) : undefined,
        }, budgeted)
        if (!rebuilt?.report.pass) return undefined
        metrics?.countRepairSuccess()
        return { ...rebuilt, repairedBy: plan.strategy }
      } catch (error) {
        if (error instanceof RepairBudgetExhausted) {
          metrics?.countRepairBudgetExhausted()
          return undefined
        }
        throw error
      }
    }
  }

  /// The router decides where a person may walk; their saved pace decides how
  /// long that distance will take. Keep the router's own duration only for
  /// older clients that do not send a pace.
  function durationFor(candidate: RoutedCandidate): number {
    return request.walkingPaceMinutesPerKm === undefined
      ? candidate.durationSeconds
      : candidate.distanceMeters / 1000 * request.walkingPaceMinutesPerKm * 60
  }
}

const WAYPOINT_EXPECTATION_LIMIT = 1.25
/**
 * How far a waypoint walk may be from the plan. Wider than a plain loop's 12%
 * because the pins are fixed: the generator has less to work with, and a walk
 * that visits everywhere the walker asked for is worth some slack on length.
 */
const WAYPOINT_DISTANCE_TOLERANCE = 0.25
const WAYPOINT_GUIDE_COUNT = 16
const WAYPOINT_GUIDE_RADIUS_SAMPLES = 48

/**
 * Route through explicit places before returning home. The first candidate is
 * the shortest honest route through them; later candidates spend any spare
 * distance in different compass sectors without moving a pin the walker chose.
 */
async function generateWaypointLoops(
  request: LoopRequest,
  options: GenerateOptions,
  start: LngLat,
  targetMetres: number,
  targetSeconds: number | undefined,
): Promise<LoopResponse> {
  const points: LngLat[] = [start, ...request.waypoints!.map(point => [point.lng, point.lat] as LngLat), start]
  // This is only the lower-bound check. It is deliberately routed without
  // anti-retrace penalties; offering it would turn a single waypoint into the
  // same path out and back, which is not a loop.
  const metrics = options.metrics
  const flags = withFlags(options.flags)
  const legacyRejections: Record<string, number> = {}
  let legacyAssembled = 0
  let legacyPassed = 0
  let handedOver: HandedOver | undefined
  /** As in the backbone path: no way of giving up goes unreported. */
  const reportLegacy = (stage: WaypointStage, offered: number): Diagnostics => {
    const diagnostics: Diagnostics = {
      candidates: legacyAssembled,
      routed: legacyAssembled,
      passed: legacyPassed,
      offered,
      rejections: legacyRejections,
      retry: 'none',
      retracing: false,
      targetMetres,
      stage,
      // Carried through the hand-over, so the newer generator's failure is
      // still readable behind the older one's outcome.
      ...(handedOver
        ? {
            backboneStage: handedOver.stage,
            backboneRejections: handedOver.rejections,
            ...(handedOver.shapes ? { backboneShapes: handedOver.shapes } : {}),
          }
        : {}),
      ...(metrics ? { metrics: metrics.snapshot() } : {}),
    }
    options.onDiagnostics?.(diagnostics)
    return diagnostics
  }
  if (flags.waypointBackbone) {
    const built = await generateBackboneWaypointLoops(request, options, start, targetMetres, targetSeconds, flags, metrics)
    if (!isHandedOver(built)) return built
    // The backbone route could not be built — an anchor the engine cannot
    // reach, or nothing that assembles. Fall through to the generator that was
    // here before rather than telling the walker nothing works, but keep hold
    // of why, or the newer code's failure is lost behind the older one's.
    handedOver = built
  }
  const direct = await routeWaypointCandidate(points, options.route, false, options.signal, 'waypoint-direct')
  if (!direct) {
    return { routes: [], warning: 'One or more waypoints cannot be reached on foot.', diagnostics: reportLegacy('unreachable', 0) }
  }

  const durationFor = (candidate: RoutedCandidate) => request.walkingPaceMinutesPerKm === undefined
    ? candidate.durationSeconds
    : candidate.distanceMeters / 1000 * request.walkingPaceMinutesPerKm * 60
  const requested = targetSeconds ?? targetMetres
  const minimum = targetSeconds ? durationFor(direct) : direct.distanceMeters
  if (minimum > requested * WAYPOINT_EXPECTATION_LIMIT) {
    const actual = request.mode === 'time'
      ? `${Math.ceil(minimum / 60)} minutes`
      : `${(minimum / 1000).toFixed(1)} km`
    const asked = request.mode === 'time'
      ? `${Math.round(request.durationMinutes!)} minutes`
      : `${request.distanceKm!.toFixed(1)} km`
    return {
      routes: [],
      expectationExceeded: true,
      warning: `These waypoints need at least ${actual}, which is more than 25% over your ${asked} plan. Increase your plan or remove a waypoint.`,
      diagnostics: reportLegacy('over-plan', 0),
    }
  }

  // Most pins added from the choices screen already sit on one or more of the
  // clean loops being shown. Generate the ordinary candidates first and keep
  // any whose actual routed geometry passes the pins in order. Rebuilding a
  // perfectly good loop around a point it already visits is both slower and
  // much more likely to manufacture a needless spur.
  const ordinary = await generateLoops(
    { ...request, waypoints: undefined },
    { ...options, onDiagnostics: undefined },
  )
  const naturalRoutes = ordinary.warning === RETRACES_WARNING
    ? []
    : ordinary.routes.filter(route =>
      route.quality.repeatedPercent <= MAX_REPEATED_FRACTION * 100
      && routeHitsWaypoints(route.geometry.coordinates as LngLat[], request.waypoints!))
  if (naturalRoutes.length >= 3) {
    const kept = naturalRoutes.slice(0, 3)
    metrics?.recordOffered(measureOffered(
      kept.map(route => ({ coordinates: route.geometry.coordinates as LngLat[], distanceMeters: route.distanceMeters, quality: route.quality })),
      targetMetres,
    ))
    return { routes: kept, diagnostics: reportLegacy('reused-natural', kept.length) }
  }

  // Try the pins themselves with avoidance on the return legs. A waypoint on
  // an existing loop often already divides it into two perfectly good paths;
  // forcing an extra corner into that route only makes it less likely to fit.
  const pinOnly = await routeWaypointCandidate(points, options.route, true, options.signal, 'waypoint-leg')

  // Add one invisible shaping point to each alternative. Its reach is solved
  // from the local network stretch measured by the direct route, rather than
  // treating every metre left in the route budget as a metre of crow-flight.
  // The old residual/2 guess routinely put the guide well outside a 5 km ring
  // and caused otherwise available loops to be rejected as too long.
  const directCrowMetres = pathThrough(points)
  const networkStretch = directCrowMetres > 0
    ? Math.min(3, Math.max(0.8, direct.distanceMeters / directCrowMetres))
    : 1
  const targetCrowMetres = targetMetres / networkStretch
  const guideAttempts = generateLoopAttempts(
    seedFor(start, targetMetres, request.variation ?? 0),
    WAYPOINT_GUIDE_COUNT * 2,
  ).filter(attempt => attempt.direction === 'clockwise')
  const guided = await mapWithConcurrency(guideAttempts, Math.min(options.concurrency ?? 6, 3), async attempt => {
    const variant = Math.floor(attempt.index / 2)
    const insertion = 1 + (variant % (points.length - 1))
    const guideRadius = guideRadiusForTarget(points, insertion, start, attempt.initialBearing, targetCrowMetres)
    const scales = [0.78, 0.9, 1, 1, 1.1, 1.22]
    const guide = destination(start, guideRadius * scales[variant % scales.length], attempt.initialBearing)
    const shaped = [...points.slice(0, insertion), guide, ...points.slice(insertion)]
    return routeWaypointCandidate(shaped, options.route, true, options.signal, 'waypoint-leg')
  })
  const analysed = [pinOnly, ...guided]
    .filter((candidate): candidate is RoutedCandidate => candidate !== undefined)
    .map(candidate => {
      const durationSeconds = durationFor(candidate)
      const traversals = flags.edgeOverlap ? measureTraversals(candidate.coordinates, candidate.edges) : undefined
      const report = analyseRouteQuality({
        traversals,
        coordinates: candidate.coordinates,
        start,
        distanceMeters: candidate.distanceMeters,
        durationSeconds,
        targetMetres,
        targetSeconds,
        legDistances: candidate.legDistances,
        maneuverSigns: candidate.steps.map(step => step.sign),
        // A user pin can split an otherwise excellent route one metre from a
        // generated corner. Leg balance therefore says where the user tapped,
        // not whether the walk is good. Geometry still has to pass every loop,
        // closure, compactness, U-turn and repeated-ground gate.
        thresholds: {
          maxDistanceError: 0.25,
          maxDurationError: 0.25,
          maxLegShare: 1,
          minLegShare: 0,
        },
      })
      if (flags.edgeOverlap) metrics?.countOverlapSource(report.overlapSource)
      legacyAssembled++
      if (report.pass) legacyPassed++
      for (const reason of report.rejections) {
        legacyRejections[reason] = (legacyRejections[reason] ?? 0) + 1
        metrics?.countRejection(reason)
      }
      return {
        candidate,
        report,
        coordinates: candidate.coordinates,
        quality: report.quality,
        bearing: bearingOf(candidate.coordinates, start),
        traversals,
        totalMetres: candidate.distanceMeters,
      }
    })
    // Waypoint mode promises a loop. Unlike the standard fallback, a long
    // there-and-back feature is never excused here, even when it is the only
    // walkable ground through the pin.
    .filter(entry => entry.report.pass && entry.report.quality.repeatedPercent <= MAX_REPEATED_FRACTION * 100)

  const diverse = selectDiverseRoutes(analysed, 3, MAX_SHARED_FRACTION)
  const chosen = [...diverse]
  for (const candidate of analysed.sort((a, b) => b.quality.score - a.quality.score)) {
    if (chosen.length >= 3) break
    if (!chosen.includes(candidate)) chosen.push(candidate)
  }
  if (!chosen.length) {
    if (naturalRoutes.length) {
      return {
        routes: naturalRoutes,
        warning: `We found only ${naturalRoutes.length} clean ${naturalRoutes.length === 1 ? 'loop' : 'loops'} through those waypoints. Try moving a waypoint for more choices.`,
        diagnostics: reportLegacy('reused-natural', naturalRoutes.length),
      }
    }
    return {
      routes: [],
      warning: 'We couldn’t make a clean loop through those waypoints. Move or remove a waypoint, or increase your plan.',
      diagnostics: reportLegacy('legacy-empty', 0),
    }
  }

  const labels = labelRoutes(chosen.map(entry => ({ bearing: entry.bearing, distanceMeters: entry.candidate.distanceMeters })))
  const forcedRoutes = chosen.slice(0, 3).map((entry, index): LoopRoute => {
    const { candidate, report } = entry
    const durationSeconds = durationFor(candidate)
    const actual = targetSeconds ? durationSeconds : candidate.distanceMeters
    return {
      id: randomUUID(),
      label: labels[index],
      distanceMeters: Math.round(candidate.distanceMeters),
      durationSeconds: Math.round(durationSeconds),
      targetDifferencePercent: Math.round((actual / requested - 1) * 100),
      geometry: { type: 'LineString', coordinates: candidate.coordinates },
      steps: candidate.steps.map(step => ({
        instruction: step.instruction,
        distanceMeters: Math.round(step.distanceMeters),
        durationSeconds: Math.round(candidate.distanceMeters > 0 ? step.distanceMeters / candidate.distanceMeters * durationSeconds : step.durationSeconds),
        maneuver: step.maneuver,
        road: step.road,
        roadClass: step.roadClass,
        startIndex: step.startIndex,
        endIndex: step.endIndex,
      })),
      quality: report.quality,
    }
  })
  const routes = [...naturalRoutes, ...forcedRoutes].slice(0, 3)
  metrics?.recordOffered(measureOffered(
    routes.map(route => ({
      coordinates: route.geometry.coordinates as LngLat[],
      distanceMeters: route.distanceMeters,
      quality: route.quality,
    })),
    targetMetres,
  ))
  return {
    routes,
    diagnostics: reportLegacy('legacy-guides', routes.length),
    ...(routes.length < 3
      ? { warning: `We found only ${routes.length} clean ${routes.length === 1 ? 'loop' : 'loops'} through those waypoints. Try moving a waypoint for more choices.` }
      : {}),
  }
}


/**
 * The loosest two waypoint walks may be and still be offered as two walks.
 * Well above the ordinary limit, because pins force shared ground; well below
 * "identical", because at some point a second option is not one.
 */
const WAYPOINT_RELAXED_SHARED = 0.8

/**
 * How much of the walk the pins have to account for before they are treating
 * it as a route through places rather than a loop with a pin on it.
 */
const PIN_CONSTRAINT_SHARE = 0.1

/** Corners the screening ring is drawn with. Three is the shape most walks want. */
const SCREEN_CORNER_COUNT = 3
/**
 * How many screened bearings go on to be built properly.
 *
 * Above the three offered and the reserve the early stop wants, because
 * screening is a proxy and some of what survives it will still fail the real
 * gates. Below the batch size, because paying the expensive price for every
 * bearing is what screening exists to avoid.
 */
const REFINE_LIMIT = 8

/** How many assembled walks are measured before the diversity selector picks three. */
const BACKBONE_ASSEMBLY_LIMIT = 24
/** Resolution of the slack allocation, as a share of the requested length. */
const BACKBONE_BUCKET_SHARE = 0.02

/**
 * Waypoint loops, built from the ordered backbone out.
 *
 * Every anchor gap is routed once directly — which both gives the shortest
 * honest way between those two places and, added up, gives the floor `B` that
 * says whether the walk is possible at all. Whatever is left of the plan after
 * that is slack, and each gap is offered a few ways of spending some of it.
 * A small dynamic programme then picks one option per gap so the whole walk
 * adds up to what was asked for, spread rather than dumped in one place.
 *
 * The walker's pins are the gap boundaries throughout. Nothing here can move
 * one, because nothing here ever asks where they should be.
 *
 * Returns undefined when it cannot build anything at all, which is the older
 * generator's cue to try its own way rather than the walker's cue to give up.
 */
async function generateBackboneWaypointLoops(
  request: LoopRequest,
  options: GenerateOptions,
  start: LngLat,
  targetMetres: number,
  targetSeconds: number | undefined,
  flags: AlgorithmFlags,
  metrics: RequestMetrics | undefined,
): Promise<LoopResponse | HandedOver> {
  const rejections: Record<string, number> = {}
  let assembled = 0
  let passed = 0
  /** Emitted on every exit, so no way of giving up is silent. */
  const report = (stage: WaypointStage, offered: number, shapes?: Diagnostics['backboneShapes']): Diagnostics => {
    const diagnostics: Diagnostics = {
      candidates: assembled,
      routed: assembled,
      passed,
      offered,
      rejections,
      retry: 'none',
      retracing: false,
      targetMetres,
      stage,
      ...(shapes ? { backboneShapes: shapes } : {}),
      ...(metrics ? { metrics: metrics.snapshot() } : {}),
    }
    options.onDiagnostics?.(diagnostics)
    return diagnostics
  }
  const anchors: LngLat[] = [start, ...request.waypoints!.map(point => [point.lng, point.lat] as LngLat), start]
  const gapCount = anchors.length - 1
  const durationFor = (metres: number, seconds: number) => request.walkingPaceMinutesPerKm === undefined
    ? seconds
    : metres / 1000 * request.walkingPaceMinutesPerKm * 60

  // One direct route per gap. These are the backbone and they are also the
  // "spend nothing here" option, so nothing is paid for twice.
  const directs: RoutedLeg[] = []
  for (let gap = 0; gap < gapCount; gap++) {
    options.signal?.throwIfAborted()
    const leg = await routeSegment(options.route, anchors[gap], anchors[gap + 1], [], options.signal, 'waypoint-direct')
    if (!leg) {
      return { routes: [], warning: 'One or more waypoints cannot be reached on foot.', diagnostics: report('unreachable', 0) }
    }
    directs.push(leg)
  }
  const backbone = directs.reduce((total, leg) => total + leg.distanceMeters, 0)
  // A pin on the doorstep, or three pins within a street of each other, does
  // not describe a route: the backbone is nearly nothing and the slack is
  // nearly the whole walk, so "spread the slack across the gaps" degenerates
  // into "invent a loop", which is the ring generator's job and it is better
  // at it. Hand those back to the generator that reuses an ordinary loop
  // already passing the pins.
  if (backbone < targetMetres * PIN_CONSTRAINT_SHARE) return handOver('doorstep-pin', rejections)
  const requested = targetSeconds ?? targetMetres
  const measuredBackbone = targetSeconds
    ? directs.reduce((total, leg) => total + durationFor(leg.distanceMeters, leg.durationSeconds), 0)
    : backbone

  // Refusing costs the walker their walk, so the floor is checked properly
  // before it is used to refuse: the profile's preferred route can be longer
  // than the shortest one, and a preference is not a bound.
  const maxError = request.overrides?.quality?.maxDistanceError ?? WAYPOINT_DISTANCE_TOLERANCE
  if (!fitsInPlan(measuredBackbone, requested, maxError)) {
    const floor = await trueLowerBound(options, anchors, targetSeconds ? durationFor : undefined, measuredBackbone)
    if (!fitsInPlan(floor, requested, maxError)) {
      return { ...refuseWaypoints(request, floor, targetSeconds !== undefined), diagnostics: report('over-plan', 0) }
    }
  }

  const slack = Math.max(0, targetMetres - backbone)
  const perGap = slack / gapCount

  // A few ways of spending part of the slack in each gap, routed once each.
  const byGap: SegmentOption[][] = []
  const routed = new Map<string, RoutedLeg[]>()
  for (let gap = 0; gap < gapCount; gap++) {
    const forThisGap: SegmentOption[] = [{
      gap,
      id: `${gap}-direct`,
      guides: [],
      distanceMeters: directs[gap].distanceMeters,
      durationSeconds: directs[gap].durationSeconds,
    }]
    routed.set(`${gap}-direct`, [directs[gap]])

    const crow = haversine(anchors[gap], anchors[gap + 1])
    const stretch = crow > 0 ? directs[gap].distanceMeters / crow : 1
    for (const plan of planSegmentOptions(gap, anchors[gap], anchors[gap + 1], perGap, stretch)) {
      if (!plan.guides.length) continue
      const legs = await routeThrough(options.route, [anchors[gap], ...plan.guides, anchors[gap + 1]], options.signal, (kind, kept) => metrics?.countFixup(kind, kept))
      if (!legs) continue
      routed.set(plan.id, legs)
      forThisGap.push({
        gap,
        id: plan.id,
        guides: plan.guides,
        distanceMeters: legs.reduce((total, leg) => total + leg.distanceMeters, 0),
        durationSeconds: legs.reduce((total, leg) => total + leg.durationSeconds, 0),
      })
    }
    byGap.push(forThisGap)
  }

  const allocations = allocateSlack(byGap, {
    anchors,
    target: targetMetres,
    bucketMetres: Math.max(25, targetMetres * BACKBONE_BUCKET_SHARE),
    limit: BACKBONE_ASSEMBLY_LIMIT,
  })
  if (!allocations.length) return handOver('no-allocation', rejections)
  // Reported on every exit from here on: if `enclosing` is zero the shape
  // preference had nothing to prefer, and the problem is where the shaping
  // points are put rather than which combination is chosen.
  const shapes: Diagnostics['backboneShapes'] = {
    assembled: allocations.length,
    enclosing: allocations.filter(allocation => allocation.shape >= DEFAULT_ALLOCATION.minShape).length,
    best: Number(Math.max(...allocations.map(allocation => allocation.shape)).toFixed(3)),
  }

  const analysed = allocations.map(allocation => {
    const legs = allocation.chosen.flatMap(option => routed.get(option.id) ?? [])
    const joined = joinAndTrimLegs(legs)
    const candidate: RoutedCandidate = {
      attemptId: `backbone-${allocation.chosen.map(option => option.id).join('_')}`,
      legs,
      ...joined,
      legDistances: legs.map(leg => leg.distanceMeters),
    }
    const durationSeconds = durationFor(candidate.distanceMeters, candidate.durationSeconds)
    const traversals = flags.edgeOverlap ? measureTraversals(candidate.coordinates, candidate.edges) : undefined
    const quality = analyseRouteQuality({
      traversals,
      coordinates: candidate.coordinates,
      start,
      distanceMeters: candidate.distanceMeters,
      durationSeconds,
      targetMetres,
      targetSeconds,
      legDistances: candidate.legDistances,
      maneuverSigns: candidate.steps.map(step => step.sign),
      // A pin can split an otherwise excellent walk one metre from a corner,
      // so leg balance says where the walker tapped rather than whether the
      // walk is good. Everything about the walk's own shape still applies.
      thresholds: {
        ...request.overrides?.quality,
        maxDistanceError: request.overrides?.quality?.maxDistanceError ?? WAYPOINT_DISTANCE_TOLERANCE,
        maxDurationError: request.overrides?.quality?.maxDurationError ?? WAYPOINT_DISTANCE_TOLERANCE,
        maxLegShare: 1,
        minLegShare: 0,
      },
    })
    if (flags.edgeOverlap) metrics?.countOverlapSource(quality.overlapSource)
    assembled++
    if (quality.pass) passed++
    for (const reason of quality.rejections) {
      rejections[reason] = (rejections[reason] ?? 0) + 1
      metrics?.countRejection(reason)
    }
    return {
      candidate,
      report: quality,
      coordinates: candidate.coordinates,
      quality: quality.quality,
      bearing: bearingOf(candidate.coordinates, start),
      traversals,
      totalMetres: candidate.distanceMeters,
      durationSeconds,
    }
  })

  const offerable = analysed.filter(entry => entry.report.pass)
  // Every assembled walk failed a gate. `rejections` says which, which is the
  // only thing that makes this case debuggable from a log line.
  if (!offerable.length) return handOver('all-rejected', rejections, shapes)

  // Pins constrain a walk in a way a plain loop is not: every alternative has
  // to visit the same places, and between two pins there is often only one
  // sensible way. So where the ordinary separation cannot be met, the bar is
  // lowered once — and then stops. Three walks that are ninety per cent the
  // same walk are one walk with two extra taps to dismiss, and offering them
  // is worse than admitting there is only one.
  const maxShared = request.overrides?.maxSharedFraction ?? MAX_SHARED_FRACTION
  const chosen = pickWithFallbackSeparation(offerable, maxShared)

  metrics?.recordOffered(measureOffered(chosen.map(entry => ({
    coordinates: entry.coordinates,
    distanceMeters: entry.candidate.distanceMeters,
    quality: entry.quality,
    traversals: entry.traversals,
  })), targetMetres))

  const labels = labelRoutes(chosen.map(entry => ({ bearing: entry.bearing, distanceMeters: entry.candidate.distanceMeters })))
  const routes = chosen.map((entry, index): LoopRoute => {
    const actual = targetSeconds ? entry.durationSeconds : entry.candidate.distanceMeters
    return {
      id: randomUUID(),
      label: labels[index],
      distanceMeters: Math.round(entry.candidate.distanceMeters),
      durationSeconds: Math.round(entry.durationSeconds),
      targetDifferencePercent: Math.round((actual / requested - 1) * 100),
      geometry: { type: 'LineString', coordinates: entry.candidate.coordinates },
      steps: entry.candidate.steps.map(step => ({
        instruction: step.instruction,
        distanceMeters: Math.round(step.distanceMeters),
        durationSeconds: Math.round(entry.candidate.distanceMeters > 0
          ? step.distanceMeters / entry.candidate.distanceMeters * entry.durationSeconds
          : step.durationSeconds),
        maneuver: step.maneuver,
        road: step.road,
        roadClass: step.roadClass,
        startIndex: step.startIndex,
        endIndex: step.endIndex,
      })),
      quality: entry.report.quality,
    }
  })

  return {
    routes,
    diagnostics: report('backbone', routes.length, shapes),
    ...(routes.length < 3
      ? { warning: `We found only ${routes.length} clean ${routes.length === 1 ? 'loop' : 'loops'} through those waypoints. Try moving a waypoint for more choices.` }
      : {}),
  }
}

/**
 * The distance below which no walk through these anchors can go.
 *
 * Only asked for when the ordinary routes already look too long — which is the
 * only moment it matters, and which keeps the extra call off every request
 * that was never going to be refused. Where the engine will not answer, the
 * ordinary measurement stands: refusing on a floor we could not establish
 * would be refusing on a guess.
 */
async function trueLowerBound(
  options: GenerateOptions,
  anchors: LngLat[],
  durationFor: ((metres: number, seconds: number) => number) | undefined,
  fallback: number,
): Promise<number> {
  let total = 0
  for (let gap = 0; gap < anchors.length - 1; gap++) {
    try {
      options.signal?.throwIfAborted()
      const leg = await options.route([anchors[gap], anchors[gap + 1]], shortestPathCustomModel(), 'waypoint-direct')
      total += durationFor ? durationFor(leg.distanceMeters, leg.durationSeconds) : leg.distanceMeters
    } catch (error) {
      if (error instanceof GraphHopperError) return fallback
      throw error
    }
  }
  return total
}

/**
 * Three genuinely different walks if they exist, or the same selector run once
 * more at a looser bar if they do not — never a top-up that ignores separation
 * altogether, which is how three readings of one walk get offered as three.
 */
function pickWithFallbackSeparation<T extends Parameters<typeof selectDiverseRoutes>[0][number]>(offerable: T[], maxShared: number): T[] {
  const strict = selectDiverseRoutes(offerable, 3, maxShared)
  if (strict.length >= 3 || maxShared >= WAYPOINT_RELAXED_SHARED) return strict
  const relaxed = selectDiverseRoutes(offerable, 3, WAYPOINT_RELAXED_SHARED)
  return relaxed.length > strict.length ? relaxed : strict
}

/** The refusal, worded the way it always has been. */
function refuseWaypoints(request: LoopRequest, minimum: number, inTime: boolean): LoopResponse {
  const actual = inTime ? `${Math.ceil(minimum / 60)} minutes` : `${(minimum / 1000).toFixed(1)} km`
  const asked = request.mode === 'time'
    ? `${Math.round(request.durationMinutes!)} minutes`
    : `${request.distanceKm!.toFixed(1)} km`
  return {
    routes: [],
    expectationExceeded: true,
    warning: `These waypoints need at least ${actual}, which is more than 25% over your ${asked} plan. Increase your plan or remove a waypoint.`,
  }
}

/** One anchor-to-anchor leg, penalised against ground already used. */
async function routeSegment(
  route: LegRouter,
  from: LngLat,
  to: LngLat,
  walked: LngLat[][],
  signal: AbortSignal | undefined,
  purpose: RoutePurpose,
): Promise<RoutedLeg | undefined> {
  signal?.throwIfAborted()
  try {
    const leg = await route([from, to], avoidanceCustomModel([]), purpose)
    return { ...leg, relaxed: false, avoidanceAreaCount: walked.length }
  } catch (error) {
    if (error instanceof GraphHopperError && error.kind !== 'transport') return undefined
    throw error
  }
}

/**
 * A gap routed via its shaping points. Each hop is penalised against the ones
 * before it within this gap, so an out-and-back to a guide point is pushed
 * back off itself the same way the ring generator's legs are.
 */
async function routeThrough(
  route: LegRouter,
  points: LngLat[],
  signal: AbortSignal | undefined,
  onFixup?: SequentialRoutingOptions['onFixup'],
): Promise<RoutedLeg[] | undefined> {
  const legs: RoutedLeg[] = []
  const walked: LngLat[][] = []
  for (let index = 1; index < points.length; index++) {
    signal?.throwIfAborted()
    const result = await routeLegAttempt(route, points[0], walked, points[index - 1], points[index], {
      signal,
      basePurpose: 'waypoint-leg',
      onFixup,
    })
    if (!result) return undefined
    legs.push({ ...result.leg, relaxed: result.relaxed, avoidanceAreaCount: walked.length })
    walked.push(result.leg.coordinates)
  }
  return legs
}

/** Crow-flight length of a point sequence, used only to aim a guide point. */
function pathThrough(points: LngLat[]): number {
  let metres = 0
  for (let index = 1; index < points.length; index++) metres += haversine(points[index - 1], points[index])
  return metres
}

/**
 * Find the guide reach whose point sequence is closest to the desired
 * crow-flight perimeter. Sampling is intentional: the length is not monotonic
 * when the bearing points between the two places being split, so binary search
 * can confidently choose the wrong side of the minimum.
 */
function guideRadiusForTarget(
  points: LngLat[],
  insertion: number,
  start: LngLat,
  bearing: number,
  targetCrowMetres: number,
): number {
  const before = points[insertion - 1]
  const after = points[insertion]
  const unchanged = pathThrough(points) - haversine(before, after)
  const maximum = Math.max(300, targetCrowMetres)
  let bestRadius = 0
  let bestError = Infinity
  for (let sample = 0; sample <= WAYPOINT_GUIDE_RADIUS_SAMPLES; sample++) {
    const radius = maximum * sample / WAYPOINT_GUIDE_RADIUS_SAMPLES
    const guide = destination(start, radius, bearing)
    const estimate = unchanged + haversine(before, guide) + haversine(guide, after)
    const error = Math.abs(estimate - targetCrowMetres)
    if (error < bestError) {
      bestError = error
      bestRadius = radius
    }
  }
  return Math.max(75, bestRadius)
}

const WAYPOINT_HIT_TOLERANCE_METRES = 40

/** True when a route passes every supplied pin in the order it was added. */
function routeHitsWaypoints(coordinates: LngLat[], waypoints: Array<{ lng: number; lat: number }>): boolean {
  if (coordinates.length < 2) return false
  const project = projector(coordinates[0])
  const route = coordinates.map(project)
  let afterSegment = 0
  for (const waypoint of waypoints) {
    const point = project([waypoint.lng, waypoint.lat])
    let bestSegment = -1
    let bestDistance = Infinity
    for (let index = afterSegment; index < route.length - 1; index++) {
      const distance = pointToSegmentDistance(point, route[index], route[index + 1])
      if (distance < bestDistance) {
        bestDistance = distance
        bestSegment = index
      }
    }
    if (bestDistance > WAYPOINT_HIT_TOLERANCE_METRES) return false
    afterSegment = bestSegment
  }
  return true
}

function pointToSegmentDistance(point: Metric, from: Metric, to: Metric): number {
  const dx = to[0] - from[0]
  const dy = to[1] - from[1]
  const lengthSquared = dx * dx + dy * dy
  if (lengthSquared === 0) return distanceBetween(point, from)
  const position = Math.max(0, Math.min(1, ((point[0] - from[0]) * dx + (point[1] - from[1]) * dy) / lengthSquared))
  return distanceBetween(point, [from[0] + position * dx, from[1] + position * dy])
}

async function routeWaypointCandidate(
  points: LngLat[],
  route: LegRouter,
  avoidWalkedGround: boolean,
  signal?: AbortSignal,
  basePurpose: RoutePurpose = 'waypoint-leg',
): Promise<RoutedCandidate | undefined> {
  const legs: RoutedLeg[] = []
  const walked: LngLat[][] = []
  for (let index = 1; index < points.length; index++) {
    signal?.throwIfAborted()
    const from = points[index - 1]
    const to = points[index]
    if (avoidWalkedGround) {
      // User waypoints stay exact: unlike generated corners, they are never
      // pulled away from a dead end. The next leg instead avoids ground already
      // used, and the finished geometry is rejected if that still retraces.
      const result = await routeLegAttempt(route, points[0], walked, from, to, { signal, basePurpose })
      if (!result) return undefined
      legs.push({ ...result.leg, relaxed: result.relaxed, avoidanceAreaCount: walked.length })
      walked.push(result.leg.coordinates)
    } else {
      try {
        const leg = await route([from, to], avoidanceCustomModel([]), basePurpose)
        legs.push({ ...leg, relaxed: false, avoidanceAreaCount: 0 })
      } catch (error) {
        if (error instanceof GraphHopperError && error.kind !== 'transport') return undefined
        throw error
      }
    }
  }
  const joined = joinAndTrimLegs(legs)
  return {
    attemptId: `waypoints-${points.length}`,
    legs,
    ...joined,
    legDistances: legs.map(leg => leg.distanceMeters),
  }
}

/**
 * What the walker was actually offered, measured rather than assumed. The
 * pairwise shared figure is the worst of the two directions for every pair,
 * because "these two are the same walk" is not a symmetric measurement when
 * one route is much longer than the other.
 */
export function measureOffered(
  offered: Array<{
    coordinates: LngLat[]
    distanceMeters: number
    quality: { repeatedPercent: number; uTurnCount: number }
    traversals?: EdgeTraversal[]
  }>,
  targetMetres: number,
): OfferedMetrics {
  if (!offered.length) {
    return {
      count: 0,
      medianDistanceErrorPercent: 0,
      maxDistanceErrorPercent: 0,
      medianRepeatedPercent: 0,
      maxRepeatedPercent: 0,
      totalUTurns: 0,
      maxPairSharedPercent: 0,
      maxPairSharedEdgePercent: undefined,
    }
  }
  const errors = offered.map(route => targetMetres > 0
    ? Math.abs(route.distanceMeters - targetMetres) / targetMetres * 100
    : 0)
  const repeated = offered.map(route => route.quality.repeatedPercent)
  let maxPairShared = 0
  let maxPairSharedEdge = 0
  let anyEdges = false
  for (let i = 0; i < offered.length; i++) {
    for (let j = i + 1; j < offered.length; j++) {
      maxPairShared = Math.max(
        maxPairShared,
        sharedCorridorMetres(offered[i].coordinates, offered[j].coordinates).fraction,
        sharedCorridorMetres(offered[j].coordinates, offered[i].coordinates).fraction,
      )
      const left = offered[i]
      const right = offered[j]
      if (left.traversals?.length && right.traversals?.length) {
        anyEdges = true
        maxPairSharedEdge = Math.max(
          maxPairSharedEdge,
          sharedEdgeMetres(left.traversals, right.traversals, left.distanceMeters).fraction,
          sharedEdgeMetres(right.traversals, left.traversals, right.distanceMeters).fraction,
        )
      }
    }
  }
  const round1 = (value: number) => Number(value.toFixed(1))
  return {
    count: offered.length,
    medianDistanceErrorPercent: round1(median(errors)),
    maxDistanceErrorPercent: round1(Math.max(...errors)),
    medianRepeatedPercent: round1(median(repeated)),
    maxRepeatedPercent: round1(Math.max(...repeated)),
    totalUTurns: offered.reduce((sum, route) => sum + route.quality.uTurnCount, 0),
    maxPairSharedPercent: round1(maxPairShared * 100),
    maxPairSharedEdgePercent: anyEdges ? round1(maxPairSharedEdge * 100) : undefined,
  }
}

/**
 * A candidate's costs, all of them things a walker would rather have less of.
 *
 * Read straight off the quality report rather than recomputed, so the front is
 * ranking the same measurements the gates already used and cannot quietly
 * disagree with them.
 */
export function objectivesOf(entry: {
  report: QualityReport
  quality: QualityReport['quality']
}): Objectives {
  const { report } = entry
  const shares = report.legShares
  return {
    targetError: Math.max(report.distanceErrorFraction, report.durationErrorFraction ?? 0),
    repeatedFraction: entry.quality.repeatedPercent / 100,
    shapePenalty: 1 - entry.quality.compactness,
    legImbalance: shares.length > 1 ? Math.max(...shares) - Math.min(...shares) : 0,
    manoeuvrePenalty: entry.quality.uTurnCount,
  }
}

/**
 * The stretch of a walk that was covered twice, as ground for a rebuild to be
 * pushed off. Taken from the network where the edges are known and from the
 * geometry where they are not — the same question, answered by whichever
 * measure this route actually has.
 */
function repeatedGroundOf(entry: Analysed): LngLat[][] | undefined {
  const section = entry.traversals?.length
    ? longestRepeatedSection(entry.traversals)
    : longestGeometricRepeat(entry.coordinates)
  if (!section || section.metres < MIN_SHARED_RUN_METRES) return undefined
  const ground = sliceByDistance(entry.coordinates, section.fromAlong, section.toAlong)
  return ground.length >= 2 ? [ground] : undefined
}

function longestGeometricRepeat(coordinates: LngLat[]): { fromAlong: number; toAlong: number; metres: number } | undefined {
  const runs = findRepeatedCorridors(coordinates).runs
  if (!runs.length) return undefined
  const longest = runs.reduce((best, run) => (run.metres > best.metres ? run : best))
  return { fromAlong: longest.alongStart, toAlong: longest.alongStart + longest.metres, metres: longest.metres }
}

/** The part of a line between two distances along it, vertices included whole. */
function sliceByDistance(coordinates: LngLat[], fromMetres: number, toMetres: number): LngLat[] {
  const kept: LngLat[] = []
  let along = 0
  for (let index = 0; index < coordinates.length; index++) {
    if (index > 0) along += haversine(coordinates[index - 1], coordinates[index])
    if (along >= fromMetres && along <= toMetres) kept.push(coordinates[index])
    if (along > toMetres) break
  }
  return kept
}

const toSelectable = (source: Analysed) => ({
  coordinates: source.coordinates,
  quality: { score: source.quality.score },
  bearing: source.bearing,
  traversals: source.traversals,
  totalMetres: source.candidate.distanceMeters,
  source,
})

const merge = (...groups: Analysed[][]) => Array.from(new Set(groups.flat()))

/** A retry re-aims; it does not go hunting. */
const clampScale = (scale: number) => Math.min(1.5, Math.max(0.55, Number.isFinite(scale) ? scale : 1))

function median(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b)
  const middle = Math.floor(sorted.length / 2)
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
}

/**
 * Candidates are independent, but twenty-four at once is more load than a small
 * routing container should take from one walker.
 *
 * `shouldStop`, checked before each item is claimed, lets a caller stop
 * dispatching *new* work once it already has enough — an attempt already
 * claimed still runs to completion, so this only ever trims the tail of a
 * batch that turned out not to be needed.
 */
export async function mapWithConcurrency<T, R>(items: T[], limit: number, worker: (item: T) => Promise<R>, shouldStop?: () => boolean): Promise<R[]> {
  const results = new Array<R>(items.length)
  let next = 0
  const runners = Array.from({ length: Math.max(1, Math.min(limit, items.length)) }, async () => {
    for (;;) {
      if (shouldStop?.()) return
      const index = next++
      if (index >= items.length) return
      results[index] = await worker(items[index])
    }
  })
  await Promise.all(runners)
  return results
}
