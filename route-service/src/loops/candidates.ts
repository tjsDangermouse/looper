import { normaliseBearing } from './geo.js'
import { mulberry32 } from './random.js'

/**
 * Loop attempts.
 *
 * What used to be decided here — a whole triangle of waypoints, guessed blind
 * before any street was consulted — is now decided live, one leg at a time, by
 * the incremental builder in routing.ts. All that's fixed up front is where an
 * attempt sets off from and which way it turns: enough to keep repeated
 * requests deterministic and to spread attempts round the compass, nothing
 * about the street network the ring will actually run on.
 */
export type LoopDirection = 'clockwise' | 'counter-clockwise'

export type LoopAttempt = {
  id: string
  /** Position within the deterministic set, 0-based. */
  index: number
  direction: LoopDirection
  /** Bearing the walk sets off on, degrees clockwise from north. */
  initialBearing: number
}

/** Spread of the first waypoint around its slot, in degrees. */
export const BEARING_JITTER_DEGREES = 12
/**
 * Each attempt now self-corrects as it builds rather than being thrown away
 * whole on a bad guess, so far fewer attempts are needed to find three clean
 * loops than the old blind-and-filter approach required.
 */
export const DEFAULT_ATTEMPT_COUNT = 16

/**
 * Deterministic for a given seed. Attempts come in mirrored pairs that share a
 * starting bearing and run opposite ways round: the same three streets can
 * make a good loop one way and an awkward one the other, and which is which
 * depends on one-way paths, stairs and crossings we cannot see from here.
 */
export function generateLoopAttempts(seed: number, count: number = DEFAULT_ATTEMPT_COUNT): LoopAttempt[] {
  if (count < 2 || count % 2 !== 0) throw new Error('Attempt count must be a positive even number so every bearing has a mirror.')
  const random = mulberry32(seed)
  const pairs = count / 2
  const attempts: LoopAttempt[] = []

  for (let pair = 0; pair < pairs; pair++) {
    // Slots evenly around the compass, nudged so two runs never look stencilled.
    const jitter = (random() - 0.5) * 2 * BEARING_JITTER_DEGREES
    const initialBearing = normaliseBearing((pair * 360) / pairs + jitter)
    for (const direction of ['clockwise', 'counter-clockwise'] as const) {
      attempts.push({ id: `${pair}-${direction === 'clockwise' ? 'cw' : 'ccw'}`, index: attempts.length, direction, initialBearing })
    }
  }
  return attempts
}
