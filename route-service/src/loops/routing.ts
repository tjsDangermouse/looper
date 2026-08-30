import type { Feature, Polygon } from 'geojson'
import { AVOID_PRIORITY, RELAXED_AVOID_PRIORITY, avoidanceCustomModel, buildAvoidanceAreas, buildSpikeAvoidanceArea } from './avoidance.js'
import type { LoopDirection } from './candidates.js'
import { bearingBetween, destination, distanceBetween, haversine, normaliseBearing, pathLength, resample, type LngLat } from './geo.js'
import { MIN_BACKTRACK_METRES, sharedCorridorMetres } from './quality.js'
import { GraphHopperError, type GraphHopperLeg, type GraphHopperStep } from '../graphhopper.js'
import type { BoundaryTrace, FixupKind, RoutePurpose } from './metrics.js'
import type { EdgeSpan } from './edges.js'
import { noteCall, traceDecision, withAttemptScope, withImpliedAttemptScope, withLegScope } from './trace.js'

/**
 * Building a loop, a leg at a time.
 *
 * Each leg is an ordinary point-to-point request. What makes the result a loop
 * rather than a there-and-back is that every leg after the first is handed the
 * ground the earlier legs already covered, weighted twenty times against.
 *
 * The loop's shape is not decided up front. It is planned live: after every
 * leg, how much distance is left and how many turns are left to spend it on
 * decide where the next leg aims, and a leg that blows its share of the budget
 * gets a bounded number of locally-adjusted retries — a different bearing, a
 * shorter reach — rather than the whole attempt being thrown away and a fresh
 * blind guess started from scratch.
 */

/**
 * No single leg of a loop should be half the whole walk. Past that, the
 * avoidance penalty is no longer nudging the route round a corner — it is
 * sending the walk somewhere else entirely.
 */
export const LEG_BUDGET_SHARE = 0.5

/**
 * A waypoint is just a point aimed at from where the walk currently stands,
 * with no idea what street layout is underneath it. Where it lands inside a
 * cul-de-sac, the leg arriving there and the leg leaving it are forced back
 * down the same short stub to reach it — not because the ring is a bad shape,
 * but because that one point happens to sit somewhere only reachable one way.
 * The tell is at the join: the walk arrives heading one way and immediately
 * leaves heading almost the opposite way, at the same spot. A corner in open
 * country never looks like this; a cul-de-sac suburb produces it constantly.
 */
export const JOIN_TURN_THRESHOLD_DEGREES = 150
/** How far to pull a dead-ending waypoint back toward the start, once, before giving up on it. */
export const WAYPOINT_PULLBACK_SCALE = 0.65
/** How far from a leg's own end to sample its direction of travel there. */
const EDGE_BEARING_WINDOW_METRES = 30

/**
 * Short dead-end branches inside a single leg.
 *
 * The join check above catches a *waypoint* landing in a cul-de-sac. It does
 * nothing for the far more common case: the shortest path GraphHopper finds
 * between two ordinary points on this leg happens to duck down a driveway,
 * footpath stub or short cul-de-sac and back, because that is genuinely the
 * nearest way to thread between the streets either side of it. The walker
 * experiences both the same way — a stretch of pavement retraced for no
 * reason — so both get the same fix: circle the dead end and ask the router
 * to go round it.
 */
const SPIKE_SAMPLE_METRES = 10
/** ~20 m either side of the turn, so only a short branch is ever caught. */
const SPIKE_WINDOW_SAMPLES = 2
const SPIKE_ANGLE_DEGREES = 150
const SPIKE_RETURN_METRES = 20
/** Radius of the avoidance disc dropped over a spike's tip. */
const SPIKE_AVOID_RADIUS_METRES = 25

/**
 * A spike that resisted every attempt to route round it — the ground
 * genuinely offers no other way for that one short stretch — is still worth
 * cutting from the geometry once it is small enough that showing it does more
 * harm than the small dishonesty of not showing exactly how the last few
 * metres were reached. Well below anything the quality gate would reject a
 * whole route over.
 */
const TINY_SPIKE_ROUND_TRIP_METRES = 80
const TINY_SPIKE_MATCH_METRES = 15
/**
 * A ceiling on how much a route may lose to trimming in total, nesting
 * included. A genuine dead-end-off-a-dead-end is a few of these passes deep
 * at most; a route that is fundamentally an out-and-back — every point on
 * the way out has a ground-level mirror on the way back — would otherwise
 * have almost the whole thing trimmed away pass after pass. Comfortably
 * below MIN_BACKTRACK_METRES: this is for noise, not for deciding whether a
 * real feature belongs in the walk.
 */
const MAX_TOTAL_TRIM_METRES = 300

/** How many corners to aim for before heading back to the start. */
const DEFAULT_CORNER_COUNT = 3
/** Bounded local retries for a single leg that blows its planned share of the budget. */
const DEFAULT_MAX_LEG_ATTEMPTS = 2
/** How far over its planned length a leg may run before it is worth retrying. */
const DEFAULT_LEG_OVERSHOOT_TOLERANCE = 1.4
/**
 * How far past the straight line between its ends a leg has to run before it
 * looks like it went round something. Below this it is simply a long way to
 * a far-off corner, and a weaker penalty will not shorten it.
 */
const BUDGET_DETOUR_RATIO = 2
/** Degrees swung further round the loop on each local retry, so a retry is a genuinely different guess. */
const LEG_RETRY_BEARING_STEP_DEGREES = 20
/** Fraction the planned length is shortened by on each local retry. */
const LEG_RETRY_LENGTH_STEP = 0.2

/**
 * `purpose` is metrics only: it says which fixup is paying for this call, so a
 * high call count can be attributed rather than merely observed. A router that
 * ignores it behaves exactly as before.
 */
export type LegRouter = (
  points: LngLat[],
  customModel: ReturnType<typeof avoidanceCustomModel>,
  purpose?: RoutePurpose,
  /** Filled in by the router with what the call cost at the boundary; see metrics.ts. */
  boundary?: BoundaryTrace,
) => Promise<GraphHopperLeg>

export type RoutedLeg = GraphHopperLeg & {
  /** True when the leg was routed under the reduced penalty after a failure. */
  relaxed: boolean
  avoidanceAreaCount: number
}

