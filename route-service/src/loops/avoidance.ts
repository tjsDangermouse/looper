import buffer from '@turf/buffer'
import circle from '@turf/circle'
import simplify from '@turf/simplify'
import area from '@turf/area'
import { lineString, feature } from '@turf/helpers'
import type { Feature, MultiPolygon, Polygon } from 'geojson'
import type { LngLat } from './geo.js'

/**
 * Anti-retrace corridors.
 *
 * Once a leg has been routed, the ground it covers is turned into a polygon and
 * handed to the next leg's request as a GraphHopper custom-model area with a
 * heavily reduced priority. The next leg may still cross or share that ground —
 * a single bridge or a seafront promenade is sometimes the only way through —
 * but it has to be worth twenty times the detour before it does.
 *
 * The circle around the start is cut out of every corridor: the first street of
 * the walk is very often the only street off the walker's doorstep, and
 * forbidding it would reject loops that are perfectly fine.
 */

/** Half-width of the corridor drawn around a routed leg. */
export const CORRIDOR_HALF_WIDTH_METRES = 25
/** Radius around the start that is never penalised. */
export const START_EXCLUSION_RADIUS_METRES = 75
/**
 * GraphHopper multiplies an edge's priority into the denominator of its weight,
 * so priority 0.05 is a 20× cost multiplier: a strong discouragement, not a
 * barrier. Anything that must be walked still can be.
 */
export const AVOID_PRIORITY = 0.05
/** The one retry a leg gets if the strong penalty leaves it unroutable. */
export const RELAXED_AVOID_PRIORITY = 0.2
/** Corridors are simplified to roughly this tolerance before being sent. */
const SIMPLIFY_TOLERANCE_DEGREES = 0.00004
/** A ceiling on request size; the largest corridors are the ones that matter. */
export const MAX_AVOIDANCE_AREAS = 12

type AnyPolygon = Feature<Polygon | MultiPolygon>

/**
 * Buffered corridors for every leg walked so far, with the start area removed.
 * Returns plain Polygons: the documented GraphHopper contract for a custom-model
 * area is a Feature with a Polygon geometry, so a multi-part corridor is sent as
 * several areas rather than one MultiPolygon.
 */
export function buildAvoidanceAreas(
  legGeometries: LngLat[][],
  start: LngLat,
  options: {
    halfWidthMetres?: number
    startExclusionMetres?: number
    maxAreas?: number
  } = {},
): Feature<Polygon>[] {
  const halfWidth = options.halfWidthMetres ?? CORRIDOR_HALF_WIDTH_METRES
  const exclusion = options.startExclusionMetres ?? START_EXCLUSION_RADIUS_METRES
  const maxAreas = options.maxAreas ?? MAX_AVOIDANCE_AREAS

  const corridors: AnyPolygon[] = []
  for (const geometry of legGeometries) {
    const distinct = dropRepeatedPoints(geometry)
    if (distinct.length < 2) continue
    // Thinned before it is buffered, not after.
    //
    // GraphHopper returns a vertex every few metres, so a routed leg arrives
    // with hundreds of them, and every one becomes several vertices of the
    // corridor — which then has to be clipped and merged. Thinning the line
    // first costs nothing and takes a 1,400 m leg from 281 points to 35, and
    // the corridor is twenty-five metres wide: detail finer than that was
    // never going to survive the buffer, let alone matter to the answer.
    // Safe to mutate, because `dropRepeatedPoints` returned a fresh array.
    // The ground near the start is dropped from the *line*, before anything is
    // buffered, rather than clipped out of the finished corridor.
    //
    // Cutting a circle out of a polygon is exact and it is by far the most
    // expensive thing this service does: turf clips with arbitrary-precision
    // arithmetic, and it was 47% of all CPU. Dropping the points instead is a
    // distance test each, and the corridor it produces differs by about two
    // per cent of its area — a boundary a few metres out on a hint that is
    // deliberately a preference rather than a barrier.
    //
    // A leg that passes the start again later is split into two runs and both
    // are kept, which is the behaviour the clip had. A leg with nothing left
    // outside the circle contributes nothing, which is a legitimate outcome
    // for a very short first leg: there is then nothing left of it to avoid.
    for (const run of runsOutside(distinct, start, exclusion > 0 ? exclusion + halfWidth : 0)) {
      // Safe to mutate: `runsOutside` returns fresh arrays.
      const line = simplify(lineString(run), { tolerance: SIMPLIFY_TOLERANCE_DEGREES, highQuality: false, mutate: true })
      if (line.geometry.coordinates.length < 2) continue
      const buffered = buffer(line, halfWidth, { units: 'meters' }) as AnyPolygon | undefined
      if (buffered) corridors.push(buffered)
    }
  }
  if (!corridors.length) return []

  return corridors
    .flatMap(explodeToPolygons)
    .map(polygon => simplify(polygon, { tolerance: SIMPLIFY_TOLERANCE_DEGREES, highQuality: false, mutate: true }))
    .filter(polygon => polygon.geometry.coordinates.length > 0 && polygon.geometry.coordinates[0].length >= 4)
    .sort((a, b) => area(b) - area(a))
    .slice(0, maxAreas)
}

/** Turf refuses a line with a repeated vertex; GraphHopper emits them at joins. */
function dropRepeatedPoints(coordinates: LngLat[]): LngLat[] {
  const out: LngLat[] = []
  for (const point of coordinates) {
    const last = out[out.length - 1]
    if (!last || last[0] !== point[0] || last[1] !== point[1]) out.push(point)
  }
  return out
}

