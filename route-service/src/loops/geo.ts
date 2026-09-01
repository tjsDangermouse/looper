/**
 * Geodesic and local-metric geometry.
 *
 * Waypoint rings are placed on the sphere with the proper direct-geodesic
 * formula: adding degrees to a longitude would squash every ring the further
 * north it sits, and Looper's first region is at 54°N where a degree of
 * longitude is already only 59% of a degree of latitude.
 *
 * Measuring, by contrast, happens in a local equirectangular projection about
 * the loop's own origin. Loops are at most a few kilometres across, so the
 * projection error stays far below the ~15 m resolution the quality engine
 * works at, and plane geometry is both faster and easier to reason about.
 */
export type LngLat = [number, number]

/** WGS84 mean radius, the same figure Turf uses. */
export const EARTH_RADIUS_METRES = 6371008.8
const RAD = Math.PI / 180

export const toRadians = (degrees: number) => degrees * RAD
export const toDegrees = (radians: number) => radians / RAD

/** Wrap to (-180, 180]. */
export const normaliseLongitude = (degrees: number) => ((degrees + 540) % 360) - 180
/** Wrap to [0, 360). */
export const normaliseBearing = (degrees: number) => ((degrees % 360) + 360) % 360

/**
 * The direct geodesic problem on a sphere: where do you end up walking
 * `distanceMetres` from `origin` on a constant bearing.
 */
export function destination(origin: LngLat, distanceMetres: number, bearingDegrees: number): LngLat {
  const angular = distanceMetres / EARTH_RADIUS_METRES
  const bearing = toRadians(bearingDegrees)
  const lat1 = toRadians(origin[1])
  const lng1 = toRadians(origin[0])
  const sinLat2 = Math.sin(lat1) * Math.cos(angular) + Math.cos(lat1) * Math.sin(angular) * Math.cos(bearing)
  const lat2 = Math.asin(Math.min(1, Math.max(-1, sinLat2)))
  const lng2 = lng1 + Math.atan2(
    Math.sin(bearing) * Math.sin(angular) * Math.cos(lat1),
    Math.cos(angular) - Math.sin(lat1) * sinLat2,
  )
  return [normaliseLongitude(toDegrees(lng2)), toDegrees(lat2)]
}

/** Initial great-circle bearing from `a` to `b`, in degrees clockwise from north. */
export function bearingBetween(a: LngLat, b: LngLat): number {
  const lat1 = toRadians(a[1])
  const lat2 = toRadians(b[1])
  const dLng = toRadians(b[0] - a[0])
  const y = Math.sin(dLng) * Math.cos(lat2)
  const x = Math.cos(lat1) * Math.sin(lat2) - Math.sin(lat1) * Math.cos(lat2) * Math.cos(dLng)
  return normaliseBearing(toDegrees(Math.atan2(y, x)))
}

export function haversine(a: LngLat, b: LngLat): number {
  const lat1 = toRadians(a[1])
  const lat2 = toRadians(b[1])
  const dLat = lat2 - lat1
  const dLng = toRadians(b[0] - a[0])
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2
  return 2 * EARTH_RADIUS_METRES * Math.asin(Math.min(1, Math.sqrt(h)))
}

export type Metric = [number, number]

/** Metres east/north of `origin`, for plane geometry over a single loop. */
export function projector(origin: LngLat): (point: LngLat) => Metric {
  const scale = Math.cos(toRadians(origin[1]))
  const lng0 = origin[0]
  const lat0 = origin[1]
  return ([lng, lat]) => [
    EARTH_RADIUS_METRES * toRadians(normaliseLongitude(lng - lng0)) * scale,
    EARTH_RADIUS_METRES * toRadians(lat - lat0),
  ]
}

export const distanceBetween = (a: Metric, b: Metric) => Math.hypot(b[0] - a[0], b[1] - a[1])

export function pathLength(coordinates: LngLat[]): number {
  let total = 0
  for (let i = 1; i < coordinates.length; i++) total += haversine(coordinates[i - 1], coordinates[i])
  return total
}