export type RoutedCandidate = {
  /** Which attempt (starting bearing/direction) built this loop, for logging. */
  attemptId: string
  legs: RoutedLeg[]
  coordinates: LngLat[]
  steps: GraphHopperStep[]
  distanceMeters: number
  durationSeconds: number
  legDistances: number[]
  /** Network edges of the joined walk, when every leg reported them. */
  edges?: EdgeSpan[]
}

export type SequentialRoutingOptions = {
  corridorHalfWidthMetres?: number
  startExclusionMetres?: number
  strongPriority?: number
  relaxedPriority?: number
  /**
   * Abandon a candidate as soon as it is hopeless, rather than paying for the
   * remaining legs. Distance overshoot is the cheapest signal we have.
   */
  abandonAboveMetres?: number
  /**
   * The length beyond which a single leg is no longer shaping a loop but being
   * dictated to by the avoidance penalty.
   */
  legBudgetMetres?: number
  /** See JOIN_TURN_THRESHOLD_DEGREES. Overridable for the tuning panel only. */
  joinTurnThresholdDegrees?: number
  /** See WAYPOINT_PULLBACK_SCALE. Overridable for the tuning panel only. */
  waypointPullbackScale?: number
  /** How this leg's own first call is attributed in metrics. Fixups keep their own tags. */
  basePurpose?: RoutePurpose
  /** See AlgorithmFlags.budgetDetourGate. */
  budgetDetourGate?: boolean
  /** See AlgorithmFlags.pullbackTurnOnly. */
  pullbackTurnOnly?: boolean
  /** See AlgorithmFlags.pullbackReusesPrevious. */
  pullbackReusesPrevious?: boolean
  /** See AlgorithmFlags.backtrackNeedsBudgetToo. */
  backtrackNeedsBudgetToo?: boolean
  /** See AlgorithmFlags.keepBestLegAttempt. */
  keepBestLegAttempt?: boolean
  /** See AlgorithmFlags.budgetOncePerLeg. */
  budgetOncePerLeg?: boolean
  /**
   * Shared across the attempts at one leg, so a later attempt can see what the
   * first one's cheaper reroute came to. Set by `attemptLeg`, which is the only
   * thing that knows where one leg's attempts begin and end.
   */
  budgetLatch?: { relaxedHelped: boolean }
  /**
   * Told whenever a speculative reroute finishes, and whether its result was
   * kept. A fix-up that is attempted far more often than it is kept is paying
   * for information rather than for a better walk.
   */
  onFixup?: (kind: FixupKind, kept: boolean) => void
  signal?: AbortSignal
}

export type BuildLoopOptions = SequentialRoutingOptions & {
  /**
   * Ground to treat as already walked before the first leg is routed.
   *
   * Used by a repair to hand the builder the stretch a previous attempt
   * doubled back on, so the rebuild is pushed off it the same way a later leg
   * is pushed off an earlier one — one mechanism, not a second one. It is a
   * penalty, not a prohibition: where there is genuinely no other way, the
   * rebuild walks it again and is judged on that as before.
   */
  preAvoidGeometries?: LngLat[][]
  /** See DEFAULT_CORNER_COUNT. */
  cornerCount?: number
  /** See DEFAULT_MAX_LEG_ATTEMPTS. */
  maxLegAttempts?: number
  /** See DEFAULT_LEG_OVERSHOOT_TOLERANCE. */
  legOvershootTolerance?: number
}

type LegAttemptResult = { leg: GraphHopperLeg; relaxed: boolean; areas: Feature<Polygon>[] }

/**
 * Route one leg, with the fixups that belong to a single leg: a relaxed retry
 * if it fails outright, a cheaper reroute if the avoidance penalty made it
 * too long, and a reroute around a short dead-end branch if one turns up
 * inside the leg's own path. Returns undefined when the leg cannot be routed
 * at all.
 */
export async function routeLegAttempt(
  route: LegRouter,
  start: LngLat,
  walked: LngLat[][],
  fromPoint: LngLat,
  toPoint: LngLat,
  options: SequentialRoutingOptions = {},
): Promise<LegAttemptResult | undefined> {
  return withImpliedAttemptScope(() => routeLegAttemptInScope(route, start, walked, fromPoint, toPoint, options))
}

