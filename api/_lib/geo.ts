// Geodesic helpers. Everything downstream works in metres, so the one job here
// is turning lng/lat into a local metric plane and back without the naive
// "one degree is 111 km in both directions" mistake that skews rings at
// latitude — Douglas is at 54°N, where a degree of longitude is 40% shorter.
export type Point = [number, number]

export const EARTH = 6371000
export const RAD = Math.PI / 180

export const haversine = (a: Point, b: Point) => {
  const dLat = (b[1] - a[1]) * RAD, dLng = (b[0] - a[0]) * RAD
  const x = Math.sin(dLat / 2) ** 2 + Math.cos(a[1] * RAD) * Math.cos(b[1] * RAD) * Math.sin(dLng / 2) ** 2
  return 2 * EARTH * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x))
}

/** Great-circle destination: travel `distanceMetres` from `origin` on `bearingDegrees`
 *  (0 = north, clockwise). This is what places a waypoint ring accurately. */
export function destination(origin: Point, distanceMetres: number, bearingDegrees: number): Point {
  const [lng, lat] = origin
  const delta = distanceMetres / EARTH, theta = bearingDegrees * RAD
  const phi1 = lat * RAD, lambda1 = lng * RAD
  const sinPhi2 = Math.sin(phi1) * Math.cos(delta) + Math.cos(phi1) * Math.sin(delta) * Math.cos(theta)
  const phi2 = Math.asin(Math.min(1, Math.max(-1, sinPhi2)))
  const lambda2 = lambda1 + Math.atan2(Math.sin(theta) * Math.sin(delta) * Math.cos(phi1), Math.cos(delta) - Math.sin(phi1) * sinPhi2)
  return [((lambda2 / RAD + 540) % 360) - 180, phi2 / RAD]
}

export const bearing = (a: Point, b: Point) => {
  const phi1 = a[1] * RAD, phi2 = b[1] * RAD, dLambda = (b[0] - a[0]) * RAD
  const y = Math.sin(dLambda) * Math.cos(phi2)
  const x = Math.cos(phi1) * Math.sin(phi2) - Math.sin(phi1) * Math.cos(phi2) * Math.cos(dLambda)
  return (Math.atan2(y, x) / RAD + 360) % 360
}

/** Equirectangular metres about the route's own first point. Loops are at most
 *  20 km across, so distortion stays far below the ~15 m tolerances we test. */
export function project(coordinates: Point[]): Point[] {
  if (!coordinates.length) return []
  const scale = Math.cos(coordinates[0][1] * RAD)
  return coordinates.map(([lng, lat]) => [EARTH * lng * RAD * scale, EARTH * lat * RAD])
}

export const distanceBetween = (a: Point, b: Point) => Math.hypot(b[0] - a[0], b[1] - a[1])

export function pathLength(flat: Point[]) {
  let total = 0
  for (let i = 1; i < flat.length; i++) total += distanceBetween(flat[i - 1], flat[i])
  return total
}

export type Sample = { point: Point; bearing: number; along: number; length: number }

/** Walk the (projected) route laying down fixed-length samples. Even spacing is
 *  what lets the overlap scan compare "corridors" rather than raw ORS vertices,
 *  whose spacing swings from a metre to a hundred. */
export function resample(flat: Point[], step: number): Sample[] {
  const samples: Sample[] = []
  if (flat.length < 2 || step <= 0) return samples
  let along = 0, target = 0
  for (let i = 1; i < flat.length; i++) {
    const a = flat[i - 1], b = flat[i], length = distanceBetween(a, b)
    if (length <= 0) continue
    const heading = (Math.atan2(b[0] - a[0], b[1] - a[1]) / RAD + 360) % 360
    while (target < along + length) {
      const f = (target - along) / length
      samples.push({ point: [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f], bearing: heading, along: target, length: step })
      target += step
    }
    along += length
  }
  return samples
}

/** Smallest difference between two bearings, 0–180. */
export const bearingDelta = (a: number, b: number) => { const d = Math.abs(a - b) % 360; return d > 180 ? 360 - d : d }

/** A uniform grid over projected points. Overlap detection is O(n²) done naively
 *  and a 20 km route resampled at 15 m is well over a thousand samples. */
export class Grid {
  private cells = new Map<string, number[]>()
  constructor(private size: number) {}
  private key = (p: Point) => `${Math.floor(p[0] / this.size)},${Math.floor(p[1] / this.size)}`
  add(point: Point, index: number) {
    const key = this.key(point), bucket = this.cells.get(key)
    if (bucket) bucket.push(index); else this.cells.set(key, [index])
  }
  /** Indices in the nine cells around `point` — every sample within `size` metres. */
  near(point: Point) {
    const cx = Math.floor(point[0] / this.size), cy = Math.floor(point[1] / this.size), out: number[] = []
    for (let dx = -1; dx <= 1; dx++) for (let dy = -1; dy <= 1; dy++) {
      const bucket = this.cells.get(`${cx + dx},${cy + dy}`)
      if (bucket) out.push(...bucket)
    }
    return out
  }
}

/** Minimum-area oriented bounding box, by rotating calipers over 1° steps. An
 *  axis-aligned box calls any diagonal loop "narrow"; this measures the shape
 *  itself, which is what "a long line out and back" actually means. */
export function orientedExtent(flat: Point[]) {
  if (flat.length < 2) return { long: 0, short: 0, ratio: 1 }
  let best = { long: Infinity, short: Infinity, area: Infinity }
  for (let degrees = 0; degrees < 180; degrees++) {
    const angle = degrees * RAD, cos = Math.cos(angle), sin = Math.sin(angle)
    let minU = Infinity, maxU = -Infinity, minV = Infinity, maxV = -Infinity
    for (const [x, y] of flat) {
      const u = x * cos + y * sin, v = -x * sin + y * cos
      if (u < minU) minU = u; if (u > maxU) maxU = u
      if (v < minV) minV = v; if (v > maxV) maxV = v
    }
    const w = maxU - minU, h = maxV - minV, area = w * h
    if (area < best.area) best = { long: Math.max(w, h), short: Math.min(w, h), area }
  }
  return { long: best.long, short: best.short, ratio: best.short > 0 ? best.long / best.short : Infinity }
}
