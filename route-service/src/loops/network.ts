import { bearingBetween, haversine, normaliseBearing, type LngLat } from './geo.js'
import type { LoopAttempt } from './candidates.js'

/**
 * What the network can actually reach.
 *
 * The candidate generator aims bearings round the compass and finds out
 * whether each one works by routing four legs and measuring the result. On a
 * seafront that means half of every batch is spent discovering the sea; on a
 * headland, or a town on one side of a river with a single bridge, it means
 * most of it.
 *
 * One reachability query answers that before any of it is dispatched: walk the
 * network outwards from the start until the walk budget runs out, and see
 * which directions have anything in them and how far the network stretches a
 * straight line in each. That is not a shortcut around routing — it is the
 * same question the batch was going to answer expensively, asked once.
 *
 * Everything here is a *preference*. A sector the summary calls empty is
 * pushed to the back of the queue, never removed: the summary is a sample of a
 * network at one budget, and a generator that refuses to look somewhere
 * because a probe was thin there is a generator that stops finding the
 * awkward, interesting loops.
 */

/** One reachable point, as the engine reported it. */
export type ReachedPoint = { point: LngLat; networkMetres: number }

export type NetworkSector = {
  /** Centre of the sector, degrees clockwise from north. */
  bearing: number
  /** Furthest the network goes in this sector, as network distance. */
  reachMetres: number
  /**
   * How much further the network makes you walk than the crow flies, in this
   * direction. Straight-line distance is never proportional to routed distance
   * and is least proportional exactly where it matters — round a harbour, up a
   * valley, along a river with one bridge.
   */
  stretch: number
  /** How many probe points landed here; a thin sector is a weak signal. */
  samples: number
}

export type NetworkSummary = {
  sectors: NetworkSector[]
  /** Sector width in degrees. */
  sectorDegrees: number
  /** Median stretch across every sector with anything in it. */
  medianStretch: number
  /** Total points the probe returned, for metrics and for judging confidence. */
  samples: number
}

/** Sectors this wide: fine enough to see a river, coarse enough to be robust. */
export const SECTOR_DEGREES = 30
/**
 * How far out a loop of a given length needs the network to go.
 *
 * A ring of circumference `C` has radius `C / 2π`, about 0.16 of the length.
 * A loop built as legs out and back is less demanding than that in the
 * direction it sets off in, so the bar is set below the ring radius: this is
 * "is there anything usable this way", not "will a perfect circle fit".
 */
export const REACH_SHARE_OF_TARGET = 0.12
/**
 * A sector with fewer probe points than this is not evidence of anything. A
 * shortest-path tree thins out at its edges, and the far corner of a sector
 * legitimately holds a handful of points.
 */
export const MIN_SECTOR_SAMPLES = 3

/**
 * Turn a shortest-path tree into per-sector reach. Pure, so the awkward
 * geographies can be tested without an engine: the interesting cases are all
 * about what the *summary* says, not about how it was fetched.
 */
export function summariseNetwork(start: LngLat, reached: ReachedPoint[], sectorDegrees = SECTOR_DEGREES): NetworkSummary {
  const count = Math.max(1, Math.round(360 / sectorDegrees))
  const width = 360 / count
  const sectors: NetworkSector[] = Array.from({ length: count }, (_, index) => ({
    bearing: normaliseBearing((index + 0.5) * width),
    reachMetres: 0,
    stretch: 1,
    samples: 0,
  }))
  const stretchTotals = new Float64Array(count)

  for (const { point, networkMetres } of reached) {
    const crow = haversine(start, point)
    // A point on the doorstep has no meaningful bearing and an unstable
    // stretch: dividing a few metres of network by a few metres of crow flight
    // amplifies snapping noise into a claim about the neighbourhood.
    if (crow < 50 || !(networkMetres > 0)) continue
    const index = Math.floor(normaliseBearing(bearingBetween(start, point)) / width) % count
    const sector = sectors[index]
    sector.samples++
    stretchTotals[index] += networkMetres / crow
    if (networkMetres > sector.reachMetres) sector.reachMetres = networkMetres
  }

  const stretches: number[] = []
  for (let index = 0; index < count; index++) {
    if (!sectors[index].samples) continue
    sectors[index].stretch = stretchTotals[index] / sectors[index].samples
    stretches.push(sectors[index].stretch)
  }
  stretches.sort((a, b) => a - b)

  return {
    sectors,
    sectorDegrees: width,
    medianStretch: stretches.length ? stretches[Math.floor(stretches.length / 2)] : 1,
    samples: reached.length,
  }
}

/** The sector a bearing falls in. */
export function sectorFor(summary: NetworkSummary, bearing: number): NetworkSector {
  const index = Math.floor(normaliseBearing(bearing) / summary.sectorDegrees) % summary.sectors.length
  return summary.sectors[index]
}

/** Whether a bearing has enough network in it to be worth a candidate's four legs. */
export function bearingIsPromising(summary: NetworkSummary, bearing: number, targetMetres: number): boolean {
  const sector = sectorFor(summary, bearing)
  if (sector.samples < MIN_SECTOR_SAMPLES) return false
  return sector.reachMetres >= targetMetres * REACH_SHARE_OF_TARGET
}

/**
 * How many of the unpromising bearings are still tried, and in what order.
 *
 * Not zero. The probe is one query at one budget against a network the service
 * does not otherwise model, and a sector it calls empty is sometimes a sector
 * whose one path starts thirty metres further along the road. Keeping a
 * quarter of them, at the back of the queue where the early stop usually never
 * reaches them, costs almost nothing and means a wrong summary loses the
 * walker some speed rather than a whole direction.
 */
export const EXPLORATION_SHARE = 0.25

/**
 * Reorder attempts so the ones aimed at real network go first.
 *
 * Deliberately a reordering and not a filter. Every attempt the generator was
 * going to make is still in the list, in a deterministic order; what changes
 * is which ones get dispatched before the batch has what it needs.
 */
export function biasAttemptsToNetwork(
  attempts: LoopAttempt[],
  summary: NetworkSummary,
  targetMetres: number,
): LoopAttempt[] {
  const promising: LoopAttempt[] = []
  const unpromising: LoopAttempt[] = []
  for (const attempt of attempts) {
    (bearingIsPromising(summary, attempt.initialBearing, targetMetres) ? promising : unpromising).push(attempt)
  }
  // Nothing looked promising: the probe told us nothing useful about this
  // start, so the original order is the better guess.
  if (!promising.length) return attempts

  const keptForExploration = Math.max(2, Math.round(unpromising.length * EXPLORATION_SHARE))
  const explore = unpromising.slice(0, keptForExploration)
  const rest = unpromising.slice(keptForExploration)
  return [...promising, ...explore, ...rest].map((attempt, index) => ({ ...attempt, index }))
}
