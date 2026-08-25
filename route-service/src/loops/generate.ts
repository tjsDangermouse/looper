import { randomUUID } from 'node:crypto'
import type { LineString } from 'geojson'
import { GraphHopperError } from '../graphhopper.js'
import { DEFAULT_ATTEMPT_COUNT, generateLoopAttempts } from './candidates.js'
import { MAX_SHARED_FRACTION, initialBearing as bearingOf, labelRoutes, selectDiverseRoutes } from './diversity.js'
import { destination, distanceBetween, haversine, projector, type LngLat, type Metric } from './geo.js'
import { MAX_REPEATED_FRACTION, analyseRouteQuality, sharedCorridorMetres, type QualityReport, type QualityThresholds } from './quality.js'
import { LEG_BUDGET_SHARE, buildLoopIncrementally, joinLegGeometries, routeLegAttempt, type LegRouter, type RoutedCandidate, type RoutedLeg } from './routing.js'
import { avoidanceCustomModel } from './avoidance.js'
import { seedFor } from './random.js'
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
/** Corner counts tried, simplest first, before an attempt gives up on a bearing. */
const CORNER_COUNTS_TO_TRY = [1, 2, 3, 4]
/** Fresh candidate batches tried before we honestly return fewer than three loops. */
const MAX_DISCOVERY_BATCHES = 3

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
}

export type Retry = 'none' | 'duration' | 'radius' 

type Analysed = {
  candidate: RoutedCandidate
  report: QualityReport
  coordinates: LngLat[]
  quality: QualityReport['quality']
  bearing: number
}

export async function generateLoops(request: LoopRequest, options: GenerateOptions): Promise<LoopResponse> {
  const start: LngLat = [request.start.lng, request.start.lat]
  const variation = request.variation ?? 0
  const targetSeconds = targetSecondsFor(request)
  const firstTarget = targetMetresFor(request)
  const overrides = request.overrides
  const candidateCount = overrides?.candidateCount ?? options.candidateCount ?? DEFAULT_ATTEMPT_COUNT

  if (request.waypoints?.length) {
    return generateWaypointLoops(request, options, start, firstTarget, targetSeconds)
  }

  const rejections: Record<string, number> = {}
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
    return selectDiverseRoutes(fresh.map(toSelectable), 3, maxShared)
  }
  let chosen = choose()

  // One heuristic batch can miss perfectly good loops on a dense or uneven
  // network. Keep sampling fresh bearings until the walker has three distinct
  // choices, rather than making them press refresh to discover them.
  for (let batch = 1; chosen.length < 3 && batch < MAX_DISCOVERY_BATCHES; batch++) {
    const next = await attempt(targetMetres, targetMetres, variation + batch)
    candidateBatches++
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
    const attempts = generateLoopAttempts(seed, candidateCount)
    const routed = await mapWithConcurrency(attempts, options.concurrency ?? 6, async loopAttempt => {
      let best: Analysed | undefined
      for (const cornerCount of CORNER_COUNTS_TO_TRY) {
        const candidate = await buildLoopIncrementally(start, constructionTarget, loopAttempt.initialBearing, loopAttempt.direction, options.route, {
          // Generous: a candidate that overshoots is still evidence about how much
          // this network stretches a ring, and that evidence steers the retry.
          abandonAboveMetres: qualityTarget * 2.2,
          legBudgetMetres: qualityTarget * LEG_BUDGET_SHARE,
          joinTurnThresholdDegrees: overrides?.joinTurnThresholdDegrees,
          waypointPullbackScale: overrides?.waypointPullbackScale,
          cornerCount,
          signal: options.signal,
        })
        if (!candidate) continue
        const report = analyseRouteQuality({
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
        const entry: Analysed = {
          candidate,
          report,
          coordinates: candidate.coordinates,
          quality: report.quality,
          bearing: bearingOf(candidate.coordinates, start),
        }
        // A clean shape at this corner count: no need to try a fussier one.
        if (report.pass) { best = entry; break }
        if (!best || entry.report.quality.score > best.report.quality.score) best = entry
      }
      if (best) for (const reason of best.report.rejections) rejections[reason] = (rejections[reason] ?? 0) + 1
      return best
    })
    const analysed = routed.filter((entry): entry is Analysed => entry !== undefined)
    return { analysed, passing: analysed.filter(entry => entry.report.pass) }
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
  const direct = await routeWaypointCandidate(points, options.route, false, options.signal)
  if (!direct) return { routes: [], warning: 'One or more waypoints cannot be reached on foot.' }

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
  if (naturalRoutes.length >= 3) return { routes: naturalRoutes.slice(0, 3) }

  // Try the pins themselves with avoidance on the return legs. A waypoint on
  // an existing loop often already divides it into two perfectly good paths;
  // forcing an extra corner into that route only makes it less likely to fit.
  const pinOnly = await routeWaypointCandidate(points, options.route, true, options.signal)

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
    return routeWaypointCandidate(shaped, options.route, true, options.signal)
  })
  const analysed = [pinOnly, ...guided]
    .filter((candidate): candidate is RoutedCandidate => candidate !== undefined)
    .map(candidate => {
      const durationSeconds = durationFor(candidate)
      const report = analyseRouteQuality({
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
      return { candidate, report, coordinates: candidate.coordinates, quality: report.quality, bearing: bearingOf(candidate.coordinates, start) }
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
      }
    }
    return {
      routes: [],
      warning: 'We couldn’t make a clean loop through those waypoints. Move or remove a waypoint, or increase your plan.',
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
  return {
    routes,
    ...(routes.length < 3
      ? { warning: `We found only ${routes.length} clean ${routes.length === 1 ? 'loop' : 'loops'} through those waypoints. Try moving a waypoint for more choices.` }
      : {}),
  }
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
      const result = await routeLegAttempt(route, points[0], walked, from, to, { signal })
      if (!result) return undefined
      legs.push({ ...result.leg, relaxed: result.relaxed, avoidanceAreaCount: walked.length })
      walked.push(result.leg.coordinates)
    } else {
      try {
        const leg = await route([from, to], avoidanceCustomModel([]))
        legs.push({ ...leg, relaxed: false, avoidanceAreaCount: 0 })
      } catch (error) {
        if (error instanceof GraphHopperError && error.kind !== 'transport') return undefined
        throw error
      }
    }
  }
  const joined = joinLegGeometries(legs)
  return {
    attemptId: `waypoints-${points.length}`,
    legs,
    ...joined,
    legDistances: legs.map(leg => leg.distanceMeters),
  }
}

const toSelectable = (source: Analysed) => ({
  coordinates: source.coordinates,
  quality: { score: source.quality.score },
  bearing: source.bearing,
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
 */
export async function mapWithConcurrency<T, R>(items: T[], limit: number, worker: (item: T) => Promise<R>): Promise<R[]> {
  const results = new Array<R>(items.length)
  let next = 0
  const runners = Array.from({ length: Math.max(1, Math.min(limit, items.length)) }, async () => {
    for (;;) {
      const index = next++
      if (index >= items.length) return
      results[index] = await worker(items[index])
    }
  })
  await Promise.all(runners)
  return results
}