/**
 * The stretches of a line that lie further than `radius` from `centre`, as
 * separate runs. A radius of zero keeps the line whole.
 *
 * The line is cut where it crosses the circle rather than at whichever vertex
 * happens to fall outside it. GraphHopper emits a vertex every few metres, so
 * the two are nearly the same on a real leg — but they are not the same on a
 * sparse one, where a segment can span the whole circle and dropping its inner
 * end would throw the entire corridor away. A corridor that silently does not
 * exist is the worst failure available here: the walk stops being steered and
 * nothing says so.
 */
function runsOutside(coordinates: LngLat[], centre: LngLat, radius: number): LngLat[][] {
  if (radius <= 0) return [coordinates]
  const runs: LngLat[][] = []
  let run: LngLat[] = []
  let previous: LngLat | undefined
  let previousOutside = false
  for (const point of coordinates) {
    const outside = metresBetween(centre, point) >= radius
    if (previous && outside !== previousOutside) {
      run.push(outside ? crossingPoint(previous, point, centre, radius) : crossingPoint(point, previous, centre, radius))
    }
    if (outside) {
      run.push(point)
    } else {
      if (run.length >= 2) runs.push(run)
      run = []
    }
    previous = point
    previousOutside = outside
  }
  if (run.length >= 2) runs.push(run)
  return runs
}

/**
 * Where the segment from a point inside the circle to one outside it crosses
 * the boundary. Bisected rather than solved: the segment is short, twenty-four
 * halvings put it well inside a millimetre, and keeping `inside` inside and
 * `outside` outside makes the answer obviously the right root.
 */
function crossingPoint(inside: LngLat, outside: LngLat, centre: LngLat, radius: number): LngLat {
  let low = 0
  let high = 1
  const at = (t: number): LngLat => [inside[0] + (outside[0] - inside[0]) * t, inside[1] + (outside[1] - inside[1]) * t]
  for (let step = 0; step < 24; step++) {
    const mid = (low + high) / 2
    if (metresBetween(centre, at(mid)) < radius) low = mid
    else high = mid
  }
  return at(high)
}

/** Flat-earth enough over the tens of metres this is asked about. */
function metresBetween(a: LngLat, b: LngLat): number {
  const north = (b[1] - a[1]) * 111320
  const east = (b[0] - a[0]) * 111320 * Math.cos((a[1] * Math.PI) / 180)
  return Math.hypot(north, east)
}

function explodeToPolygons(shape: AnyPolygon): Feature<Polygon>[] {
  if (shape.geometry.type === 'Polygon') return [feature(shape.geometry) as Feature<Polygon>]
  return shape.geometry.coordinates.map(rings => feature({ type: 'Polygon', coordinates: rings }) as Feature<Polygon>)
}

/**
 * A small avoidance disc around one point.
 *
 * Used to push a leg off a short dead-end branch: circle the tip the walk
 * backtracked from and hand it to a reroute the same way an already-walked
 * corridor is avoided, rather than teaching the router a second mechanism.
 */
export function buildSpikeAvoidanceArea(tip: LngLat, radiusMetres: number): Feature<Polygon> {
  return circle(tip, radiusMetres, { units: 'meters', steps: 16 }) as Feature<Polygon>
}

export type CustomModel = {
  priority?: Array<Record<string, string>>
  areas?: { type: 'FeatureCollection'; features: Feature<Polygon>[] }
  /**
   * GraphHopper adds `distance * distance_influence / 1000` to an edge's
   * weight. Large enough, and that term dominates the profile's own
   * preferences, so the route returned is very nearly the shortest one on the
   * ground rather than the one the profile likes best.
   */
  distance_influence?: number
}

/**
 * A model that asks for the shortest walk rather than the nicest one.
 *
 * Looper's profile expresses preferences as priority multipliers at or below
 * one, and GraphHopper divides by priority — so the route it returns can be
 * physically longer than the shortest path, and is therefore *not* a lower
 * bound on how far a walk through some places must be. Anything that refuses
 * a walker's request for being too long needs a real floor, and this is how
 * one is asked for. See docs/routing-baseline.md §7.
 *
 * "Very nearly" rather than "exactly": the preference term does not vanish, it
 * is only outweighed. Callers apply a tolerance on top rather than treating
 * the answer as exact.
 */
export const LOWER_BOUND_DISTANCE_INFLUENCE = 2000

export const shortestPathCustomModel = (): CustomModel => ({ distance_influence: LOWER_BOUND_DISTANCE_INFLUENCE })

/**
 * The GraphHopper custom model that discourages the corridors. Area ids must be
 * referenced as `in_<id>` inside the condition, which is why they are named
 * here rather than by the caller.
 */
export function avoidanceCustomModel(areas: Feature<Polygon>[], priority: number = AVOID_PRIORITY): CustomModel | undefined {
  if (!areas.length) return undefined
  const named = areas.map((polygon, index) => ({ ...polygon, id: `looper_avoid_${index}`, properties: polygon.properties ?? {} }))
  // One rule naming every corridor, not one rule each.
  //
  // GraphHopper applies each matching rule in turn, so a rule per corridor
  // multiplies the penalty once for every corridor an edge falls in — and
  // corridors overlap wherever the walk crosses its own path. Ground walked
  // twice would be discouraged four hundredfold instead of twentyfold, which
  // is not the strength this was tuned at. Naming them in one expression says
  // what was always meant: this ground has been walked, once.
  return {
    priority: [{ if: named.map(polygon => `in_${polygon.id}`).join(' || '), multiply_by: String(priority) }],
    areas: { type: 'FeatureCollection', features: named },
  }
}
