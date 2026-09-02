import {
  boundingBoxSides,
  compactness as isoperimetricCompactness,
  distanceBetween,
  haversine,
  resample,
  type LngLat,
  type Sample,
} from './geo.js'
import { isUTurnSign } from '../graphhopper.js'
import { edgeRepeatReport, type EdgeTraversal } from './edges.js'

/**
 * Route quality.
 *
 * Every candidate is judged on its geometry before anyone sees it. The
 * measurements here are the difference between "a loop" and "a walk that
 * happens to end where it started": a route can hit the requested distance
 * exactly, return to the door, and still be a long path walked twice.
 *
 * Geometry is the source of truth throughout. GraphHopper's own instructions
 * are consulted as a supporting signal for U-turns, but a router that fails to
 * call a turn-around a turn-around must not be able to smuggle one past us.
 */

// --- Thresholds. A candidate failing any of these is not offered at all. ----
export const MAX_DISTANCE_ERROR = 0.12
export const MAX_DURATION_ERROR = 0.15
export const MAX_REPEATED_FRACTION = 0.12
/**
 * A short backtrack out in the middle of a walk is not a lane in from the
 * road — it is a corner that turned out to be a dead end, given up on rather
 * than routed around. A long one is the opposite: nobody accidentally walks
 * 500 m up a promenade and back, so at that length it can only be a real
 * feature — a pier, a headland, a canal towpath with no second path back —
 * worth keeping rather than a defect worth hiding. So this is a *minimum*:
 * backtracking shorter than it is always held against a walk; at or past it,
 * never on length alone.
 */
export const MIN_BACKTRACK_METRES = 500
/**
 * How much of the walk's own length its longest backtrack has to be before
 * the walk is treated as fundamentally a there-and-back — a promenade, not a
 * loop with an incidental spur — and excused the checks below that assume a
 * proper enclosing shape.
 */
export const OUT_AND_BACK_SHARE_THRESHOLD = 0.3
/**
 * The doorstep stub is judged the opposite way round: a short one is the
 * shared pavement every loop has, a long one turns the whole walk into a
 * there-and-back with a loop stuck on the end. Proportional the same way a
 * lane in from the road matters less on a long day out than a short town
 * loop.
 */
export const START_STUB_SHARE = 0.04
export const spurLimitMetres = (routeMetres: number, floorMetres: number, share = START_STUB_SHARE) =>
  Math.max(floorMetres, routeMetres * share)
export const MAX_U_TURNS = 1
export const MAX_LEG_SHARE = 0.45
/**
 * Applies to the outer-ring legs only — A→B and B→C — not to the spokes out to
 * the ring and back. Where the first waypoint snaps to a street near the door,
 * the spoke is legitimately short, and holding that against the walk threw out
 * some of the best loops the generator made. A ring that has collapsed to a
 * point fails on shape instead, which is what actually makes it a bad walk.
 */
export const MIN_LEG_SHARE = 0.08
export const MAX_BOUNDING_BOX_RATIO = 4.5
/**
 * How much ground the walk actually encloses, against a circle of the same
 * length. A walk can hit the distance exactly, never repeat a street and still
 * be a scribble: out along one road, back along the next one over, threaded
 * through the same few blocks. It reads as a loop to every other measure here
 * and as a mess to anyone looking at the map.
 *
 * The ring this generator builds from — a spoke out, two sides of a triangle,
 * a spoke back — scores about 0.37 when the streets cooperate perfectly, so
 * the bar has to sit below that. Measured against routes drawn out and looked
 * at: below 0.20 is a tangle, 0.26 and up is a walk. 0.21-0.25 was being
 * spent rejecting real neighbourhood loops in tightly-streeted suburbs — a
 * walk crossing eight named streets, not two roads threaded back and forth —
 * so the bar sits at the tangle line itself rather than a margin above it.
 */
export const MIN_COMPACTNESS = 0.2
/**
 * The stub at the door: how far the walk goes out before it commits to the
 * circuit, and comes back along afterwards. A few tens of metres is the shared
 * pavement every loop has. Two hundred is a there-and-back with a loop on the
 * end, and it is the single thing that most makes a drawn route look wrong.
 */
