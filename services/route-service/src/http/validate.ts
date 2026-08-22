import type { LoopOverrides, LoopRequest } from '../loops/generate.js'
import type { QualityThresholds } from '../loops/quality.js'

/**
 * Input validation.
 *
 * Messages here are written for a walker, not a developer: they say what to do
 * about it. Nothing about the routing engine, the provider, or the shape of the
 * JSON leaks through to the app.
 */

export class ValidationError extends Error {
  constructor(message: string, readonly field: string) {
    super(message)
    this.name = 'ValidationError'
  }
}

export const MIN_DISTANCE_KM = 0.5
export const MAX_DISTANCE_KM = 30
export const MIN_DURATION_MINUTES = 10
export const MAX_DURATION_MINUTES = 360
export const MAX_VARIATION = 999

export function parseLoopRequest(body: unknown): LoopRequest {
  if (!body || typeof body !== 'object') throw new ValidationError('Send a valid route request.', 'body')
  const input = body as Record<string, any>

  const start = input.start
  const lng = Number(start?.lng)
  const lat = Number(start?.lat)
  if (!Number.isFinite(lng) || !Number.isFinite(lat) || Math.abs(lng) > 180 || Math.abs(lat) > 90) {
    throw new ValidationError('Choose a valid starting point.', 'start')
  }

  const mode = input.mode
  if (mode !== 'distance' && mode !== 'time') throw new ValidationError('Choose a distance or a time.', 'mode')

  const units = input.units === 'mi' ? 'mi' : input.units === 'km' ? 'km' : undefined
  if (!units) throw new ValidationError('Choose kilometres or miles.', 'units')

  let distanceKm: number | undefined
  let durationMinutes: number | undefined
  if (mode === 'distance') {
    distanceKm = Number(input.distanceKm)
    if (!Number.isFinite(distanceKm) || distanceKm < MIN_DISTANCE_KM || distanceKm > MAX_DISTANCE_KM) {
      throw new ValidationError(`Choose a loop between ${MIN_DISTANCE_KM} and ${MAX_DISTANCE_KM} km.`, 'distanceKm')
    }
  } else {
    durationMinutes = Number(input.durationMinutes)
    if (!Number.isFinite(durationMinutes) || durationMinutes < MIN_DURATION_MINUTES || durationMinutes > MAX_DURATION_MINUTES) {
      throw new ValidationError(`Choose between ${MIN_DURATION_MINUTES} minutes and ${MAX_DURATION_MINUTES / 60} hours.`, 'durationMinutes')
    }
  }

  const rawVariation = input.variation === undefined || input.variation === null ? 0 : Number(input.variation)
  if (!Number.isFinite(rawVariation) || rawVariation < 0 || rawVariation > MAX_VARIATION) {
    throw new ValidationError('Ask for a different set of loops.', 'variation')
  }

  return {
    start: { lng, lat },
    mode,
    distanceKm,
    durationMinutes,
    units,
    variation: Math.trunc(rawVariation),
    overrides: parseOverrides(input.overrides),
  }
}

/**
 * The tuning panel's knobs. Never sent by the ordinary app — only by
 * whoever opens `?debug=1` on purpose — so validation here is about not
 * crashing the service on a stray value while dragging a slider, not about
 * defending against a hostile caller the way the fields above do.
 */
const OVERRIDE_RANGES = {
  maxDistanceError: [0, 2],
  maxDurationError: [0, 2],
  maxRepeatedFraction: [0, 1],
  maxUTurns: [0, 10],
  maxLegShare: [0, 1],
  minLegShare: [0, 1],
  maxBoundingBoxRatio: [1, 30],
  minCompactness: [0, 1],
  maxStartStubMetres: [0, 3000],
  maxOutAndBackSpurMetres: [0, 3000],
  maxOutAndBackSpurShare: [0, 1],
} satisfies Record<keyof QualityThresholds, [number, number]>

function clamp(value: unknown, [low, high]: [number, number]): number | undefined {
  const n = Number(value)
  return Number.isFinite(n) ? Math.min(high, Math.max(low, n)) : undefined
}

function parseOverrides(raw: unknown): LoopOverrides | undefined {
  if (!raw || typeof raw !== 'object') return undefined
  const input = raw as Record<string, any>

  const quality: Partial<QualityThresholds> = {}
  if (input.quality && typeof input.quality === 'object') {
    for (const key of Object.keys(OVERRIDE_RANGES) as (keyof QualityThresholds)[]) {
      const value = clamp(input.quality[key], OVERRIDE_RANGES[key])
      if (value !== undefined) quality[key] = value
    }
  }

  const overrides: LoopOverrides = { quality }
  const maxSharedFraction = clamp(input.maxSharedFraction, [0, 1])
  if (maxSharedFraction !== undefined) overrides.maxSharedFraction = maxSharedFraction
  const joinTurnThresholdDegrees = clamp(input.joinTurnThresholdDegrees, [0, 180])
  if (joinTurnThresholdDegrees !== undefined) overrides.joinTurnThresholdDegrees = joinTurnThresholdDegrees
  const waypointPullbackScale = clamp(input.waypointPullbackScale, [0.1, 1])
  if (waypointPullbackScale !== undefined) overrides.waypointPullbackScale = waypointPullbackScale
  const rawCandidateCount = clamp(input.candidateCount, [2, 96])
  if (rawCandidateCount !== undefined) overrides.candidateCount = Math.round(rawCandidateCount / 2) * 2

  return overrides
}