async function routeLegAttemptInScope(
  route: LegRouter,
  start: LngLat,
  walked: LngLat[][],
  fromPoint: LngLat,
  toPoint: LngLat,
  options: SequentialRoutingOptions,
): Promise<LegAttemptResult | undefined> {
  const areas: Feature<Polygon>[] = walked.length
    ? buildAvoidanceAreas(walked, start, {
        halfWidthMetres: options.corridorHalfWidthMetres,
        startExclusionMetres: options.startExclusionMetres,
      })
    : []
  const pair: LngLat[] = [fromPoint, toPoint]
  noteCall({ askMetres: Math.round(haversine(fromPoint, toPoint)), areas: areas.length })

  let leg: GraphHopperLeg | undefined
  let relaxed = false
  try {
    leg = await route(pair, avoidanceCustomModel(areas, options.strongPriority ?? AVOID_PRIORITY), options.basePurpose ?? 'leg')
  } catch (error) {
    if (!(error instanceof GraphHopperError) || error.kind === 'transport') throw error
    // One retry for this leg only, still penalised, just less absolutely.
    if (!areas.length) return undefined
    relaxed = true
    try {
      leg = await route(pair, avoidanceCustomModel(areas, options.relaxedPriority ?? RELAXED_AVOID_PRIORITY), 'leg-relaxed')
    } catch (retryError) {
      if (!(retryError instanceof GraphHopperError) || retryError.kind === 'transport') throw retryError
      return undefined
    }
  }

  // GraphHopper never *refuses* a penalised corridor — it walks round it. In a
  // dense grid "round it" is the next street; on a single road up a valley it
  // can be six kilometres to dodge nine hundred metres, and the loop comes
  // back at twice the length asked for and is thrown away for it. So the one
  // retry each leg gets is spent here too, not only on an outright failure.
  // A leg only gets shorter under a weaker penalty if the penalty is what
  // made it long. One that runs close to the straight line between its ends
  // did not go round anything, and rerouting it is two-thirds likely to come
  // back with the same answer at the cost of a call.
  const detoursRoundSomething = !options.budgetDetourGate
    || leg.distanceMeters > haversine(fromPoint, toPoint) * BUDGET_DETOUR_RATIO
  const budgetWorthAsking = !options.budgetOncePerLeg || (options.budgetLatch?.relaxedHelped ?? true)
  if (!relaxed && areas.length && detoursRoundSomething && budgetWorthAsking && options.legBudgetMetres && leg.distanceMeters > options.legBudgetMetres) {
    noteCall({
      budgetMetres: Math.round(options.legBudgetMetres),
      strongDistance: Math.round(leg.distanceMeters),
      straightLine: Math.round(haversine(fromPoint, toPoint)),
    })
    try {
      const cheaper = await route(pair, avoidanceCustomModel(areas, options.relaxedPriority ?? RELAXED_AVOID_PRIORITY), 'leg-budget')
      const better = cheaper.distanceMeters < leg.distanceMeters
      if (options.budgetLatch) options.budgetLatch.relaxedHelped = better
      traceDecision('leg-budget', { kept: better, before: Math.round(leg.distanceMeters), after: Math.round(cheaper.distanceMeters) })
      options.onFixup?.('leg-budget', better)
      if (better) {
        leg = cheaper
        relaxed = true
      }
    } catch (error) {
      if (!(error instanceof GraphHopperError) || error.kind === 'transport') throw error
      // Keep the strongly penalised leg: it routed, it is just a long way round.
    }
  }

  // A short dead end inside this leg's own path, not at either of its ends.
  // One retry, circling just the branch: worth it if the reroute actually
  // avoids it and does not cost more than it saves.
  const spike = findLegSpike(leg.coordinates)
  if (spike) {
    const spikeAreas = [...areas, buildSpikeAvoidanceArea(spike, SPIKE_AVOID_RADIUS_METRES)]
    try {
      const rerouted = await route(pair, avoidanceCustomModel(spikeAreas, relaxed ? (options.relaxedPriority ?? RELAXED_AVOID_PRIORITY) : (options.strongPriority ?? AVOID_PRIORITY)), 'spike')
      const stillSpiked = findLegSpike(rerouted.coordinates)
      const better = !stillSpiked && rerouted.distanceMeters < leg.distanceMeters * 1.5
      traceDecision('spike', { kept: better, before: Math.round(leg.distanceMeters), after: Math.round(rerouted.distanceMeters), stillSpiked: Boolean(stillSpiked) })
      options.onFixup?.('spike', better)
      if (better) {
        leg = rerouted
      }
    } catch (error) {
      if (!(error instanceof GraphHopperError) || error.kind === 'transport') throw error
      // Keep the branch: circling it found no way round either.
    }
  }

  return { leg, relaxed, areas }
}

type JoinPullbackResult = {
  /** The (possibly rerouted) current leg. */
  leg: GraphHopperLeg
  relaxed: boolean
  /** Set when the previous leg had to be undone and redone too. */
  revisedPrevious?: { leg: RoutedLeg; point: LngLat }
}

/**
 * The join a leg's *start* sits on is the previous leg's arrival, which is
 * already routed and committed. Catching a dead end here means undoing that
 * leg too: both legs meeting at the bad waypoint get re-routed around a
 * version of it pulled back toward the start, once.
 */
export async function applyJoinPullback(
  route: LegRouter,
  start: LngLat,
  /** Ground walked before the previous leg — not including it, since it may be redone. */
  walkedBeforePrevious: LngLat[][],
  previousPoint: LngLat,
  previous: RoutedLeg,
  /** The shared waypoint between the previous leg and this one. */
  original: LngLat,
  currentTarget: LngLat,
  leg: GraphHopperLeg,
  relaxed: boolean,
  options: SequentialRoutingOptions = {},
): Promise<JoinPullbackResult> {
  const turn = turnAngleDegrees(edgeBearing(previous.coordinates, false), edgeBearing(leg.coordinates, true))
  // The turn angle alone misses a dead end that sits a little way into either
  // leg rather than exactly on the join: the same branch a single leg's own
  // spike check looks for, just spanning the seam between two legs instead of
  // sitting inside one.
  // A short branch straddling the seam is already removed from the finished
  // walk for free by the tiny-spike trim, which reaches further than this
  // detector does. Paying two engine calls to route around one buys nothing
  // the walker would ever see.
  const boundarySpike = options.pullbackTurnOnly
    ? undefined
    : findLegSpike([...previous.coordinates, ...leg.coordinates])
  if (turn <= (options.joinTurnThresholdDegrees ?? JOIN_TURN_THRESHOLD_DEGREES) && !boundarySpike) {
    return { leg, relaxed }
  }

  const pullbackScale = options.waypointPullbackScale ?? WAYPOINT_PULLBACK_SCALE
  const wantedFromStart = haversine(start, original) * pullbackScale
  // Where the pulled-back corner goes, and whether getting there costs a call.
  const onPath = options.pullbackReusesPrevious ? pullbackOnPath(previous.coordinates, start, wantedFromStart) : undefined
  const pulledIn = onPath?.point ?? destination(start, wantedFromStart, bearingBetween(start, original))
  noteCall({
    ...(options.pullbackReusesPrevious ? {
      onPath: Boolean(onPath),
      keptFraction: onPath ? Math.round((onPath.index / (previous.coordinates.length - 1)) * 100) : undefined,
      wantedFromStart: Math.round(wantedFromStart),
      gotFromStart: onPath ? Math.round(haversine(start, onPath.point)) : undefined,
      previousStartFromStart: Math.round(haversine(start, previousPoint)),
    } : {}),
    trigger: turn > (options.joinTurnThresholdDegrees ?? JOIN_TURN_THRESHOLD_DEGREES)
      ? (boundarySpike ? 'turn+spike' : 'turn')
      : 'spike',
    joinTurn: Math.round(turn),
    fromStart: Math.round(haversine(start, original)),
    moved: Math.round(haversine(original, pulledIn)),
    previousDistance: Math.round(previous.distanceMeters),
    currentDistance: Math.round(leg.distanceMeters),
  })
  const areasBeforePrevious = walkedBeforePrevious.length
    ? buildAvoidanceAreas(walkedBeforePrevious, start, {
        halfWidthMetres: options.corridorHalfWidthMetres,
        startExclusionMetres: options.startExclusionMetres,
      })
    : []
  try {
    const redonePrevious = onPath
      ? trimLegTo(previous, onPath.index)
      : await route(
        [previousPoint, pulledIn],
        avoidanceCustomModel(areasBeforePrevious, previous.relaxed ? (options.relaxedPriority ?? RELAXED_AVOID_PRIORITY) : (options.strongPriority ?? AVOID_PRIORITY)),
        'join-pullback',
      )
    const walkedWithRedone = [...walkedBeforePrevious, redonePrevious.coordinates]
    const areasForCurrent = buildAvoidanceAreas(walkedWithRedone, start, {
      halfWidthMetres: options.corridorHalfWidthMetres,
      startExclusionMetres: options.startExclusionMetres,
    })
    const redoneCurrent = await route(
      [pulledIn, currentTarget],
      avoidanceCustomModel(areasForCurrent, relaxed ? (options.relaxedPriority ?? RELAXED_AVOID_PRIORITY) : (options.strongPriority ?? AVOID_PRIORITY)),
      'join-pullback',
    )
    const redoneTurn = turnAngleDegrees(edgeBearing(redonePrevious.coordinates, false), edgeBearing(redoneCurrent.coordinates, true))
    const redoneSpike = findLegSpike([...redonePrevious.coordinates, ...redoneCurrent.coordinates])
    // Only keep the pulled-in point if it actually straightened the join, or
    // actually cleared the branch that sent us here; a still-sharp turn or
    // still-present branch would only be trading one dead end for another,
    // for the price of two extra requests.
    const better = redoneTurn < turn || Boolean(boundarySpike && !redoneSpike)
    traceDecision('join-pullback', {
      kept: better, joinTurn: Math.round(turn), redoneTurn: Math.round(redoneTurn),
      spikeCleared: Boolean(boundarySpike && !redoneSpike),
      before: Math.round(previous.distanceMeters + leg.distanceMeters),
      after: Math.round(redonePrevious.distanceMeters + redoneCurrent.distanceMeters),
    })
    options.onFixup?.('join-pullback', better)
    if (better) {
      return {
        leg: redoneCurrent,
        relaxed,
        revisedPrevious: { leg: { ...redonePrevious, relaxed: previous.relaxed, avoidanceAreaCount: areasBeforePrevious.length }, point: pulledIn },
      }
    }
  } catch (error) {
    if (!(error instanceof GraphHopperError) || error.kind === 'transport') throw error
    // Keep the dead-ending join: pulling the waypoint in found no way round either.
  }
  return { leg, relaxed }
}