export const MAX_START_STUB_METRES = 150
export const ENDPOINT_TOLERANCE_METRES = 40

// --- Repeat detection tuning ------------------------------------------------
/** Route geometry is compared at this resolution. */
export const SAMPLE_METRES = 15
/** Two stretches this close together are on the same ground. */
export const CORRIDOR_MATCH_METRES = 17.5
/** Shorter than this and it is a crossing, not a shared corridor. */
export const MIN_SHARED_RUN_METRES = 37.5
/** Stretches nearer than this along the route are simply the route continuing. */
export const NON_ADJACENT_METRES = 50
/** The shared start and finish of any loop is not retracing. */
export const START_IGNORE_METRES = 75
/** Beyond this angle two stretches are crossing, not running together. */
const PARALLEL_COSINE = Math.cos((35 * Math.PI) / 180)
/** Walking the same street back the other way is the worse failure. */
export const REVERSE_OVERLAP_WEIGHT = 1.5

export type SharedRun = { metres: number; reversed: boolean; alongStart: number }

export type RepeatReport = {
  repeatedMeters: number
  repeatedPercent: number
  /** Reverse-direction overlap counted at a premium, for scoring only. */
  weightedRepeatedMeters: number
  runs: SharedRun[]
  longestReverseRunMetres: number
}

type IndexedSamples = { samples: Sample[]; cell: number; grid: Map<string, number[]> }

const key = (x: number, y: number) => `${x},${y}`

function index(samples: Sample[], cellMetres: number): IndexedSamples {
  const grid = new Map<string, number[]>()
  samples.forEach((sample, i) => {
    const k = key(Math.floor(sample.mid[0] / cellMetres), Math.floor(sample.mid[1] / cellMetres))
    const bucket = grid.get(k)
    if (bucket) bucket.push(i)
    else grid.set(k, [i])
  })
  return { samples, cell: cellMetres, grid }
}

/** Every sample within one cell of `point`, so a match is never missed at a boundary. */
function near(indexed: IndexedSamples, point: [number, number]): number[] {
  const cx = Math.floor(point[0] / indexed.cell)
  const cy = Math.floor(point[1] / indexed.cell)
  const found: number[] = []
  for (let dx = -1; dx <= 1; dx++) {
    for (let dy = -1; dy <= 1; dy++) {
      const bucket = indexed.grid.get(key(cx + dx, cy + dy))
      if (bucket) found.push(...bucket)
    }
  }
  return found
}

const dot = (a: [number, number], b: [number, number]) => a[0] * b[0] + a[1] * b[1]

/**
 * How much of the walk is spent on ground it has already covered.
 *
 * Only *earlier* ground counts, so a shared corridor is charged once rather
 * than twice. Matches must run together for at least ~40 m before they count:
 * a route crossing its own path at a junction touches itself for a couple of
 * metres, and that is not retracing, it is a crossroads.
 */
