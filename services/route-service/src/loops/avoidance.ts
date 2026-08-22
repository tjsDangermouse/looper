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

  let merged: AnyPolygon | null = corridors.length === 1
    ? corridors[0]
    : (union(featureCollection(corridors as never)) as AnyPolygon | null)
  if (!merged) return []

  if (exclusion > 0) {
    const keepClear = circle(start, exclusion, { units: 'meters', steps: 32 })
    merged = (difference(featureCollection([merged, keepClear] as never)) as AnyPolygon | null)
    // The whole corridor sitting inside the start circle is a legitimate
    // outcome for a very short first leg: there is then nothing to avoid.
    if (!merged) return []
  }

  return explodeToPolygons(merged)
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

function explodeToPolygons(shape: AnyPolygon): Feature<Polygon>[] {
  if (shape.geometry.type === 'Polygon') return [feature(shape.geometry) as Feature<Polygon>]
  return shape.geometry.coordinates.map(rings => feature({ type: 'Polygon', coordinates: rings }) as Feature<Polygon>)
}

export type CustomModel = {
  priority?: Array<Record<string, string>>
  areas?: { type: 'FeatureCollection'; features: Feature<Polygon>[] }
}

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
