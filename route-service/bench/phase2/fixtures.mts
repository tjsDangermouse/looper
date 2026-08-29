/**
 * The Phase 2 fixture set and the service environment every Phase 2 benchmark
 * starts a route service with.
 *
 * Deliberately the same six production probes Phase 1 used, so the two phases'
 * tables are about the same work. Shared rather than copied because a
 * benchmark suite whose fixtures drift between scripts measures the drift.
 */
import { createHash } from 'node:crypto'

const DOUGLAS = { lng: -4.4816, lat: 54.1506 }

export const FIXTURES: Array<{ name: string; body: any }> = [
  { name: 'douglas-5km', body: { start: DOUGLAS, mode: 'distance', distanceKm: 5, units: 'km', variation: 0 } },
  { name: 'douglas-3km', body: { start: DOUGLAS, mode: 'distance', distanceKm: 3, units: 'km', variation: 0 } },
  { name: 'peel-5km', body: { start: { lng: -4.6947, lat: 54.2247 }, mode: 'distance', distanceKm: 5, units: 'km', variation: 0 } },
  { name: 'onchan-5km', body: { start: { lng: -4.4530, lat: 54.1745 }, mode: 'distance', distanceKm: 5, units: 'km', variation: 0 } },
  { name: 'wp-one', body: { start: DOUGLAS, mode: 'distance', distanceKm: 6, units: 'km', variation: 0, waypoints: [{ lng: -4.4746, lat: 54.1566 }] } },
  { name: 'wp-two', body: { start: DOUGLAS, mode: 'distance', distanceKm: 8, units: 'km', variation: 0, waypoints: [{ lng: -4.4700, lat: 54.1560 }, { lng: -4.4900, lat: 54.1600 }] } },
]

/** Nothing throttled, nothing cached, nothing logged that is not an error. */
export const START_SERVICE_ENV = {
  RATE_LIMIT_PER_MINUTE: '100000',
  LOOPER_REQUEST_CACHE: 'false',
  LOG_LEVEL: 'error',
}

/** Six decimals, matching Phase 1, so the two phases' hashes are comparable. */
export const hashRoute = (coords: number[][]) =>
  createHash('sha256').update(coords.map(([a, b]) => `${Math.round(a * 1e6) / 1e6},${Math.round(b * 1e6) / 1e6}`).join(';')).digest('hex').slice(0, 16)