export function findRepeatedCorridors(coordinates: LngLat[], options: { ignoreStartMetres?: number } = {}): RepeatReport {
  const ignoreStart = options.ignoreStartMetres ?? START_IGNORE_METRES
  const { samples, totalMetres } = resample(coordinates, SAMPLE_METRES)
  const empty: RepeatReport = { repeatedMeters: 0, repeatedPercent: 0, weightedRepeatedMeters: 0, runs: [], longestReverseRunMetres: 0 }
  if (samples.length < 3 || totalMetres <= 0) return empty

  const indexed = index(samples, CORRIDOR_MATCH_METRES)
  const matched: Array<false | { reversed: boolean }> = samples.map(() => false)

  for (let i = 0; i < samples.length; i++) {
    const sample = samples[i]
    // The first and last stretch of any loop share a doorstep. That is not a fault.
    if (sample.along < ignoreStart || sample.along > totalMetres - ignoreStart) continue
    let best: { reversed: boolean; distance: number } | undefined
    for (const j of near(indexed, sample.mid)) {
      const other = samples[j]
      // Earlier ground only, and far enough back along the route that this is
      // not simply the walk continuing round a bend.
      if (other.along >= sample.along - NON_ADJACENT_METRES) continue
      if (other.along < ignoreStart) continue
      const gap = distanceBetween(sample.mid, other.mid)
      if (gap > CORRIDOR_MATCH_METRES) continue
      const alignment = dot(sample.direction, other.direction)
      if (Math.abs(alignment) < PARALLEL_COSINE) continue
      if (!best || gap < best.distance) best = { reversed: alignment < 0, distance: gap }
    }
    if (best) matched[i] = { reversed: best.reversed }
  }

  // Group consecutive matched samples; short ones are junctions, not corridors.
  const runs: SharedRun[] = []
  let runStart = -1
  let runMetres = 0
  let reversedMetres = 0
  const closeRun = (endExclusive: number) => {
    if (runStart < 0) return
    if (runMetres >= MIN_SHARED_RUN_METRES) {
      runs.push({ metres: runMetres, reversed: reversedMetres * 2 >= runMetres, alongStart: samples[runStart].along })
    }
    void endExclusive
    runStart = -1
    runMetres = 0
    reversedMetres = 0
  }
  for (let i = 0; i < samples.length; i++) {
    const hit = matched[i]
    if (hit) {
      if (runStart < 0) runStart = i
      runMetres += samples[i].length
      if (hit.reversed) reversedMetres += samples[i].length
    } else {
      closeRun(i)
    }
  }
  closeRun(samples.length)

  const repeatedMeters = runs.reduce((total, run) => total + run.metres, 0)
  const weightedRepeatedMeters = runs.reduce((total, run) => total + run.metres * (run.reversed ? REVERSE_OVERLAP_WEIGHT : 1), 0)
  const longestReverseRunMetres = runs.filter(run => run.reversed).reduce((longest, run) => Math.max(longest, run.metres), 0)

  return {
    repeatedMeters,
    repeatedPercent: (repeatedMeters / totalMetres) * 100,
    weightedRepeatedMeters,
    runs,
    longestReverseRunMetres,
  }
}

/**
 * The length of the shared out-and-back stub at the start.
 *
 * Walk outwards from the beginning and inwards from the end at the same pace;
 * while the two are on the same ground, the walk has not started its loop yet.
 * Deliberately not subject to the 75 m that retrace detection forgives — that
 * allowance exists so a shared doorstep is not called retracing, not so a
 * quarter-kilometre spur can hide behind it.
 */
export function startStubMetres(coordinates: LngLat[], toleranceMetres = 25): number {
  const { samples, totalMetres } = resample(coordinates, SAMPLE_METRES)
  if (samples.length < 4 || totalMetres <= 0) return 0
  // Where the walk is when it has `target` metres behind it.
  const at = (target: number): Sample => {
    let low = 0
    let high = samples.length - 1
    while (low < high) {
      const mid = (low + high) >> 1
      if (samples[mid].along < target) low = mid + 1
      else high = mid
    }
    const previous = samples[low - 1]
    return previous && Math.abs(previous.along - target) < Math.abs(samples[low].along - target) ? previous : samples[low]
  }

  let stub = 0
  for (const sample of samples) {
    if (sample.along * 2 >= totalMetres) break
    if (distanceBetween(sample.mid, at(totalMetres - sample.along).mid) > toleranceMetres) break
    stub = sample.along
  }
  return stub
}

/**
 * Turn-arounds, from the line itself.
 *
 * An angle alone is not enough: a switchback lane or a tight corner round a
 * block can swing more than 165° in thirty metres without the walker having
 * reversed anything. What makes a turn a U-turn is that the walk comes back
 * past where it was — so both are required, the sharp angle *and* the ground
 * forty metres before the turn ending up within a street's width of the ground
 * forty metres after it.
 *
 * GraphHopper's own U-turn signs are taken as a supporting signal, but geometry
 * decides: a router that fails to call a reversal a reversal must not be able
 * to slip one past.
 */
export const U_TURN_DEGREES = 150
/**
 * How far apart the two arms of a turn may end up and still count as one.
 * A street's width: any wider and the walk went round something rather than
 * back down what it came up.
 */