/**
 * Where on an already-routed path to put a pulled-back corner.
 *
 * The corner is being moved toward the start, and the geometric rule says how
 * far: `pullbackScale` of its straight-line distance from the start. Nothing
 * says the point that rule names is anywhere a walker can stand, which is why
 * moving there costs a routing call to find out.
 *
 * The previous leg's own geometry is a list of places a walker demonstrably
 * can stand, every one of them already paid for. Taking the point on it whose
 * distance from the start is closest to what the rule asked for keeps the
 * rule's intent — a corner this much nearer home — and makes the leg that
 * arrives there a prefix of the leg we already have. Routing to a point on a
 * routed path returns that path's prefix; measured on the Isle of Man graph,
 * byte-identically, with GraphHopper's distance agreeing with its own geometry
 * to 0.015%. So the reroute would buy back exactly what is being trimmed.
 *
 * The path's own last point is never chosen — that is the corner we are trying
 * to move — and neither is its first, which is where the leg set off from.
 *
 * Two guards, and they are what make this a saving rather than a different
 * algorithm. A leg heading away from the start need never come as near it as
 * the rule asks — measured, that is half of all pullbacks — and the nearest
 * point it can offer is then its own beginning, which would collapse the leg
 * to nothing and hand the loop a corner it never asked for. So the point is
 * taken only when the path genuinely passes near the wanted reach, and only
 * when enough of the leg survives the trim. Everything else falls back to
 * routing the pulled-back leg exactly as before, at the price it always cost.
 */
const PULLBACK_REACH_TOLERANCE = 0.15
const PULLBACK_MIN_KEPT_FRACTION = 0.4

function pullbackOnPath(path: LngLat[], start: LngLat, wantedFromStart: number): { point: LngLat; index: number } | undefined {
  if (path.length < 3 || wantedFromStart <= 0) return undefined
  let bestIndex = -1
  let bestMiss = Infinity
  for (let index = 1; index < path.length - 1; index++) {
    const miss = Math.abs(haversine(start, path[index]) - wantedFromStart)
    if (miss < bestMiss) {
      bestMiss = miss
      bestIndex = index
    }
  }
  if (bestIndex < 0 || bestMiss > wantedFromStart * PULLBACK_REACH_TOLERANCE) return undefined
  const whole = pathLength(path)
  if (whole <= 0 || pathLength(path.slice(0, bestIndex + 1)) < whole * PULLBACK_MIN_KEPT_FRACTION) return undefined
  return { point: path[bestIndex], index: bestIndex }
}

/**
 * The leg that arrives at a pulled-back corner, taken from the leg that
 * arrived at the original one.
 *
 * Geometry is the prefix. Distance and duration are re-derived from that
 * geometry rather than scaled: GraphHopper's own distance is the same sum, and
 * scaling would let a leg whose speed varied along it report a length it never
 * had. Steps are kept while their interval fits, and the edge spans likewise,
 * so nothing downstream is handed an index past the end of the line.
 */
function trimLegTo(leg: GraphHopperLeg, index: number): GraphHopperLeg {
  const coordinates = leg.coordinates.slice(0, index + 1)
  const distanceMeters = pathLength(coordinates)
  return {
    ...leg,
    coordinates,
    distanceMeters,
    durationSeconds: leg.distanceMeters > 0 ? leg.durationSeconds * (distanceMeters / leg.distanceMeters) : leg.durationSeconds,
    steps: leg.steps.filter(step => step.endIndex === undefined || step.endIndex <= index),
    edges: leg.edges?.filter(span => span.endIndex <= index),
    roadClasses: leg.roadClasses?.filter(span => span.endIndex <= index),
    // The engine settled what it settled for the whole leg. Attributing a
    // share of it to a prefix would invent a measurement, so the count stays
    // with the call that earned it and this leg reports none.
    visitedNodes: undefined,
  }
}

