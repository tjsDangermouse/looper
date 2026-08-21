// Candidate generation. ORS `round_trip` picks its own shape from a seed and
// will happily send you down a lane and back out of it; instead we decide the
// shape ourselves — a triangle of waypoints around the start — and let ORS do
// only the part it is good at, which is joining four points by footpath.
import { destination, type Point } from './geo.js'

export type Candidate = { index: number; waypoints: Point[]; radiusMetres: number; baseAngle: number }

/** A start point plus a target length should always give the same walks, so the
 *  randomness is seeded from exactly those. mulberry32: small, fast, and even
 *  enough in the low bits for angles and radii. */
export function seededRandom(seed: number) {
  let state = seed >>> 0
  return () => {
    state = (state + 0x6d2b79f5) >>> 0
    let t = Math.imul(state ^ (state >>> 15), 1 | state)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

/** Stable across processes and deploys — no Math.random, no clock. Rounded to
 *  ~11 m of start position so a jittery GPS fix does not reshuffle the results. */
export function seedFor(start: Point, targetMetres: number) {
  const text = `${start[0].toFixed(4)},${start[1].toFixed(4)},${Math.round(targetMetres)}`
  let hash = 2166136261
  for (let i = 0; i < text.length; i++) { hash ^= text.charCodeAt(i); hash = Math.imul(hash, 16777619) }
  return hash >>> 0
}

// A loop out to a ring, around three sides of it and back covers roughly 8.3
// radii of ground, so this inverts that to size the ring for a target length.
export const RADIUS_DIVISOR = 8.3
export const radiusFor = (targetMetres: number) => targetMetres / RADIUS_DIVISOR
export const RADIUS_BAND: [number, number] = [.85, 1.3]

/** Three outer waypoints at ~120° apart. The order is the walking order, and
 *  ORS must not reorder it (`optimized: false`) — the sequence is the only
 *  thing making the route go round rather than out and back. */
export function ringWaypoints(start: Point, radiusMetres: number, baseAngle: number, jitter: number[]): Point[] {
  return [0, 120, 240].map((offset, i) => destination(start, radiusMetres * (jitter[i] ?? 1), (baseAngle + offset) % 360))
}

/** `count` rings spread over the compass so the pool holds walks in genuinely
 *  different directions before quality ever gets a say. */
export function generateCandidates(start: Point, targetMetres: number, count = 18, seed = seedFor(start, targetMetres)): Candidate[] {
  const random = seededRandom(seed), base = radiusFor(targetMetres)
  return Array.from({ length: count }, (_, index) => {
    // Even spread plus a nudge: without the spread, seeds cluster and half the
    // pool heads the same way; without the nudge, every search looks identical.
    const baseAngle = ((index * 360 / count + (random() - .5) * (360 / count)) % 360 + 360) % 360
    // The band is centred slightly above the geometric estimate: measured
    // against real ORS output the plain estimate lands about a tenth short,
    // because streets never take the straight line between two waypoints.
    const radiusMetres = base * (RADIUS_BAND[0] + random() * (RADIUS_BAND[1] - RADIUS_BAND[0]))
    const jitter = [0, 1, 2].map(() => .85 + random() * .3) // ±15% per waypoint
    return { index, waypoints: ringWaypoints(start, radiusMetres, baseAngle, jitter), radiusMetres, baseAngle }
  })
}

/** The coordinate list sent to ORS: start, the ring in order, then start again. */
export const routeCoordinates = (start: Point, waypoints: Point[]): Point[] => [start, ...waypoints, start]

/** Time input is converted at a plain 5 km/h; the honest duration comes back
 *  from ORS afterwards and is what the route is finally judged on. */
export const WALKING_METRES_PER_SECOND = 5000 / 3600
export const metresFromMinutes = (minutes: number) => minutes * 60 * WALKING_METRES_PER_SECOND
export const minutesFromMetres = (metres: number) => metres / WALKING_METRES_PER_SECOND / 60
