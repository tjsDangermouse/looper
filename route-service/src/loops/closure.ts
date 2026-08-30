import { haversine, type LngLat } from './geo.js'

/**
 * A deliberately small, local estimate of the network cost of returning home.
 *
 * This is not a geographic model.  It only uses the stretch that this
 * candidate has already observed, then bounds that observation so one bad
 * leg cannot make the remaining plan collapse.  The bounds are options rather
 * than hidden constants because Phase 4's corpus is responsible for choosing
 * the retained range.
 */
export type ClosureEstimatorOptions = {
  globalStretch?: number
  minStretch?: number
  maxStretch?: number
}

export type ClosureEstimate = {
  crowMetres: number
  stretch: number
  metres: number
  source: 'global' | 'candidate-local'
}

export const DEFAULT_CLOSURE_ESTIMATOR: Required<ClosureEstimatorOptions> = {
  // The existing network-aware seed fallback uses the same neutral multiplier.
  // It is only used before this candidate has a routed leg of its own.
  globalStretch: 1.35,
  minStretch: 1.05,
  maxStretch: 2.25,
}

export type ObservedLeg = { distanceMeters: number; coordinates: LngLat[] }

export function median(values: number[]): number {
  if (!values.length) return 0
  const sorted = [...values].sort((a, b) => a - b)
  const middle = Math.floor(sorted.length / 2)
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
}

export function observedStretch(legs: ObservedLeg[]): number[] {
  return legs.flatMap(leg => {
    const first = leg.coordinates[0]
    const last = leg.coordinates.at(-1)
    if (!first || !last) return []
    const crow = haversine(first, last)
    // Very short joins are numerically noisy and tell us nothing useful about
    // the reach of a later closing leg.
    return crow >= 20 && Number.isFinite(leg.distanceMeters) && leg.distanceMeters > 0
      ? [leg.distanceMeters / crow]
      : []
  })
}

export function estimateClosure(
  start: LngLat,
  from: LngLat,
  legs: ObservedLeg[],
  options: ClosureEstimatorOptions = {},
): ClosureEstimate {
  const settings = { ...DEFAULT_CLOSURE_ESTIMATOR, ...options }
  const ratios = observedStretch(legs)
  const raw = ratios.length ? median(ratios) : settings.globalStretch
  const stretch = Math.max(settings.minStretch, Math.min(settings.maxStretch, raw))
  const crowMetres = haversine(from, start)
  return {
    crowMetres,
    stretch,
    metres: crowMetres * stretch,
    source: ratios.length ? 'candidate-local' : 'global',
  }
}
