import buffer from '@turf/buffer'
import circle from '@turf/circle'
import difference from '@turf/difference'
import union from '@turf/union'
import simplify from '@turf/simplify'
import area from '@turf/area'
import { featureCollection, lineString, feature } from '@turf/helpers'
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
    const buffered = buffer(lineString(distinct), halfWidth, { units: 'meters' })
    if (buffered) corridors.push(buffered as AnyPolygon)
  }
  if (!corridors.length) return []

  // Merging is an optimisation — fewer, larger areas in the request — not a
  // requirement. Where it cannot be done, the separate corridors describe
  // exactly the same ground and are sent as they are.
  const merged = corridors.length === 1 ? corridors : (tryUnion(corridors) ?? corridors)

  const keepClear = exclusion > 0 ? circle(start, exclusion, { units: 'meters', steps: 32 }) : undefined
  const shapes = keepClear
    // A corridor entirely inside the start circle is a legitimate outcome for
    // a very short first leg: there is then nothing left of it to avoid.
    ? merged.flatMap(shape => { const cut = trySubtract(shape, keepClear); return cut ? [cut] : [] })
    : merged

  return shapes
    .flatMap(explodeToPolygons)
    .map(polygon => simplify(polygon, { tolerance: SIMPLIFY_TOLERANCE_DEGREES, highQuality: false, mutate: true }))
    .filter(polygon => polygon.geometry.coordinates.length > 0 && polygon.geometry.coordinates[0].length >= 4)
    .sort((a, b) => area(b) - area(a))
    .slice(0, maxAreas)
}

/**
 * Polygon clipping is not total.
 *
 * A walk that doubles back along exactly the same line — the only bridge, a
 * promenade with no second path — buffers into two corridors sharing a whole
 * edge, and the clipping library can fail outright on that degeneracy rather
 * than returning a shape. Letting it throw would abandon the entire request
 * over one candidate's geometry, which is the opposite of what an avoidance
 * hint is for: it is a preference, and a preference that cannot be expressed
 * is not an error, it is a weaker preference.
 */
function tryUnion(corridors: AnyPolygon[]): AnyPolygon[] | undefined {
  try {
    const merged = union(featureCollection(corridors as never)) as AnyPolygon | null
    return merged ? [merged] : undefined
  } catch {
    return undefined
  }
}

/** As `tryUnion`: a start circle that cannot be cut out simply is not cut out. */
function trySubtract(shape: AnyPolygon, keepClear: AnyPolygon): AnyPolygon | undefined {
  try {
    return (difference(featureCollection([shape, keepClear] as never)) as AnyPolygon | null) ?? undefined
  } catch {
    return shape
  }
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
  return {
    priority: named.map(polygon => ({ if: `in_${polygon.id}`, multiply_by: String(priority) })),
    areas: { type: 'FeatureCollection', features: named },
  }
}
