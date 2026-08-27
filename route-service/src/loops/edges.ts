import { distanceBetween, projector, type LngLat, type Metric } from './geo.js'

/**
 * Overlap measured on the network, not on the map.
 *
 * The geometric measure in quality.ts asks whether two stretches of walk pass
 * within seventeen metres of each other running roughly parallel. That is a
 * street's width, so it cannot tell the pavement on one side of a road from
 * the pavement on the other, a back lane from the road it runs behind, or a
 * towpath from the road above it. All three read as "the same ground", and all
 * three are what a walker would call a genuinely different way round.
 *
 * When GraphHopper tells us which edges a route actually traversed, the
 * question stops being geometric: two routes share ground if and only if they
 * walked the same edges, and how much they share is the length they both
 * walked on those edges. A crossing shares no edge. A parallel pavement shares
 * no edge. Walking one street twice shares all of it.
 *
 * Geometry remains the truth for everything about *shape* — spikes, bounding
 * boxes, compactness, avoidance corridors, what gets drawn — and remains the
 * fallback wherever edge ids are unavailable.
 */

/** One stretch of a route on one network edge, as GraphHopper reports it. */
export type EdgeSpan = {
  id: number
  /** Index of the first coordinate of the stretch, into the route's own line. */
  startIndex: number
  /** Index of the last coordinate of the stretch. */
  endIndex: number
}

/** One stretch of a route on one edge, measured. */
export type EdgeTraversal = {
  id: number
  /** Metres walked on this edge during this pass. */
  metres: number
  /** Metres from the start of the route to the middle of this pass. */
  along: number
  /** Unit vector along the pass, in the route's own local frame. */
  direction: Metric
}

export type EdgeRepeatReport = {
  repeatedMeters: number
  repeatedPercent: number
  /** Reverse-direction repeats counted at a premium, for scoring only. */
  weightedRepeatedMeters: number
  /** The longest unbroken stretch of already-walked ground. */
  longestRepeatedRunMetres: number
  /** The longest unbroken stretch walked back the way it came. */
  longestReverseRunMetres: number
}

/** Walking the same street back the other way is the worse failure. */
export const REVERSE_REPEAT_WEIGHT = 1.5
/** The shared doorstep at either end of any loop is not retracing. */
export const EDGE_START_IGNORE_METRES = 75

/**
 * Turn GraphHopper's edge intervals into measured passes.
 *
 * Lengths come from the route's own geometry rather than from the graph, which
 * is what makes a partial traversal come out right: an edge entered halfway
 * along, because the walk snapped into the middle of it, contributes only the
 * half that was walked.
 *
 * Spans that fall outside the line, run backwards, or collapse to a point are
 * dropped rather than trusted — a malformed detail is missing data, not a
 * reason to produce a wrong measurement.
 */
export function measureTraversals(coordinates: LngLat[], spans: EdgeSpan[] | undefined): EdgeTraversal[] | undefined {
  if (!spans?.length || coordinates.length < 2) return undefined
  const project = projector(coordinates[0])
  const flat = coordinates.map(project)
  // Cumulative distance to each vertex, so a span's length and position are
  // both a subtraction rather than a walk along the line.
  const cumulative = new Float64Array(flat.length)
  for (let index = 1; index < flat.length; index++) {
    cumulative[index] = cumulative[index - 1] + distanceBetween(flat[index - 1], flat[index])
  }

  const traversals: EdgeTraversal[] = []
  for (const span of spans) {
    const from = span.startIndex
    const to = span.endIndex
    if (!Number.isInteger(from) || !Number.isInteger(to)) continue
    if (from < 0 || to >= flat.length || to <= from) continue
    const metres = cumulative[to] - cumulative[from]
    if (!(metres > 0)) continue
    // A span whose two ends land on the same spot has no overall direction —
    // a graph edge never does this, but a caller measuring a whole closed loop
    // as one span would. Fall back to the direction it set off in.
    const direction = unit(flat[from], flat[to]) ?? unit(flat[from], flat[from + 1])
    if (!direction) continue
    traversals.push({ id: span.id, metres, along: (cumulative[from] + cumulative[to]) / 2, direction })
  }
  return traversals.length ? traversals : undefined
}

function unit(from: Metric, to: Metric): Metric | undefined {
  const dx = to[0] - from[0]
  const dy = to[1] - from[1]
  const length = Math.hypot(dx, dy)
  if (length < 1e-9) return undefined
  return [dx / length, dy / length]
}

