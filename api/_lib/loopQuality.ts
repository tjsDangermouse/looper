// Judging a candidate loop. The failures walkers actually complain about are
// retracing, dead-end spurs and "it's just a long line there and back", so each
// one gets its own measurement rather than being folded into a single number.
import { Grid, bearing, bearingDelta, distanceBetween, orientedExtent, pathLength, project, resample, type Point } from './geo.js'
export type { Point } from './geo.js'

// Geometry tolerances, all in metres.
export const SAMPLE_STEP = 15          // resampling resolution for corridor scanning
export const CORRIDOR_WIDTH = 18       // two paths this close are the same corridor
export const MIN_CORRIDOR_LENGTH = 38  // shorter than this is a crossing, not retracing
export const START_EXCLUSION = 75      // shared departure/arrival stub is unavoidable
export const MIN_ALONG_SEPARATION = 60 // ignore near-neighbours: a bend is not an overlap

// Hard limits.
export const MAX_RETRACE_FRACTION = .12
export const MAX_SPUR_METRES = 150
export const MAX_LEG_SHARE = .45
export const MIN_OUTER_LEG_SHARE = .08
export const MAX_EXTENT_RATIO = 4.5
export const MAX_U_TURNS = 1
export const DISTANCE_TOLERANCE = .12
export const DURATION_TOLERANCE = .15

const U_TURN = 9, SHARP = new Set([2, 3, 9]) // ORS instruction types

export type RouteInput = {
  coordinates: Point[]
  distanceMeters: number
  durationSeconds: number
  /** One per ORS segment, i.e. one per leg of the waypoint ring. */
  legDistances?: number[]
  maneuvers?: (number | undefined)[]
  /** OSM way ids from `extra_info: ["osmid"]`, as [fromIndex, toIndex, wayId]. */
  wayValues?: number[][]
}

export type Overlap = {
  retracedMetres: number
  retraceFraction: number
  weightedFraction: number
  longestReverseRun: number
  runs: { startAlong: number; length: number; reversed: boolean }[]
}

/** Where the route walks ground it has already covered. Works on evenly spaced
 *  samples rather than raw ORS vertices — vertex spacing swings from a metre to
 *  a hundred, which would make any per-vertex test meaningless. */
export function selfOverlap(coordinates: Point[]): Overlap {
  const empty: Overlap = { retracedMetres: 0, retraceFraction: 0, weightedFraction: 0, longestReverseRun: 0, runs: [] }
  const flat = project(coordinates)
  const total = pathLength(flat)
  if (total <= 0) return empty
  const samples = resample(flat, SAMPLE_STEP)
  if (samples.length < 3) return empty

  const grid = new Grid(CORRIDOR_WIDTH)
  samples.forEach((sample, index) => grid.add(sample.point, index))

  // reversed | same | undefined for each sample.
  const matched: (boolean | undefined)[] = new Array(samples.length)
  for (let i = 0; i < samples.length; i++) {
    const sample = samples[i]
    // A brief shared stub leaving and returning to the start is unavoidable on
    // most street layouts, so it is not counted against the route.
    if (sample.along < START_EXCLUSION || sample.along > total - START_EXCLUSION) continue
    for (const j of grid.near(sample.point)) {
      if (j === i) continue
      const other = samples[j]
      if (Math.abs(other.along - sample.along) < MIN_ALONG_SEPARATION) continue
      if (other.along < START_EXCLUSION || other.along > total - START_EXCLUSION) continue
      if (distanceBetween(sample.point, other.point) > CORRIDOR_WIDTH) continue
      const delta = bearingDelta(sample.bearing, other.bearing)
      // Anything in between is a path crossing another at an angle, which is
      // just a junction and perfectly normal on a loop.
      if (delta >= 140) { matched[i] = true; break }
      if (delta <= 40) matched[i] ??= false
    }
  }

  // Only sustained corridors count; a couple of stray samples is noise.
  const runs: Overlap['runs'] = []
  for (let i = 0; i < samples.length;) {
    if (matched[i] === undefined) { i++; continue }
    let j = i, reversed = false
    while (j < samples.length && matched[j] !== undefined) { reversed ||= matched[j] === true; j++ }
    const length = (j - i) * SAMPLE_STEP
    if (length >= MIN_CORRIDOR_LENGTH) runs.push({ startAlong: samples[i].along, length, reversed })
    i = j
  }

  const retracedMetres = runs.reduce((sum, run) => sum + run.length, 0)
  // Walking a corridor back the way you came is the thing people notice;
  // brushing past it in the same direction is far more forgivable.
  const weighted = runs.reduce((sum, run) => sum + run.length * (run.reversed ? 1 : .6), 0)
  return {
    retracedMetres,
    retraceFraction: Math.min(1, retracedMetres / total),
    weightedFraction: Math.min(1, weighted / total),
    // Each pass of an out-and-back is marked, so one spur shows as two runs of
    // its own length; the longest single run is the length of the spur itself.
    longestReverseRun: runs.filter(run => run.reversed).reduce((max, run) => Math.max(max, run.length), 0),
    runs,
  }
}