export const U_TURN_RETURN_METRES = 20
/** Roughly 45 m of route either side of the turn. */
const U_TURN_WINDOW_SAMPLES = 3

export function countUTurns(coordinates: LngLat[], signs: Array<number | undefined> = []): number {
  const { samples } = resample(coordinates, SAMPLE_METRES)
  const window = U_TURN_WINDOW_SAMPLES
  const limit = Math.cos((U_TURN_DEGREES * Math.PI) / 180)
  let geometric = 0
  let lastAt = -Infinity

  for (let i = window; i < samples.length - window; i++) {
    const before = samples[i - window].mid
    const here = samples[i].mid
    const after = samples[i + window].mid
    const incoming = unit(before, here)
    const outgoing = unit(here, after)
    if (!incoming || !outgoing) continue
    if (dot(incoming, outgoing) > limit) continue
    if (distanceBetween(before, after) > U_TURN_RETURN_METRES) continue
    // One turn-around, not one per sample that can see it.
    if (samples[i].along - lastAt < 60) continue
    lastAt = samples[i].along
    geometric++
  }

  const fromInstructions = signs.filter(isUTurnSign).length
  return Math.max(geometric, fromInstructions)
}

function unit(from: [number, number], to: [number, number]): [number, number] | undefined {
  const dx = to[0] - from[0]
  const dy = to[1] - from[1]
  const length = Math.hypot(dx, dy)
  if (length < 1e-6) return undefined
  return [dx / length, dy / length]
}

export type QualityScore = {
  score: number
  repeatedMeters: number
  repeatedPercent: number
  uTurnCount: number
  compactness: number
}

export type QualityInput = {
  coordinates: LngLat[]
  start: LngLat
  distanceMeters: number
  durationSeconds: number
  targetMetres: number
  targetSeconds?: number
  legDistances: number[]
  maneuverSigns?: Array<number | undefined>
  /**
   * The network edges this route traversed, when the engine reported them.
   * Supplying them measures retracing on the network instead of by geometric
   * proximity; leaving them out keeps today's geometric measure exactly.
   */
  traversals?: EdgeTraversal[]
  /**
   * Every threshold above, individually overridable. Exists for the tuning
   * panel: a walker experimenting with these live is how we find out which
   * one is actually the wall at their address, rather than guessing from
   * server logs. Never sent by the ordinary app flow, which always gets the
   * defaults above.
   */
  thresholds?: Partial<QualityThresholds>
}

export type QualityThresholds = {
  maxDistanceError: number
  maxDurationError: number
  maxRepeatedFraction: number
  maxUTurns: number
  maxLegShare: number
  minLegShare: number
  maxBoundingBoxRatio: number
  minCompactness: number
  maxStartStubMetres: number
  startStubShare: number
  /** See MIN_BACKTRACK_METRES. A minimum, not a maximum: backtracking has to
   *  reach this length before it stops being held against the walk. */
  minBacktrackMetres: number
}

export const DEFAULT_QUALITY_THRESHOLDS: QualityThresholds = {
  maxDistanceError: MAX_DISTANCE_ERROR,
  maxDurationError: MAX_DURATION_ERROR,
  maxRepeatedFraction: MAX_REPEATED_FRACTION,
  maxUTurns: MAX_U_TURNS,
  maxLegShare: MAX_LEG_SHARE,
  minLegShare: MIN_LEG_SHARE,
  maxBoundingBoxRatio: MAX_BOUNDING_BOX_RATIO,
  minCompactness: MIN_COMPACTNESS,
  maxStartStubMetres: MAX_START_STUB_METRES,
  startStubShare: START_STUB_SHARE,
  minBacktrackMetres: MIN_BACKTRACK_METRES,
}

/**
 * The rejections that mean "this is not the walk you asked for": the wrong
 * length, the wrong duration, or not actually returning to the start. Every
 * other rejection is about the *shape* of the walk — retracing, hairpins,
 * lopsided legs, a long thin corridor.
 *
 * Where the ground offers no clean loop at all, Looper would rather offer a
 * walk that doubles back than nothing, so the shape rules can be set aside as
 * a last resort. These three never can: a 9 km trudge is not an answer to
 * someone who asked for 5 km.
 */