const dot = (a: Metric, b: Metric) => a[0] * b[0] + a[1] * b[1]

/**
 * How much of a walk is spent on ground it has already covered.
 *
 * A pass over an edge repeats only as much as has already been covered on that
 * edge, so the second full traversal of a street counts once, not twice, and
 * three traversals count twice. The first and last stretch of the route are
 * skipped entirely: every loop shares a doorstep, and that is not retracing.
 *
 * One honest limitation: where the same edge is entered partway along twice,
 * on genuinely different portions of it, this counts the shorter pass as
 * repeated even though no ground was walked twice. That can only happen where
 * a route snaps into or out of the middle of an edge — the ends of a leg — and
 * the geometric measure makes the same assumption far more often.
 */
export function edgeRepeatReport(traversals: EdgeTraversal[], totalMetres: number, ignoreStartMetres = EDGE_START_IGNORE_METRES): EdgeRepeatReport {
  const empty: EdgeRepeatReport = {
    repeatedMeters: 0,
    repeatedPercent: 0,
    weightedRepeatedMeters: 0,
    longestRepeatedRunMetres: 0,
    longestReverseRunMetres: 0,
  }
  if (!traversals.length || totalMetres <= 0) return empty

  /** The most of an edge covered in one pass so far, and which way that pass ran. */
  const covered = new Map<number, { metres: number; direction: Metric }>()
  let repeatedMeters = 0
  let weightedRepeatedMeters = 0
  let longestRepeatedRunMetres = 0
  let longestReverseRunMetres = 0
  let repeatedRun = 0
  let reverseRun = 0

  for (const traversal of traversals) {
    const atDoorstep = traversal.along < ignoreStartMetres || traversal.along > totalMetres - ignoreStartMetres
    const seen = covered.get(traversal.id)
    const overlap = atDoorstep ? 0 : Math.min(traversal.metres, seen?.metres ?? 0)

    if (overlap > 0) {
      const reversed = seen ? dot(traversal.direction, seen.direction) < 0 : false
      repeatedMeters += overlap
      weightedRepeatedMeters += overlap * (reversed ? REVERSE_REPEAT_WEIGHT : 1)
      repeatedRun += overlap
      reverseRun = reversed ? reverseRun + overlap : 0
      longestRepeatedRunMetres = Math.max(longestRepeatedRunMetres, repeatedRun)
      longestReverseRunMetres = Math.max(longestReverseRunMetres, reverseRun)
    } else {
      repeatedRun = 0
      reverseRun = 0
    }

    if (!seen || traversal.metres > seen.metres) {
      covered.set(traversal.id, { metres: traversal.metres, direction: traversal.direction })
    }
  }

  return {
    repeatedMeters,
    repeatedPercent: (repeatedMeters / totalMetres) * 100,
    weightedRepeatedMeters,
    longestRepeatedRunMetres,
    longestReverseRunMetres,
  }
}

/**
 * How much of route `a` runs along the same edges as route `b`.
 *
 * Deliberately not symmetric, for the same reason the geometric version is
 * not: a two-kilometre walk sharing every metre with a six-kilometre one is
 * entirely contained in it, and the six-kilometre walk is not. The caller
 * checks both directions where that matters.
 */
export function sharedEdgeMetres(
  a: EdgeTraversal[],
  b: EdgeTraversal[],
  totalMetresOfA: number,
  ignoreStartMetres = EDGE_START_IGNORE_METRES,
): { metres: number; fraction: number } {
  if (!a.length || !b.length || totalMetresOfA <= 0) return { metres: 0, fraction: 0 }
  const inB = new Map<number, number>()
  for (const traversal of b) {
    inB.set(traversal.id, Math.max(inB.get(traversal.id) ?? 0, traversal.metres))
  }

  let metres = 0
  for (const traversal of a) {
    if (traversal.along < ignoreStartMetres || traversal.along > totalMetresOfA - ignoreStartMetres) continue
    const other = inB.get(traversal.id)
    if (other === undefined) continue
    metres += Math.min(traversal.metres, other)
  }
  return { metres, fraction: metres / totalMetresOfA }
}

/**
 * The longest stretch of a route walked more than once, as a coordinate range.
 * Used to aim a repair at the section that is actually the problem rather than
 * at the route as a whole.
 */