export type Sample = {
  /** Midpoint of the sample, in metres from the projection origin. */
  mid: Metric
  /** Unit vector along the sample. */
  direction: Metric
  /** Length of the sample in metres. */
  length: number
  /** Distance from the route start to the sample's midpoint. */
  along: number
}

/**
 * Cut a path into near-uniform samples so that two stretches of route can be
 * compared without either one's vertex spacing mattering. GraphHopper emits a
 * vertex per OSM node, which can be metres apart on a winding lane and hundreds
 * apart on a straight one.
 */
export function resample(coordinates: LngLat[], spacingMetres: number, origin?: LngLat): { samples: Sample[]; totalMetres: number } {
  if (coordinates.length < 2) return { samples: [], totalMetres: 0 }
  const project = projector(origin ?? coordinates[0])
  const flat = coordinates.map(project)
  const samples: Sample[] = []
  let carried = 0            // metres of the sample under construction so far
  let from: Metric = flat[0] // walking cursor along the input path
  let sampleStart: Metric = flat[0]
  let travelled = 0          // metres of completed samples

  for (let i = 1; i < flat.length; i++) {
    let remaining = distanceBetween(from, flat[i])
    while (remaining > 0 && carried + remaining >= spacingMetres) {
      const need = spacingMetres - carried
      const t = need / remaining
      const point: Metric = [from[0] + (flat[i][0] - from[0]) * t, from[1] + (flat[i][1] - from[1]) * t]
      samples.push(makeSample(sampleStart, point, travelled))
      travelled += spacingMetres
      sampleStart = point
      from = point
      remaining -= need
      carried = 0
    }
    carried += remaining
    from = flat[i]
  }
  // A trailing stub shorter than a third of the spacing is noise, not a sample.
  if (carried > spacingMetres / 3) samples.push(makeSample(sampleStart, from, travelled))
  return { samples, totalMetres: travelled + carried }
}

function makeSample(from: Metric, to: Metric, travelled: number): Sample {
  const length = distanceBetween(from, to) || 1e-9
  return {
    mid: [(from[0] + to[0]) / 2, (from[1] + to[1]) / 2],
    direction: [(to[0] - from[0]) / length, (to[1] - from[1]) / length],
    length,
    along: travelled + length / 2,
  }
}

/** Long and short sides of the route's bounding box, in metres. */
/** The furthest any point of the walk gets from the start, in metres. */
export function maxRadiusMetres(coordinates: LngLat[], start: LngLat): number {
  const project = projector(start)
  let radius = 0
  for (const point of coordinates) {
    const [x, y] = project(point)
    radius = Math.max(radius, Math.hypot(x, y))
  }
  return radius
}

export function boundingBoxSides(coordinates: LngLat[]): { longMetres: number; shortMetres: number } {
  if (coordinates.length < 2) return { longMetres: 0, shortMetres: 0 }
  const project = projector(coordinates[0])
  let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity
  for (const point of coordinates) {
    const [x, y] = project(point)
    if (x < minX) minX = x
    if (x > maxX) maxX = x
    if (y < minY) minY = y
    if (y > maxY) maxY = y
  }
  const width = maxX - minX
  const height = maxY - minY
  return { longMetres: Math.max(width, height), shortMetres: Math.min(width, height) }
}

/**
 * Isoperimetric quotient: 1 for a circle, 0 for a path that encloses nothing.
 * The measure of "is this a loop or is this a there-and-back".
 */
export function compactness(coordinates: LngLat[]): number {
  if (coordinates.length < 4) return 0
  const project = projector(coordinates[0])
  const flat = coordinates.map(project)
  let twiceArea = 0
  let perimeter = 0
  for (let i = 0; i < flat.length; i++) {
    const a = flat[i]
    const b = flat[(i + 1) % flat.length]
    twiceArea += a[0] * b[1] - b[0] * a[1]
    perimeter += distanceBetween(a, b)
  }
  if (perimeter <= 0) return 0
  return Math.min(1, (4 * Math.PI * Math.abs(twiceArea / 2)) / perimeter ** 2)
}