/** Share of the walk spent on OSM ways it uses more than once. A weak signal on
 *  its own — one way id can span a whole high street — so it only ever nudges
 *  the geometry result, never overrides it. */
export function repeatedWayFraction(distanceMeters: number, coordinates: Point[], wayValues?: number[][]) {
  if (!wayValues?.length || coordinates.length < 2 || distanceMeters <= 0) return 0
  const flat = project(coordinates), lengths = new Map<number, number>(), passes = new Map<number, number>()
  for (const [from, to, id] of wayValues) {
    let length = 0
    for (let i = Math.max(1, from); i <= Math.min(to, flat.length - 1); i++) length += distanceBetween(flat[i - 1], flat[i])
    lengths.set(id, (lengths.get(id) || 0) + length)
    passes.set(id, (passes.get(id) || 0) + 1)
  }
  let repeated = 0
  for (const [id, count] of passes) if (count > 1) repeated += lengths.get(id) || 0
  return Math.min(1, repeated / pathLength(flat))
}

/** Isoperimetric quotient: 1 for a circle, ~0 for a there-and-back with no
 *  enclosed area. The single best proxy for "looks like a deliberate loop". */
export function roundness(coordinates: Point[]) {
  const flat = project(coordinates)
  if (flat.length < 4) return 0
  let twiceArea = 0, perimeter = 0
  for (let i = 0; i < flat.length; i++) {
    const a = flat[i], b = flat[(i + 1) % flat.length]
    twiceArea += a[0] * b[1] - b[0] * a[1]
    perimeter += distanceBetween(a, b)
  }
  return perimeter > 0 ? Math.min(1, 4 * Math.PI * Math.abs(twiceArea / 2) / perimeter ** 2) : 0
}

export const uTurnCount = (maneuvers: (number | undefined)[] = []) => maneuvers.filter(m => m === U_TURN).length
export const sharpTurnsPerKm = (maneuvers: (number | undefined)[] = [], distanceMeters: number) =>
  distanceMeters > 0 ? maneuvers.filter(m => m !== undefined && SHARP.has(m)).length / (distanceMeters / 1000) : 0

/** Bearing from the start over the first stretch of the walk — used to keep the
 *  three offered loops heading different ways. */
export function departureBearing(coordinates: Point[], metres = 120) {
  if (coordinates.length < 2) return 0
  const start = coordinates[0]
  let along = 0
  for (let i = 1; i < coordinates.length; i++) {
    const flat = project([coordinates[i - 1], coordinates[i]])
    along += distanceBetween(flat[0], flat[1])
    if (along >= metres) return bearing(start, coordinates[i])
  }
  return bearing(start, coordinates[coordinates.length - 1])
}

/** The direction the loop as a whole occupies, taken from the point on it
 *  furthest from the start. Deliberately not the raw first-100-metres bearing:
 *  a ring entered at its nearest point sets off tangentially, so two people
 *  walking the same circuit in opposite directions would read two different
 *  labels for one walk. The far end is what a walker pictures. */
export function dominantBearing(coordinates: Point[]) {
  if (coordinates.length < 2) return 0
  const flat = project(coordinates), [origin] = flat
  let far = origin, best = -1
  for (const point of flat) {
    const distance = distanceBetween(point, origin)
    if (distance > best) { best = distance; far = point }
  }
  if (best <= 0) return departureBearing(coordinates)
  return (Math.atan2(far[0] - origin[0], far[1] - origin[1]) * 180 / Math.PI + 360) % 360
}

export type Assessment = {
  passed: boolean
  score: number
  rejections: string[]
  metrics: {
    distanceMeters: number
    durationSeconds: number
    distanceErrorFraction: number
    durationErrorFraction: number
    retraceFraction: number
    weightedRetraceFraction: number
    repeatedWayFraction: number
    longestSpurMetres: number
    uTurns: number
    sharpTurnsPerKm: number
    maxLegShare: number
    minOuterLegShare: number
    extentRatio: number
    roundness: number
    departureBearing: number
    dominantBearing: number
  }
  /** 0–1 each, before weighting; kept for development logging. */
  components: { overlap: number; accuracy: number; shape: number; balance: number; turns: number }
}

export type Target = { metres: number; seconds?: number; mode: 'distance' | 'time' }