/**
 * Build one loop, live: `cornerCount` legs turning steadily one way round the
 * compass, then a closing leg back to the start. Each leg aims at an even
 * share of whatever distance budget is left; if the street network makes it
 * overrun that share badly, the leg gets a bounded number of retries with a
 * shorter reach and a bearing swung further round, rather than the whole
 * attempt being discarded for one bad leg.
 *
 * Returns undefined when the loop cannot be closed at all.
 */
export async function buildLoopIncrementally(
  start: LngLat,
  targetMetres: number,
  initialBearing: number,
  direction: LoopDirection,
  route: LegRouter,
  options: BuildLoopOptions = {},
): Promise<RoutedCandidate | undefined> {
  const cornerCount = options.cornerCount ?? DEFAULT_CORNER_COUNT
  const maxLegAttempts = options.maxLegAttempts ?? DEFAULT_MAX_LEG_ATTEMPTS
  const overshootTolerance = options.legOvershootTolerance ?? DEFAULT_LEG_OVERSHOOT_TOLERANCE
  const turn = direction === 'clockwise' ? 1 : -1

  const points: LngLat[] = [start]
  const legs: RoutedLeg[] = []
  // Seeded ground is never popped, because it was never pushed by a leg: the
  // undo in the join fix-up below only ever removes what this loop added.
  const walked: LngLat[][] = [...(options.preAvoidGeometries ?? [])]
  let running = 0
  let heading = initialBearing

  for (let step = 0; step <= cornerCount; step++) {
    const stepOutcome = await withLegScope({ legIndex: step, cornerCount }, async () => {
      options.signal?.throwIfAborted()
      const closing = step === cornerCount
      const legsLeft = cornerCount - step + 1
      const plannedLength = Math.max(0, targetMetres - running) / legsLeft
      const from = points[points.length - 1]

      const attempted = await attemptLeg({
        route,
        start,
        walked,
        from,
        previous: legs[legs.length - 1],
        pickTarget: attempt => closing
          ? start
          : destination(
              from,
              plannedLength * Math.max(0.4, 1 - attempt * LEG_RETRY_LENGTH_STEP),
              normaliseBearing(heading + attempt * turn * LEG_RETRY_BEARING_STEP_DEGREES),
            ),
        plannedLength: closing ? undefined : plannedLength,
        maxAttempts: maxLegAttempts,
        overshootTolerance,
        options,
      })
      if (!attempted) return undefined

      points.push(attempted.target)
      let finalLeg = attempted.leg
      let finalRelaxed = attempted.relaxed

      // Every waypoint but the first and last is somebody's arrival and
      // somebody's departure; check the seam this leg's start sits on.
      if (legs.length > 0) {
        const previous = legs[legs.length - 1]
        const outcome = await applyJoinPullback(
          route,
          start,
          walked.slice(0, -1),
          points[points.length - 3],
          previous,
          points[points.length - 2],
          attempted.target,
          finalLeg,
          finalRelaxed,
          options,
        )
        finalLeg = outcome.leg
        finalRelaxed = outcome.relaxed
        if (outcome.revisedPrevious) {
          running -= previous.distanceMeters
          legs.pop()
          walked.pop()
          legs.push(outcome.revisedPrevious.leg)
          walked.push(outcome.revisedPrevious.leg.coordinates)
          running += outcome.revisedPrevious.leg.distanceMeters
          points[points.length - 2] = outcome.revisedPrevious.point
        }
      }

      running += finalLeg.distanceMeters
      if (options.abandonAboveMetres && running > options.abandonAboveMetres) return undefined
      legs.push({ ...finalLeg, relaxed: finalRelaxed, avoidanceAreaCount: walked.length })
      walked.push(finalLeg.coordinates)
      // Ready for the leg after next; the closing leg never needs a heading.
      if (!closing) heading = normaliseBearing(heading + (turn * 360) / (cornerCount + 1))
      return 'continued' as const
    })
    if (stepOutcome === undefined) return undefined
  }

  const joined = joinAndTrimLegs(legs)
  return {
    attemptId: `${direction === 'clockwise' ? 'cw' : 'ccw'}-${Math.round(initialBearing)}`,
    legs,
    ...joined,
    legDistances: legs.map(leg => leg.distanceMeters),
  }
}

/**
 * Stitch legs into one walk and cut the noise out of it — the two steps that
 * together turn a set of routed legs into something a walker would recognise.
 *
 * Every builder that assembles legs needs both. Joining without trimming
 * leaves the short dead-end branches that the ground genuinely offers no way
 * round, and the quality engine then refuses the whole walk for a forty-metre
 * duck into a driveway. That is what happened to waypoint walks, in both
 * generators, for as long as they have existed: they joined and did not trim,
 * and `out-and-back-spur` threw out twenty of every twenty-four.
 */
export const joinAndTrimLegs = (
  legs: Parameters<typeof joinLegGeometries>[0],
  /**
   * Places the finished walk must still pass once the trim has had its way
   * with it.
   *
   * The walker's own pins, and only those. A generated shaping point is ours
   * to move and ours to trim round — that is the whole purpose of the trim —
   * but a pin is the problem statement. Routing through a pin and then
   * splicing the section containing it out of the geometry offers a walk that
   * does not go where it was asked to go, and nothing downstream would notice:
   * the engine was asked correctly, so every check on what we *asked for*
   * passes.
   */
  protectedPoints: LngLat[] = [],
) => alignStepsWithGeometry(trimTinySpikes(joinLegGeometries(legs), protectedPoints))

/**
 * GraphHopper's instruction intervals point into the route line. Trimming a
 * short out-and-back changes that line, so retaining the engine's original
 * per-step distances makes every later turn appear too far away to a client
 * that (correctly) measures its position on the final line. Derive each
 * instruction's walked distance from that final geometry: then progress and
 * turn boundaries share one ruler. The
 * route's advertised distance remains GraphHopper's engine measurement,
 * which is used elsewhere for route-selection and tolerances.
 */