export const ESSENTIAL_REJECTIONS = ['distance', 'duration', 'open-ended'] as const

export type QualityReport = {
  pass: boolean
  /** Machine-readable reasons, for logs and tests. Never shown to a walker. */
  rejections: string[]
  quality: QualityScore
  distanceErrorFraction: number
  durationErrorFraction?: number
  /**
   * What was measured and what was asked for. Echoed back because a repair
   * needs to know *which side* of the target a candidate missed on, and an
   * error fraction is an absolute value.
   */
  distanceMeters: number
  targetMetres: number
  durationSeconds: number
  targetSeconds?: number
  boundingBoxRatio: number
  legShares: number[]
  /** Out-and-back length at the door before the loop proper begins. */
  startStubMetres: number
  longestReverseRunMetres: number
  /** True when the only thing wrong is the time, which one retry may fix. */
  durationOnly: boolean
  /** True when the only thing wrong is the length, which a resized ring may fix. */
  distanceOnly: boolean
  /** Which measure decided the retracing figures above. */
  overlapSource: 'edges' | 'geometry'
  /**
   * Right length, right place, but the shape is compromised — it retraces, or
   * doubles back, or is a long thin corridor. Offered only where nothing clean
   * exists, and never silently.
   */
  passesEssentials: boolean
}

