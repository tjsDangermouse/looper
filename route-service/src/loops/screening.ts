import { boundingBoxSides, compactness, haversine, type LngLat } from './geo.js'
import { bearingOctant } from './diversity.js'

/**
 * Looking before paying.
 *
 * Building one candidate properly costs a dozen engine calls: a leg at a time,
 * each with its own avoidance corridor, its own retries, and its own fix-ups
 * for dead ends. On easy ground that is money well spent. On ground where most
 * bearings do not work at all — a sparse rural lattice, a headland — it is
 * twelve calls to discover something one call could have shown.
 *
 * So: route the bare ring first, in a single request with no avoidance and no
 * repair, and look at what comes back. It is not the walk that would be built
 * — the real one avoids its own ground and is usually better — but it is drawn
 * from the same streets, and a bearing whose bare ring comes back three times
 * too long, or barely leaves the doorstep, is not going to be rescued by
 * avoidance corridors.
 *
 * The screen is therefore deliberately loose. Its job is to notice the
 * hopeless, not to judge the promising; anything it is unsure about survives,
 * because the cost of wrongly discarding a bearing is a walk the walker never
 * sees, and the cost of wrongly keeping one is a dozen calls.
 */

export type Skeleton = {
  /** Which attempt this screened, so the refinement stage can rebuild it. */
  attemptId: string
  bearing: number
  coordinates: LngLat[]
  distanceMeters: number
}

export type ScreenVerdict = {
  keep: boolean
  /** Why it was dropped, for metrics. Absent when it was kept. */
  reason?: 'far-too-long' | 'far-too-short' | 'no-shape' | 'never-left'
  /** Higher is better. Only meaningful for a skeleton that was kept. */
  score: number
  octant: number
}

export type ScreenThresholds = {
  /**
   * The bare ring may be this many times the target and still be worth
   * building properly. Generous on purpose: the real build aims each leg
   * against a running budget and routinely brings a ring that came back half
   * again too long back inside the gate.
   */
  maxLengthRatio: number
  /**
   * And this small. A ring that came back well under its target has usually
   * hit something it cannot get round, and avoidance corridors only make a
   * route longer, never shorter — so a short bare ring stays short.
   */
  minLengthRatio: number
  /**
   * Enclosed area against a circle of the same length. Far below the quality
   * gate's own floor: this is "did the ring collapse onto itself", not "is
   * this a handsome walk".
   */
  minCompactness: number
  /** Longest side over shortest. A bare ring this thin is a there-and-back. */
  maxBoundingBoxRatio: number
  /** A ring that never got this far from the door did not find a loop. */
  minReachMetres: number
}

export const DEFAULT_SCREEN_THRESHOLDS: ScreenThresholds = {
  maxLengthRatio: 1.9,
  minLengthRatio: 0.45,
  minCompactness: 0.06,
  maxBoundingBoxRatio: 9,
  minReachMetres: 100,
}

/**
 * Judge one bare ring. Pure, and deliberately cheap: everything here is read
 * off the geometry that already came back.
 */
export function screenSkeleton(
  skeleton: Skeleton,
  start: LngLat,
  targetMetres: number,
  thresholds: Partial<ScreenThresholds> = {},
): ScreenVerdict {
  const limits: ScreenThresholds = { ...DEFAULT_SCREEN_THRESHOLDS, ...thresholds }
  const octant = bearingOctant(skeleton.bearing)
  const drop = (reason: ScreenVerdict['reason']): ScreenVerdict => ({ keep: false, reason, score: 0, octant })

  const ratio = targetMetres > 0 ? skeleton.distanceMeters / targetMetres : 0
  if (ratio > limits.maxLengthRatio) return drop('far-too-long')
  if (ratio < limits.minLengthRatio) return drop('far-too-short')

  const furthest = skeleton.coordinates.reduce((far, point) => Math.max(far, haversine(start, point)), 0)
  if (furthest < limits.minReachMetres) return drop('never-left')

  const shape = compactness(skeleton.coordinates)
  const { longMetres, shortMetres } = boundingBoxSides(skeleton.coordinates)
  const elongation = shortMetres > 0 ? longMetres / shortMetres : Infinity
  if (shape < limits.minCompactness || elongation > limits.maxBoundingBoxRatio) return drop('no-shape')

  // Closeness to the requested length first, then how much ground it encloses.
  // Both are cheap proxies for what the quality engine will decide properly.
  const closeness = 1 - Math.min(1, Math.abs(ratio - 1))
  return { keep: true, score: closeness * 0.6 + Math.min(1, shape / 0.4) * 0.4, octant }
}

/**
 * Which of the surviving skeletons to spend the expensive stage on.
 *
 * Best first, but never more than a couple from the same direction: three
 * excellent bearings all heading north-east is one walk to offer, and the
 * whole point of screening cheaply is being able to afford to look elsewhere.
 */
export function pickForRefinement<T>(
  screened: Array<{ item: T; verdict: ScreenVerdict }>,
  limit: number,
  perOctant = 2,
): T[] {
  const ranked = screened
    .filter(entry => entry.verdict.keep)
    .sort((a, b) => b.verdict.score - a.verdict.score)
  const taken = new Map<number, number>()
  const chosen: T[] = []

  for (const pass of [perOctant, Infinity]) {
    for (const entry of ranked) {
      if (chosen.length >= limit) return chosen
      if (chosen.includes(entry.item)) continue
      const already = taken.get(entry.verdict.octant) ?? 0
      if (already >= pass) continue
      taken.set(entry.verdict.octant, already + 1)
      chosen.push(entry.item)
    }
  }
  return chosen
}