function alignStepsWithGeometry(joined: {
  coordinates: LngLat[]
  steps: GraphHopperStep[]
  distanceMeters: number
  durationSeconds: number
  edges?: EdgeSpan[]
}): typeof joined {
  const cumulative = [0]
  for (let index = 1; index < joined.coordinates.length; index++) {
    cumulative.push(cumulative[index - 1] + haversine(joined.coordinates[index - 1], joined.coordinates[index]))
  }
  const steps = joined.steps.map(step => {
    const start = step.startIndex
    const end = step.endIndex
    // An arrival is deliberately zero length. A malformed or unavailable
    // interval cannot be safely remapped, so leave that one untouched rather
    // than inventing a position for its instruction.
    if (step.distanceMeters <= 0 || start === undefined || end === undefined
      || start < 0 || end <= start || end >= cumulative.length) return step
    return { ...step, distanceMeters: cumulative[end] - cumulative[start] }
  })
  return { ...joined, steps }
}

/**
 * Cut any backtrack under TINY_SPIKE_ROUND_TRIP_METRES straight out of the
 * finished geometry: find a later point close in space and short in the path
 * back to an earlier one, *and* confirm the walk actually reversed there
 * rather than merely passing nearby — a tight corner, a cul-de-sac turning
 * circle and a narrow zigzag street all bring two points within a few metres
 * of each other without either being backtracking — then splice out
 * everything between them. This runs after every other attempt to avoid a
 * spike during construction, as the fallback for the ground that genuinely
 * offers no other way for one short stretch — at this size, the honest fix
 * is not to show it, not to keep failing to route round it.
 *
 * A detour off a detour — into a cul-de-sac, then further into a driveway
 * off it, then all the way back out — is longer round trip than the window
 * allows in one look, even though each of its two nested turn-arounds is
 * short on its own. One pass resolves the inner one; a repeat resolves what
 * is left of the outer one now that the ground between its own ends is
 * shorter. Bounded by the geometry only shrinking, never a fixed count.
 */
function trimTinySpikes(joined: {
  coordinates: LngLat[]
  steps: GraphHopperStep[]
  distanceMeters: number
  durationSeconds: number
  edges?: EdgeSpan[]
}, protectedPoints: LngLat[] = []): typeof joined {
  const originalDistanceMeters = joined.distanceMeters
  let current = joined
  for (;;) {
    const next = trimTinySpikesOnce(current, protectedPoints)
    if (next.coordinates.length === current.coordinates.length) return next
    if (originalDistanceMeters - next.distanceMeters > MAX_TOTAL_TRIM_METRES) return current
    current = next
  }
}

function trimTinySpikesOnce(joined: {
  coordinates: LngLat[]
  steps: GraphHopperStep[]
  distanceMeters: number
  durationSeconds: number
  edges?: EdgeSpan[]
}, protectedPoints: LngLat[] = []): typeof joined {
  const { coordinates, steps, distanceMeters, durationSeconds } = joined
  const n = coordinates.length
  // Found again on every pass rather than carried through the splice and
  // remapped alongside the steps and edges. A pin is never what gets trimmed,
  // so it is still exactly where it was, and looking it up again cannot go
  // stale the way a carried index quietly can.
  const protectedIndices = protectedIndexesFor(coordinates, protectedPoints)
  const keep = new Array<boolean>(n).fill(true)
  const anchorFor = Array.from({ length: n }, (_, index) => index)
  const reversalLimit = Math.cos((SPIKE_ANGLE_DEGREES * Math.PI) / 180)

  let i = 0
  while (i < n - 2) {
    if (!keep[i]) { i++; continue }
    // The segment leaving i, compared against the segment arriving at each
    // candidate j: for a genuine out-and-back these point opposite ways,
    // because leaving j's match reverses however i was left. A path merely
    // curving close to itself — a tight corner, a turning circle — keeps
    // heading roughly the same way through both, and is left alone.
    const leavingI = rawDirection(coordinates[i], coordinates[i + 1])
    let pathMetres = 0
    let spliceAt = -1
    // Splicing at j removes everything from i + 1 to j, so the first pin
    // lying ahead of i is a ceiling on how far this splice may reach. A walk
    // that no longer passes a place the walker chose is not the walk that was
    // asked for, however tidy the geometry reads afterwards — and a pin at
    // the tip of a short cul-de-sac is exactly the shape this trim is looking
    // for, so this is the common case rather than the corner one.
    const firstProtectedAhead = protectedIndices.find(index => index > i) ?? Infinity
    // The last point is where the walk closes back on the start; it is
    // never a spike to be spliced away, whatever it happens to sit near.
    for (let j = i + 2; j < n - 1 && j < firstProtectedAhead; j++) {
      pathMetres += haversine(coordinates[j - 1], coordinates[j])
      if (pathMetres > TINY_SPIKE_ROUND_TRIP_METRES) break
      if (haversine(coordinates[i], coordinates[j]) >= TINY_SPIKE_MATCH_METRES) continue
      const arrivingJ = rawDirection(coordinates[j - 1], coordinates[j])
      if (!leavingI || !arrivingJ) continue
      if (leavingI[0] * arrivingJ[0] + leavingI[1] * arrivingJ[1] < reversalLimit) spliceAt = j
    }
    if (spliceAt > i) {
      for (let k = i + 1; k <= spliceAt; k++) { keep[k] = false; anchorFor[k] = i }
      i = spliceAt + 1
    } else {
      i++
    }
  }
  if (keep.every(Boolean)) return joined

  const newIndexOf = new Array<number>(n)
  let cursor = 0
  for (let index = 0; index < n; index++) if (keep[index]) newIndexOf[index] = cursor++
  const remapIndex = (index: number) => newIndexOf[keep[index] ? index : anchorFor[index]]

  const newSteps: GraphHopperStep[] = []
  for (const step of steps) {
    if (step.startIndex === undefined || step.endIndex === undefined) { newSteps.push(step); continue }
    const startIndex = remapIndex(step.startIndex)
    const endIndex = remapIndex(step.endIndex)
    // Collapsed entirely into a trimmed spike: the instruction it described no longer exists.
    if (endIndex <= startIndex && step.startIndex !== step.endIndex) continue
    newSteps.push({ ...step, startIndex, endIndex: Math.max(startIndex, endIndex) })
  }

  // Measured from the geometry itself, not attributed step by step: a step
  // spanning far more ground than the one spike inside it would otherwise
  // hide almost all of what was actually cut.
  // Edge spans index the line, so trimming has to move them with it. A span
  // that lay entirely inside a trimmed spike describes ground the walk no
  // longer covers, and is dropped rather than collapsed onto a point — the
  // walk did not walk it, so it must not count as having walked it.
  const newEdges: EdgeSpan[] = []
  for (const span of joined.edges ?? []) {
    const startIndex = remapIndex(span.startIndex)
    const endIndex = remapIndex(span.endIndex)
    if (endIndex > startIndex) newEdges.push({ id: span.id, startIndex, endIndex })
  }

  const newCoordinates = coordinates.filter((_, index) => keep[index])
  const removedMetres = Math.max(0, pathLength(coordinates) - pathLength(newCoordinates))
  const trimmedFraction = distanceMeters > 0 ? removedMetres / distanceMeters : 0
  return {
    coordinates: newCoordinates,
    steps: newSteps,
    distanceMeters: Math.max(0, distanceMeters - removedMetres),
    durationSeconds: durationSeconds * (1 - trimmedFraction),
    ...(joined.edges ? { edges: newEdges } : {}),
  }
}