export function analyseRouteQuality(input: QualityInput): QualityReport {
  const { coordinates, start, distanceMeters, durationSeconds, targetMetres, targetSeconds, legDistances } = input
  const t: QualityThresholds = { ...DEFAULT_QUALITY_THRESHOLDS, ...input.thresholds }
  const rejections: string[] = []

  const measured = repeatsFor(coordinates, input.traversals, distanceMeters)
  const repeats = measured.repeats
  const uTurnCount = countUTurns(coordinates, input.maneuverSigns)
  const shape = isoperimetricCompactness(coordinates)
  const { longMetres, shortMetres } = boundingBoxSides(coordinates)
  const boundingBoxRatio = shortMetres > 0 ? longMetres / shortMetres : Infinity
  const stubMetres = startStubMetres(coordinates)
  const total = legDistances.reduce((sum, leg) => sum + leg, 0) || distanceMeters
  const legShares = legDistances.map(leg => (total > 0 ? leg / total : 0))
  const startStubLimit = spurLimitMetres(distanceMeters, t.maxStartStubMetres, t.startStubShare)
  /** Long enough that it can only be a real feature, not an accident. */
  const isLongEnoughBacktrack = repeats.longestReverseRunMetres >= t.minBacktrackMetres
  /**
   * Short and non-zero: some ground was retraced, but not enough of it to be
   * the walk's own feature rather than a corner that turned out to be a dead
   * end. This is the one always held against a walk, regardless of shape.
   */
  const isShortBacktrack = repeats.longestReverseRunMetres > 0 && !isLongEnoughBacktrack
  /**
   * A walk that is essentially there-and-back — a promenade, a pier, a
   * headland with one road in — legitimately encloses almost no area, runs
   * long and thin, and puts about half its distance on a single leg. That is
   * what the walk is, not a failure of shape. A loop that merely has one
   * long, legitimate crossing off to the side (a bridge with no second
   * crossing) still gets judged as the loop it otherwise is.
   */
  const isWholeWalkOutAndBack = isLongEnoughBacktrack
    && repeats.longestReverseRunMetres > distanceMeters * OUT_AND_BACK_SHARE_THRESHOLD
  /**
   * Ground repeated beyond the one long crossing already excused above. A
   * walk is not let off the general scribble check just because one of its
   * retraced stretches happens to be a legitimate feature.
   */
  const scribbleMeters = Math.max(0, repeats.repeatedMeters - (isLongEnoughBacktrack ? repeats.longestReverseRunMetres : 0))

  const distanceErrorFraction = targetMetres > 0 ? Math.abs(distanceMeters - targetMetres) / targetMetres : 0
  const durationErrorFraction = targetSeconds && targetSeconds > 0 ? Math.abs(durationSeconds - targetSeconds) / targetSeconds : undefined

  if (distanceErrorFraction > t.maxDistanceError) rejections.push('distance')
  if (durationErrorFraction !== undefined && durationErrorFraction > t.maxDurationError) rejections.push('duration')
  if (scribbleMeters > distanceMeters * t.maxRepeatedFraction) rejections.push('repeated-corridor')
  if (isShortBacktrack) rejections.push('out-and-back-spur')
  if (uTurnCount > t.maxUTurns) rejections.push('u-turns')
  // A two-leg shape — out one way, home a different way, no third corner —
  // can never satisfy this: two shares summing to the whole walk always put
  // one of them past 45%. That is what a two-leg shape *is*, not a failure
  // of balance; the check only means something once there is a third corner
  // to be lopsided against.
  if (!isWholeWalkOutAndBack && legShares.length > 2 && legShares.some(share => share > t.maxLegShare)) rejections.push('leg-too-long')
  if (legShares.slice(1, -1).some(share => share < t.minLegShare)) rejections.push('leg-too-short')
  if (!isWholeWalkOutAndBack && boundingBoxRatio > t.maxBoundingBoxRatio) rejections.push('elongated')
  if (!isWholeWalkOutAndBack && shape < t.minCompactness) rejections.push('shapeless')
  // The doorstep stub is the same band the mid-route backtrack check applies:
  // fine as the ordinary shared pavement every loop has, fine again once it
  // is long enough to be a real feature in its own right (a promenade the
  // walk happens to start on), and rejected only in between — long enough to
  // be "a there-and-back with a loop stuck on the end," not long enough to
  // be a destination.
  if (stubMetres > startStubLimit && stubMetres < t.minBacktrackMetres) rejections.push('start-spur')
  if (!returnsToStart(coordinates, start)) rejections.push('open-ended')

  return {
    pass: rejections.length === 0,
    rejections,
    quality: {
      score: scoreRoute({ repeats, distanceErrorFraction, durationErrorFraction, compactness: shape, legShares, uTurnCount, distanceMeters }),
      repeatedMeters: Math.round(repeats.repeatedMeters),
      repeatedPercent: round(repeats.repeatedPercent, 1),
      uTurnCount,
      compactness: round(shape, 3),
    },
    distanceErrorFraction,
    durationErrorFraction,
    distanceMeters,
    targetMetres,
    durationSeconds,
    targetSeconds,
    boundingBoxRatio,
    legShares,
    startStubMetres: stubMetres,
    longestReverseRunMetres: repeats.longestReverseRunMetres,
    durationOnly: rejections.length === 1 && rejections[0] === 'duration',
    distanceOnly: rejections.length === 1 && rejections[0] === 'distance',
    overlapSource: measured.source,
    passesEssentials: !rejections.some(reason => (ESSENTIAL_REJECTIONS as readonly string[]).includes(reason)),
  }
}

/**
 * Retracing, from the network where the network is known and from the geometry
 * where it is not. The two measures answer the same question and are used
 * interchangeably by everything downstream, so both must produce the same
 * shape of answer — including the reverse-run length, which is what decides
 * whether a long backtrack is a pier or a mistake.
 */
function repeatsFor(
  coordinates: LngLat[],
  traversals: EdgeTraversal[] | undefined,
  distanceMeters: number,
): { repeats: RepeatReport; source: 'edges' | 'geometry' } {
  if (!traversals?.length) return { repeats: findRepeatedCorridors(coordinates), source: 'geometry' }
  const report = edgeRepeatReport(traversals, distanceMeters)
  return {
    source: 'edges',
    repeats: {
      repeatedMeters: report.repeatedMeters,
      repeatedPercent: report.repeatedPercent,
      weightedRepeatedMeters: report.weightedRepeatedMeters,
      // The individual runs exist only for the aggregates above, which the
      // network measure produces directly.
      runs: [],
      longestReverseRunMetres: report.longestReverseRunMetres,
    },
  }
}