export function longestRepeatedSection(traversals: EdgeTraversal[]): { fromAlong: number; toAlong: number; metres: number } | undefined {
  const covered = new Map<number, number>()
  let best: { fromAlong: number; toAlong: number; metres: number } | undefined
  let runFrom = 0
  let runMetres = 0

  for (const traversal of traversals) {
    const seen = covered.get(traversal.id) ?? 0
    const overlap = Math.min(traversal.metres, seen)
    if (overlap > 0) {
      if (runMetres === 0) runFrom = traversal.along - traversal.metres / 2
      runMetres += overlap
      const candidate = { fromAlong: runFrom, toAlong: traversal.along + traversal.metres / 2, metres: runMetres }
      if (!best || candidate.metres > best.metres) best = candidate
    } else {
      runMetres = 0
    }
    if (traversal.metres > seen) covered.set(traversal.id, traversal.metres)
  }
  return best
}

/** One stretch of a route on one road class, as GraphHopper reports it. */
export type ClassSpan = {
  value: string
  startIndex: number
  endIndex: number
}

/**
 * The road classes a walker treats as a pavement rather than a road: ground
 * laid down for people on foot. Anything else is a carriageway shared with
 * traffic, however quiet.
 */
export const PEDESTRIAN_ROAD_CLASSES = new Set(['FOOTWAY', 'PATH', 'PEDESTRIAN', 'STEPS'])

export type PavementReport = {
  /** Metres walked on dedicated pedestrian ways. */
  pavementMetres: number
  /** Metres of the measured stretch, pedestrian and carriageway together. */
  measuredMetres: number
  /** Times the walk changed between pavement and carriageway. */
  hops: number
  /** Hops per kilometre walked — the comparable figure. */
  hopsPerKm: number
}

/**
 * How often a walk changes its mind about whether it is on the pavement.
 *
 * Where OSM maps a pavement as its own way, a pavement and its carriageway are
 * near enough the same weight that the router takes whichever is a few metres
 * shorter, block by block. The line then crosses and recrosses the road, which
 * is confusing to look at and produces a turn prompt every time. Nothing has
 * ever counted it, so every attempt to tune it against has been an argument
 * about screenshots.
 *
 * Counted as *transitions*, not as classes: a walk entirely on pavements and a
 * walk entirely on roads both score zero, because neither leaves the walker
 * wondering which side of the street they are meant to be on. Only alternation
 * costs. Per kilometre, so a 10 km walk is comparable with a 3 km one.
 *
 * Consecutive spans of the same kind are one stretch — GraphHopper splits a
 * detail at every edge, so a single pavement is many spans and none of those
 * boundaries is a hop.
 *
 * Unclassified ground is skipped rather than guessed at, and skipped without
 * breaking the run: a gap in the detail is missing data, and treating it as a
 * carriageway would invent two hops around every hole.
 */
export function pavementReport(coordinates: LngLat[], spans: ClassSpan[] | undefined): PavementReport | undefined {
  if (!spans?.length || coordinates.length < 2) return undefined
  const project = projector(coordinates[0])
  const flat = coordinates.map(project)
  const cumulative = new Float64Array(flat.length)
  for (let index = 1; index < flat.length; index++) {
    cumulative[index] = cumulative[index - 1] + distanceBetween(flat[index - 1], flat[index])
  }

  const ordered = [...spans].sort((a, b) => a.startIndex - b.startIndex)
  let pavementMetres = 0
  let measuredMetres = 0
  let hops = 0
  let previous: boolean | undefined
  for (const span of ordered) {
    const { startIndex: from, endIndex: to } = span
    if (!Number.isInteger(from) || !Number.isInteger(to)) continue
    if (from < 0 || to >= flat.length || to <= from) continue
    const metres = cumulative[to] - cumulative[from]
    if (!(metres > 0)) continue
    const pedestrian = PEDESTRIAN_ROAD_CLASSES.has(span.value.toUpperCase())
    measuredMetres += metres
    if (pedestrian) pavementMetres += metres
    if (previous !== undefined && previous !== pedestrian) hops++
    previous = pedestrian
  }

  if (!(measuredMetres > 0)) return undefined
  return {
    pavementMetres,
    measuredMetres,
    hops,
    hopsPerKm: (hops * 1000) / measuredMetres,
  }
}