/**
 * Where on the joined line each place the walker insisted on actually falls.
 *
 * A pin is an end of the leg that arrives at it, so it is one of these
 * vertices rather than merely near one; the nearest-vertex search is for the
 * metre or two of snapping between what was asked for and what the network
 * offered, not for a genuine search.
 *
 * Sorted, so the scan above can ask for the first one ahead of a point and
 * stop looking.
 */
function protectedIndexesFor(coordinates: LngLat[], points: LngLat[]): number[] {
  if (!points.length) return []
  const found = new Set<number>()
  for (const point of points) {
    let bestIndex = -1
    let bestMetres = Infinity
    for (let index = 0; index < coordinates.length; index++) {
      const away = haversine(coordinates[index], point)
      if (away < bestMetres) {
        bestMetres = away
        bestIndex = index
      }
    }
    if (bestIndex >= 0) found.add(bestIndex)
  }
  return [...found].sort((a, b) => a - b)
}

/**
 * Try a leg up to `maxAttempts + 1` times. A corner leg that comes back
 * within `overshootTolerance` of its planned length (and the leg budget, if
 * any) is accepted immediately; otherwise the next attempt aims shorter and
 * swings the bearing further round, a genuinely different guess rather than
 * the same request repeated. The closing leg (no planned length) is never
 * retried — there is only one way back to the start.
 */
async function attemptLeg(params: {
  route: LegRouter
  start: LngLat
  walked: LngLat[][]
  from: LngLat
  /** The already-committed leg this one's start sits on, if any. */
  previous?: RoutedLeg
  pickTarget: (attempt: number) => LngLat
  plannedLength: number | undefined
  maxAttempts: number
  overshootTolerance: number
  options: SequentialRoutingOptions
}): Promise<{ target: LngLat; leg: GraphHopperLeg; relaxed: boolean } | undefined> {
  let best: { target: LngLat; leg: GraphHopperLeg; relaxed: boolean } | undefined
  let bestMiss = Infinity
  const attempts = params.plannedLength === undefined ? 0 : params.maxAttempts
  // One latch for the whole leg, so its attempts can tell each other what the
  // cheaper reroute was worth here rather than each finding out for itself.
  const options = params.options.budgetOncePerLeg
    ? { ...params.options, budgetLatch: { relaxedHelped: true } }
    : params.options
  for (let attempt = 0; attempt <= attempts; attempt++) {
    const target = params.pickTarget(attempt)
    const outcome = await withAttemptScope(
      { legAttempt: attempt, plannedMetres: params.plannedLength === undefined ? undefined : Math.round(params.plannedLength) },
      () => routeLegAttempt(params.route, params.start, params.walked, params.from, target, options),
    )
    if (!outcome) continue
    // Which answer to keep once the retries run out. Overwriting on every
    // attempt keeps the last one, which is the shortest and most swung guess
    // the leg made rather than its closest fit.
    const miss = params.plannedLength === undefined ? 0 : Math.abs(outcome.leg.distanceMeters - params.plannedLength)
    if (!params.options.keepBestLegAttempt || best === undefined || miss < bestMiss) {
      best = { target, leg: outcome.leg, relaxed: outcome.relaxed }
      bestMiss = miss
    }
    if (params.plannedLength === undefined) return best
    const fitsBudget = outcome.leg.distanceMeters <= params.plannedLength * params.overshootTolerance
      && (!params.options.legBudgetMetres || outcome.leg.distanceMeters <= params.options.legBudgetMetres)
    // A leg that shares ground with the one before it, but not enough of it
    // to be a real feature, is a corner that turned out to be a dead end —
    // worth a different aim, exactly like a leg that blew its budget, rather
    // than accepted and left for the reactive join fix-up further down.
    const backtrack = params.previous ? overlapMetres(params.previous.coordinates, outcome.leg.coordinates) : 0
    // Retrying for a short backtrack alone was measured to clear it 15 times in
    // 256 on the production corpus: a bearing swung twenty degrees and a reach
    // a fifth shorter is not what moves a corner out of a dead end. The join
    // fix-up below is, and it still runs. See AlgorithmFlags.
    const isShortBacktrack = backtrack > 0 && backtrack < MIN_BACKTRACK_METRES
      && !(params.options.backtrackNeedsBudgetToo && fitsBudget)
    traceDecision('leg-attempt', {
      kept: fitsBudget && !isShortBacktrack,
      attempt,
      planned: params.plannedLength === undefined ? undefined : Math.round(params.plannedLength),
      got: Math.round(outcome.leg.distanceMeters),
      fitsBudget,
      shortBacktrack: isShortBacktrack,
      last: attempt === attempts,
    })
    if (fitsBudget && !isShortBacktrack) return best
  }
  return best
}

/** How much of `a` runs along `b`, checked both ways so direction of travel never hides an overlap. */
function overlapMetres(a: LngLat[], b: LngLat[]): number {
  const ignoreStart = 20
  return Math.max(sharedCorridorMetres(a, b, ignoreStart).metres, sharedCorridorMetres(b, a, ignoreStart).metres)
}

