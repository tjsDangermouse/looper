import { bearingBetween, normaliseBearing, pathLength, type LngLat } from './geo.js'
import { sharedCorridorMetres } from './quality.js'
import { sharedEdgeMetres, type EdgeTraversal } from './edges.js'

/**
 * Choosing what to offer.
 *
 * Three loops that all leave by the same street and differ by a block are one
 * choice wearing three hats. A candidate is dropped if it walks more than
 * MAX_SHARED_FRACTION of the same ground as one already chosen, and the
 * picker looks for a different way out of the door before it settles for a
 * second loop heading the same way.
 */

/**
 * In a town with a natural bottleneck — a harbour, a single bridge, a
 * headland — every clean loop leaves and returns the same way, whatever
 * direction it heads in between. Cutting at a third of shared ground threw
 * those away too and regularly left a walker with one loop where three
 * genuinely different ones existed but for a shared street at each end.
 */
export const MAX_SHARED_FRACTION = 0.55
/** How far into the walk "which way does this go" is decided. */
export const INITIAL_BEARING_METRES = 500
export const INITIAL_BEARING_FRACTION = 0.2

export const COMPASS_LABELS = [
  'North loop',
  'North-east loop',
  'East loop',
  'South-east loop',
  'South loop',
  'South-west loop',
  'West loop',
  'North-west loop',
] as const

/**
 * The bearing the walk sets off on, taken a few hundred metres in rather than
 * at the first vertex: the first thirty metres of any walk is whichever way the
 * pavement happens to run.
 */
export function initialBearing(coordinates: LngLat[], start: LngLat): number {
  if (coordinates.length < 2) return 0
  const target = Math.min(INITIAL_BEARING_METRES, pathLength(coordinates) * INITIAL_BEARING_FRACTION)
  let travelled = 0
  for (let i = 1; i < coordinates.length; i++) {
    travelled += distance(coordinates[i - 1], coordinates[i])
    if (travelled >= target) return bearingBetween(start, coordinates[i])
  }
  return bearingBetween(start, coordinates[coordinates.length - 1])
}

const distance = (a: LngLat, b: LngLat) => {
  const dLat = (b[1] - a[1]) * 111320
  const dLng = (b[0] - a[0]) * 111320 * Math.cos((a[1] * Math.PI) / 180)
  return Math.hypot(dLat, dLng)
}

export const bearingOctant = (bearing: number) => Math.round(normaliseBearing(bearing) / 45) % 8
export const bearingLabel = (bearing: number) => COMPASS_LABELS[bearingOctant(bearing)]

export type Selectable = {
  coordinates: LngLat[]
  quality: { score: number }
  bearing: number
  /**
   * The network edges this route walked, when the engine reported them.
   * Where both routes in a comparison have them, "the same ground" stops
   * being a question about proximity — see loops/edges.ts.
   */
  traversals?: EdgeTraversal[]
  /** Length of the route, needed to turn shared metres into a fraction. */
  totalMetres?: number
}

/**
 * How much of `a` runs along `b`, on the network where both routes know their
 * edges and by geometric proximity where either does not.
 *
 * Deliberately one-directional: a two-kilometre walk entirely contained in a
 * six-kilometre one shares all of itself and only a third of the other. Every
 * caller that needs a symmetric answer asks twice and takes the worse.
 */
export function sharedFraction(a: Selectable, b: Selectable): number {
  if (a.traversals?.length && b.traversals?.length && a.totalMetres) {
    return sharedEdgeMetres(a.traversals, b.traversals, a.totalMetres).fraction
  }
  return sharedCorridorMetres(a.coordinates, b.coordinates).fraction
}

/** The worse of the two directions: "are these the same walk" has no favourite. */
export const mutualSharedFraction = (a: Selectable, b: Selectable) =>
  Math.max(sharedFraction(a, b), sharedFraction(b, a))

/**
 * Best first, then the best that is a different walk from the ones already
 * taken. Two passes: the first insists on a different way out of the door, the
 * second accepts a same-bearing loop that is nonetheless different ground,
 * because two good loops beat one good loop and a rule.
 */
export function selectDiverseRoutes<T extends Selectable>(candidates: T[], limit = 3, maxShared = MAX_SHARED_FRACTION): T[] {
  return select(candidates, limit, maxShared, [true, false])
}

/**
 * The first pass on its own: only loops that leave by genuinely different
 * streets. This is what "we already have three good choices" means, and it is
 * a stricter question than the one `selectDiverseRoutes` finally answers —
 * which is the point. Stopping early on a set the second pass had to rescue
 * would be stopping on the worse answer.
 *
 * Deliberately the same code path, not a second implementation of it: two
 * subtly different diversity rules is exactly how a generator ends up
 * stopping on a set the selector then refuses.
 */
export function selectPreferredDiverseRoutes<T extends Selectable>(candidates: T[], limit = 3, maxShared = MAX_SHARED_FRACTION): T[] {
  return select(candidates, limit, maxShared, [true])
}

function select<T extends Selectable>(candidates: T[], limit: number, maxShared: number, passes: boolean[]): T[] {
  const ranked = [...candidates].sort((a, b) => b.quality.score - a.quality.score)
  const chosen: T[] = []
  const octants = new Set<number>()

  for (const requireNewOctant of passes) {
    for (const candidate of ranked) {
      if (chosen.length >= limit) break
      if (chosen.includes(candidate)) continue
      if (requireNewOctant && octants.has(bearingOctant(candidate.bearing))) continue
      const tooSimilar = chosen.some(other => mutualSharedFraction(candidate, other) > maxShared)
      if (tooSimilar) continue
      chosen.push(candidate)
      octants.add(bearingOctant(candidate.bearing))
    }
    if (chosen.length >= limit) break
  }
  return chosen
}

/**
 * Two loops that both head north-east would otherwise arrive with the same
 * name. Length is the thing the walker is choosing between, so that is what
 * separates them.
 */
export function labelRoutes(routes: Array<{ bearing: number; distanceMeters: number }>): string[] {
  const labels = routes.map(route => bearingLabel(route.bearing))
  return labels.map((label, index) => {
    const sameWay = labels
      .map((other, i) => ({ i, distance: routes[i].distanceMeters, other }))
      .filter(entry => entry.other === label)
    if (sameWay.length < 2) return label
    sameWay.sort((a, b) => a.distance - b.distance)
    const rank = sameWay.findIndex(entry => entry.i === index)
    if (rank === 0) return `Shorter ${label.toLowerCase()}`
    if (rank === sameWay.length - 1) return `Longer ${label.toLowerCase()}`
    return label
  })
}