/**
 * A loop that does not end where it began is not a loop. The comparison is
 * against the route's own first point, which is where the router actually
 * started after snapping to the network.
 */
function returnsToStart(coordinates: LngLat[], start: LngLat): boolean {
  if (coordinates.length < 2) return false
  const first = coordinates[0]
  const last = coordinates[coordinates.length - 1]
  return haversine(first, last) <= ENDPOINT_TOLERANCE_METRES && haversine(start, first) <= 1000
}

/**
 * The ranking, weighted the way a walker would weigh it: not covering the same
 * ground twice matters most, then getting the length they asked for, then
 * whether it feels like a loop, then whether it is a balanced walk rather than
 * a long trudge and three corners, then how fiddly it is to follow.
 */
export const SCORE_WEIGHTS = { overlap: 0.35, closeness: 0.25, shape: 0.20, balance: 0.10, simplicity: 0.10 }

function scoreRoute(parts: {
  repeats: RepeatReport
  distanceErrorFraction: number
  durationErrorFraction?: number
  compactness: number
  legShares: number[]
  uTurnCount: number
  distanceMeters: number
}): number {
  const totalMetres = Math.max(1, parts.distanceMeters)
  const weightedOverlap = parts.repeats.weightedRepeatedMeters / totalMetres
  const overlap = clamp(1 - weightedOverlap / MAX_REPEATED_FRACTION)
  const error = Math.max(parts.distanceErrorFraction / MAX_DISTANCE_ERROR, (parts.durationErrorFraction ?? 0) / MAX_DURATION_ERROR)
  const closeness = clamp(1 - error)
  const shape = clamp(parts.compactness)
  const spread = parts.legShares.length ? Math.max(...parts.legShares) - Math.min(...parts.legShares) : 1
  const balance = clamp(1 - spread / (MAX_LEG_SHARE - MIN_LEG_SHARE))
  const simplicity = clamp(1 - parts.uTurnCount / (MAX_U_TURNS + 1))

  return round(100 * (
    SCORE_WEIGHTS.overlap * overlap +
    SCORE_WEIGHTS.closeness * closeness +
    SCORE_WEIGHTS.shape * shape +
    SCORE_WEIGHTS.balance * balance +
    SCORE_WEIGHTS.simplicity * simplicity
  ), 1)
}

const clamp = (value: number) => Math.min(1, Math.max(0, value))
const round = (value: number, places: number) => Number(value.toFixed(places))

/**
 * How much of route `a` runs along route `b`. Used to keep the three offered
 * walks genuinely different from one another rather than three readings of the
 * same streets. The shared doorstep at either end is excluded, for the same
 * reason it is excluded from retrace detection.
 */
export function sharedCorridorMetres(a: LngLat[], b: LngLat[], ignoreStartMetres = START_IGNORE_METRES): { metres: number; fraction: number } {
  // Both routes must be measured in the *same* frame, or two loops three
  // kilometres apart come out overlapping.
  const origin = a[0]
  const left = resample(a, SAMPLE_METRES, origin)
  const right = resample(b, SAMPLE_METRES, origin)
  if (!left.samples.length || !right.samples.length) return { metres: 0, fraction: 0 }
  const indexed = index(right.samples, CORRIDOR_MATCH_METRES)

  let runMetres = 0
  let shared = 0
  const closeRun = () => {
    if (runMetres >= MIN_SHARED_RUN_METRES) shared += runMetres
    runMetres = 0
  }
  for (const sample of left.samples) {
    if (sample.along < ignoreStartMetres || sample.along > left.totalMetres - ignoreStartMetres) {
      closeRun()
      continue
    }
    const hit = near(indexed, sample.mid).some(j => {
      const other = right.samples[j]
      return distanceBetween(sample.mid, other.mid) <= CORRIDOR_MATCH_METRES
        && Math.abs(dot(sample.direction, other.direction)) >= PARALLEL_COSINE
    })
    if (hit) runMetres += sample.length
    else closeRun()
  }
  closeRun()

  return { metres: shared, fraction: left.totalMetres > 0 ? shared / left.totalMetres : 0 }
}