const clamp01 = (value: number) => Math.min(1, Math.max(0, value))

// Self-overlap is the strongest factor by design: a route that retraces itself
// is the one complaint no amount of accuracy or shape makes up for.
export const WEIGHTS = { overlap: .35, accuracy: .25, shape: .2, balance: .1, turns: .1 }

/** Score one candidate and say plainly why it is not offerable, if it isn't. */
export function scoreLoopRoute(route: RouteInput, target: Target): Assessment {
  const { coordinates, distanceMeters, durationSeconds } = route
  const overlap = selfOverlap(coordinates)
  const wayRepeat = repeatedWayFraction(distanceMeters, coordinates, route.wayValues)
  const legs = route.legDistances?.length ? route.legDistances : []
  const legTotal = legs.reduce((sum, leg) => sum + leg, 0) || distanceMeters
  const maxLegShare = legs.length ? Math.max(...legs.map(leg => leg / legTotal)) : 0
  // Legs 0 and last are the spokes out to the ring and back; the ones between
  // are the ring itself, and a vanishing ring leg means two waypoints landed on
  // the same corner and the "loop" is really a there-and-back.
  const outerLegs = legs.slice(1, -1)
  const minOuterLegShare = outerLegs.length ? Math.min(...outerLegs.map(leg => leg / legTotal)) : 1
  const extent = orientedExtent(project(coordinates))
  const uTurns = uTurnCount(route.maneuvers)
  const sharp = sharpTurnsPerKm(route.maneuvers, distanceMeters)
  const distanceErrorFraction = target.metres > 0 ? Math.abs(distanceMeters - target.metres) / target.metres : 0
  const durationErrorFraction = target.seconds ? Math.abs(durationSeconds - target.seconds) / target.seconds : 0
  const timed = target.mode === 'time' && !!target.seconds
  const accuracyError = timed ? durationErrorFraction : distanceErrorFraction
  const tolerance = timed ? DURATION_TOLERANCE : DISTANCE_TOLERANCE

  const rejections: string[] = []
  if (accuracyError > tolerance)
    rejections.push(timed ? `duration ${Math.round(durationErrorFraction * 100)}% off target` : `distance ${Math.round(distanceErrorFraction * 100)}% off target`)
  if (overlap.retraceFraction > MAX_RETRACE_FRACTION) rejections.push(`retraces ${Math.round(overlap.retraceFraction * 100)}% of itself`)
  if (overlap.longestReverseRun > MAX_SPUR_METRES) rejections.push(`out-and-back spur of ${Math.round(overlap.longestReverseRun)} m`)
  if (uTurns > MAX_U_TURNS) rejections.push(`${uTurns} U-turns`)
  if (maxLegShare > MAX_LEG_SHARE) rejections.push(`one leg is ${Math.round(maxLegShare * 100)}% of the walk`)
  if (minOuterLegShare < MIN_OUTER_LEG_SHARE) rejections.push(`an outer leg is only ${Math.round(minOuterLegShare * 100)}% of the walk`)
  if (extent.ratio > MAX_EXTENT_RATIO) rejections.push(`shape is ${extent.ratio.toFixed(1)}× longer than it is wide`)

  const components = {
    overlap: clamp01(1 - overlap.weightedFraction / MAX_RETRACE_FRACTION) * (1 - .25 * clamp01(wayRepeat)),
    accuracy: clamp01(1 - accuracyError / tolerance),
    // Both halves matter: roundness catches spurs and figure-eights, the extent
    // ratio catches the long thin loop that roundness alone can rate too kindly.
    shape: .65 * roundness(coordinates) + .35 * clamp01(1 - (extent.ratio - 1) / (MAX_EXTENT_RATIO - 1)),
    balance: legs.length ? clamp01(1 - (maxLegShare - 1 / legs.length) / (MAX_LEG_SHARE - 1 / legs.length)) : .5,
    // A single U-turn is survivable if everything else is strong, so it costs
    // most of this component rather than disqualifying the route outright.
    turns: clamp01(1 - .6 * uTurns - .4 * clamp01(sharp / 6)),
  }
  const score = 100 * (Object.keys(WEIGHTS) as (keyof typeof WEIGHTS)[]).reduce((sum, key) => sum + WEIGHTS[key] * components[key], 0)

  return {
    passed: rejections.length === 0,
    score,
    rejections,
    components,
    metrics: {
      distanceMeters, durationSeconds, distanceErrorFraction, durationErrorFraction,
      retraceFraction: overlap.retraceFraction, weightedRetraceFraction: overlap.weightedFraction,
      repeatedWayFraction: wayRepeat, longestSpurMetres: overlap.longestReverseRun,
      uTurns, sharpTurnsPerKm: sharp, maxLegShare, minOuterLegShare, extentRatio: extent.ratio,
      roundness: roundness(coordinates), departureBearing: departureBearing(coordinates), dominantBearing: dominantBearing(coordinates),
    },
  }
}

