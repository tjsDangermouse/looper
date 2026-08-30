import { destination, haversine, normaliseBearing, type LngLat } from './geo.js'
import { DEFAULT_CLOSURE_ESTIMATOR, observedStretch, median, type ObservedLeg } from './closure.js'

/**
 * The cheap geometric object Phase 5 measures. It is deliberately ignorant of
 * GraphHopper: all remaining corner guides are laid out at the current
 * equal-share radius, then the last point is joined to the start.
 */
export type RemainingShape = {
  points: LngLat[]
  segmentMetres: number[]
  crowMetres: number
}

export type FullShapeEstimates = {
  f0: number
  f1: number
  f2: number
  f3: number
  localStretch: number
  blendedStretch: number
  completedLegs: number
}

export const NEUTRAL_NETWORK_STRETCH = 1.35

export function constructRemainingShape(
  start: LngLat,
  from: LngLat,
  remainingCornerLegs: number,
  radiusMetres: number,
  heading: number,
  direction: 'clockwise' | 'counter-clockwise',
  cornerCount: number,
): RemainingShape {
  const turn = direction === 'clockwise' ? 1 : -1
  const turnDegrees = turn * 360 / (cornerCount + 1)
  const points: LngLat[] = [from]
  let current = from
  let currentHeading = heading
  for (let index = 0; index < remainingCornerLegs; index++) {
    current = destination(current, Math.max(0, radiusMetres), currentHeading)
    points.push(current)
    currentHeading = normaliseBearing(currentHeading + turnDegrees)
  }
  points.push(start)
  const segmentMetres = points.slice(1).map((point, index) => haversine(points[index], point))
  return { points, segmentMetres, crowMetres: segmentMetres.reduce((sum, metres) => sum + metres, 0) }
}

/** F0–F3 as specified by Phase 5. All returned values are complete-loop metres. */
export function estimateFullShape(
  distanceUsed: number,
  shape: RemainingShape,
  completedLegs: ObservedLeg[],
): FullShapeEstimates {
  const ratios = observedStretch(completedLegs)
  const unclampedLocal = ratios.length ? median(ratios) : NEUTRAL_NETWORK_STRETCH
  const localStretch = Math.max(
    DEFAULT_CLOSURE_ESTIMATOR.minStretch,
    Math.min(DEFAULT_CLOSURE_ESTIMATOR.maxStretch, unclampedLocal),
  )
  // Two neutral pseudo-observations prevent one early routed leg from taking
  // complete control. Confidence then rises deterministically with evidence.
  const confidence = ratios.length / (ratios.length + 2)
  const blendedStretch = NEUTRAL_NETWORK_STRETCH * (1 - confidence) + localStretch * confidence
  const complete = (stretch: number) => distanceUsed + shape.crowMetres * stretch
  return {
    f0: complete(1),
    f1: complete(NEUTRAL_NETWORK_STRETCH),
    f2: complete(localStretch),
    f3: complete(blendedStretch),
    localStretch,
    blendedStretch,
    completedLegs: ratios.length,
  }
}