/**
 * Stitch the legs into one walk.
 *
 * Consecutive legs meet at the same snapped point, so the duplicate is dropped;
 * the "arrive at destination" each leg ends with is dropped too, except on the
 * last, where arriving is the point. Step point indices are rebased onto the
 * joined line so the walk screen can still find a turn's position.
 */
export function joinLegGeometries(legs: Array<Pick<GraphHopperLeg, 'coordinates' | 'steps' | 'distanceMeters' | 'durationSeconds' | 'edges'>>): {
  coordinates: LngLat[]
  steps: GraphHopperStep[]
  distanceMeters: number
  durationSeconds: number
  edges?: EdgeSpan[]
} {
  const coordinates: LngLat[] = []
  const steps: GraphHopperStep[] = []
  const edges: EdgeSpan[] = []
  // One leg without edge details makes the whole joined walk unmeasurable on
  // the network: a half-covered edge list would silently under-report
  // retracing, which is worse than falling back to geometry for this route.
  let everyLegHasEdges = true
  let distanceMeters = 0
  let durationSeconds = 0

  legs.forEach((leg, legIndex) => {
    const joins = coordinates.length > 0 && samePoint(coordinates[coordinates.length - 1], leg.coordinates[0])
    // Index of this leg's first point once it is in the joined line.
    const offset = joins ? coordinates.length - 1 : coordinates.length
    coordinates.push(...(joins ? leg.coordinates.slice(1) : leg.coordinates))

    const last = legIndex === legs.length - 1
    for (const step of leg.steps) {
      const arrival = step.sign === 4 || step.sign === 5
      if (arrival && !last) continue
      steps.push({
        ...step,
        startIndex: step.startIndex === undefined ? undefined : step.startIndex + offset,
        endIndex: step.endIndex === undefined ? undefined : step.endIndex + offset,
      })
    }
    if (leg.edges?.length) {
      for (const span of leg.edges) {
        edges.push({ id: span.id, startIndex: span.startIndex + offset, endIndex: span.endIndex + offset })
      }
    } else {
      everyLegHasEdges = false
    }

    distanceMeters += leg.distanceMeters
    durationSeconds += leg.durationSeconds
  })

  return { coordinates, steps, distanceMeters, durationSeconds, ...(everyLegHasEdges && edges.length ? { edges } : {}) }
}

const samePoint = (a: LngLat, b: LngLat) => Math.abs(a[0] - b[0]) < 1e-9 && Math.abs(a[1] - b[1]) < 1e-9

/**
 * The direction a leg is travelling right at one end of it — the last stretch
 * before it arrives, or the first stretch after it departs — rather than the
 * bearing of the whole leg, which a winding street would blur into something
 * meaningless.
 */
function edgeBearing(coordinates: LngLat[], atStart: boolean, windowMetres = EDGE_BEARING_WINDOW_METRES): number {
  if (coordinates.length < 2) return 0
  if (atStart) {
    let index = 1
    while (index < coordinates.length - 1 && haversine(coordinates[0], coordinates[index]) < windowMetres) index++
    return bearingBetween(coordinates[0], coordinates[index])
  }
  let index = coordinates.length - 2
  while (index > 0 && haversine(coordinates[coordinates.length - 1], coordinates[index]) < windowMetres) index--
  return bearingBetween(coordinates[index], coordinates[coordinates.length - 1])
}

/** The angle between two bearings, 0-180 degrees either way round the compass. */
function turnAngleDegrees(a: number, b: number): number {
  const diff = Math.abs(normaliseBearing(a) - normaliseBearing(b))
  return diff > 180 ? 360 - diff : diff
}

/**
 * The tip of a short dead-end branch in `coordinates`, if there is one: a
 * sharp reversal (further round than a switchback lane manages) whose two
 * arms end up back within a street's width of each other, close enough
 * together that it can only be this leg doubling back on itself rather than
 * the walk continuing round a bend.
 */
function findLegSpike(coordinates: LngLat[]): LngLat | undefined {
  const { samples } = resample(coordinates, SPIKE_SAMPLE_METRES)
  const window = SPIKE_WINDOW_SAMPLES
  const limit = Math.cos((SPIKE_ANGLE_DEGREES * Math.PI) / 180)
  for (let i = window; i < samples.length - window; i++) {
    const before = samples[i - window].mid
    const here = samples[i].mid
    const after = samples[i + window].mid
    const incoming = unit(before, here)
    const outgoing = unit(here, after)
    if (!incoming || !outgoing) continue
    if (incoming[0] * outgoing[0] + incoming[1] * outgoing[1] > limit) continue
    if (distanceBetween(before, after) > SPIKE_RETURN_METRES) continue
    return pointAtDistance(coordinates, samples[i].along)
  }
  return undefined
}

function unit(from: [number, number], to: [number, number]): [number, number] | undefined {
  const dx = to[0] - from[0]
  const dy = to[1] - from[1]
  const length = Math.hypot(dx, dy)
  if (length < 1e-6) return undefined
  return [dx / length, dy / length]
}

/** Direction between two raw lng/lat points, longitude scaled flat by local latitude — good enough over a few tens of metres. */
function rawDirection(from: LngLat, to: LngLat): [number, number] | undefined {
  const scale = Math.cos((from[1] * Math.PI) / 180)
  return unit([from[0] * scale, from[1]], [to[0] * scale, to[1]])
}

/** The point `targetMetres` along `coordinates`, interpolated between the raw vertices either side of it. */
function pointAtDistance(coordinates: LngLat[], targetMetres: number): LngLat {
  let travelled = 0
  for (let i = 1; i < coordinates.length; i++) {
    const segment = haversine(coordinates[i - 1], coordinates[i])
    if (travelled + segment >= targetMetres || i === coordinates.length - 1) {
      const t = segment > 0 ? Math.min(1, Math.max(0, (targetMetres - travelled) / segment)) : 0
      return [
        coordinates[i - 1][0] + (coordinates[i][0] - coordinates[i - 1][0]) * t,
        coordinates[i - 1][1] + (coordinates[i][1] - coordinates[i - 1][1]) * t,
      ]
    }
    travelled += segment
  }
  return coordinates[coordinates.length - 1]
}
