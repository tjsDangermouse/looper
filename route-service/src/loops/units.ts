/** Unit conversion and the time-to-distance estimate. */

/** Kilometres in a statute mile, exactly. */
export const KM_PER_MILE = 1.609344
export const kmToMiles = (km: number) => km / KM_PER_MILE
export const milesToKm = (miles: number) => miles * KM_PER_MILE
export const kmToMetres = (km: number) => km * 1000

/**
 * A first guess only. Real walking speed depends on hills, surface and the
 * walker; the duration GraphHopper returns for the finished route is what the
 * app shows and what the time-mode tolerance is judged against.
 */
export const ESTIMATED_WALKING_SPEED_KMH = 5
export const DEFAULT_WALKING_PACE_MINUTES_PER_KM = 12

export const minutesToMetres = (minutes: number, speedKmh = ESTIMATED_WALKING_SPEED_KMH) =>
  (minutes / 60) * speedKmh * 1000

export const metresForPace = (minutes: number, paceMinutesPerKm = DEFAULT_WALKING_PACE_MINUTES_PER_KM) =>
  (minutes / paceMinutesPerKm) * 1000

export type LoopMode = 'distance' | 'time'

/** The distance the candidate rings are sized for. */
export function targetMetresFor(input: { mode: LoopMode; distanceKm?: number; durationMinutes?: number; walkingPaceMinutesPerKm?: number }): number {
  if (input.mode === 'time') return metresForPace(input.durationMinutes ?? 0, input.walkingPaceMinutesPerKm)
  return kmToMetres(input.distanceKm ?? 0)
}

/** Seconds the walker asked for, or undefined in distance mode. */
export const targetSecondsFor = (input: { mode: LoopMode; durationMinutes?: number }) =>
  input.mode === 'time' ? (input.durationMinutes ?? 0) * 60 : undefined