/** Share of route `a` that runs in the same corridor as route `b`, ignoring the
 *  stub near the start that every loop from one point must share. */
export function sharedFraction(a: Point[], b: Point[]) {
  const flatA = project(a), totalA = pathLength(flatA)
  if (totalA <= 0) return 0
  // Both routes are projected about A's origin so the two planes line up.
  const merged = project([a[0], ...b])
  const flatB = merged.slice(1)
  const samplesA = resample(flatA, SAMPLE_STEP), samplesB = resample(flatB, SAMPLE_STEP)
  if (!samplesA.length || !samplesB.length) return 0
  const grid = new Grid(CORRIDOR_WIDTH)
  samplesB.forEach((sample, index) => grid.add(sample.point, index))
  let shared = 0, measured = 0
  for (const sample of samplesA) {
    if (sample.along < START_EXCLUSION || sample.along > totalA - START_EXCLUSION) continue
    measured += SAMPLE_STEP
    if (grid.near(sample.point).some(j => distanceBetween(sample.point, samplesB[j].point) <= CORRIDOR_WIDTH)) shared += SAMPLE_STEP
  }
  return measured > 0 ? Math.min(1, shared / measured) : 0
}

export const MAX_SHARED_GEOMETRY = .35
export const MIN_BEARING_SEPARATION = 35
export const SIMILAR_GEOMETRY = .2

/** Two loops are the same walk to a user if they cover the same streets, or if
 *  they set off the same way and then largely coincide. */
export function tooSimilar(a: Point[], b: Point[]) {
  const shared = Math.max(sharedFraction(a, b), sharedFraction(b, a))
  if (shared > MAX_SHARED_GEOMETRY) return true
  return bearingDelta(departureBearing(a), departureBearing(b)) < MIN_BEARING_SEPARATION && shared > SIMILAR_GEOMETRY
}

/** Best first, and never two versions of the same walk. Only routes that passed
 *  every hard check get here — padding the list with poor loops is exactly the
 *  behaviour this engine exists to remove. */
export function selectLoops<T extends { coordinates: Point[]; assessment: Assessment }>(candidates: T[], wanted = 3) {
  const ranked = candidates.filter(candidate => candidate.assessment.passed).sort((a, b) => b.assessment.score - a.assessment.score)
  const chosen: T[] = []
  for (const candidate of ranked) {
    if (chosen.length >= wanted) break
    if (chosen.some(other => tooSimilar(candidate.coordinates, other.coordinates))) continue
    chosen.push(candidate)
  }
  return chosen
}

const COMPASS = ['North', 'North-east', 'East', 'South-east', 'South', 'South-west', 'West', 'North-west']
export const describeDirection = (bearingDegrees: number) => `${COMPASS[Math.round(bearingDegrees / 45) % 8]} loop`

/** Two loops heading the same way would otherwise share a name, so tell them
 *  apart by length — the thing the walker is actually choosing between. */
export function nameLoops(loops: { distanceMeters: number; direction: string }[]) {
  return loops.map(({ direction: name }, index) => {
    const sameWay = loops.map((loop, i) => ({ i, distance: loop.distanceMeters })).filter(({ i }) => loops[i].direction === name)
    if (sameWay.length < 2) return name
    sameWay.sort((a, b) => a.distance - b.distance)
    const rank = sameWay.findIndex(({ i }) => i === index)
    if (rank === 0) return `Shorter ${name.toLowerCase()}`
    if (rank === sameWay.length - 1) return `Longer ${name.toLowerCase()}`
    return name
  })
}

/** A quality cue is only worth showing when it says something true and useful,
 *  so at most one route gets each, and only when it has earned it. */
export function qualityCues(assessments: Assessment[]) {
  const cues: (string | undefined)[] = assessments.map(() => undefined)
  if (!assessments.length) return cues
  let closest = 0
  assessments.forEach((a, i) => {
    const error = (x: Assessment) => Math.min(x.metrics.distanceErrorFraction, x.metrics.durationErrorFraction || 1)
    if (error(a) < error(assessments[closest])) closest = i
  })
  const cleanest = assessments.findIndex(a => a.metrics.retraceFraction === 0 && a.metrics.uTurns === 0 && a.metrics.roundness > .5)
  if (cleanest >= 0) cues[cleanest] = 'Clean loop'
  if (cues[closest] === undefined && assessments.length > 1) cues[closest] = 'Closest to your target'
  return cues
}
