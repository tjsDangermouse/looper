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

/**
 * Reorder attempts so that any prefix of them already covers the compass.
 *
 * `generateLoopAttempts` emits bearings in order round the dial, which is the
 * right thing when every attempt is going to run. It is the wrong thing the
 * moment the generator can stop partway: the first six attempts of twenty-four
 * are then the first quarter of the compass and nothing else, so the pool a
 * stopping rule looks at is not a sample of the ground, it is a sample of one
 * side of it — and a rule asking "do we have three walks setting off in
 * different directions" can never answer yes.
 *
 * Bit-reversal gives the property wanted: take the pairs in the order their
 * indices read backwards in binary, and every prefix is spread as evenly round
 * the dial as a prefix of that length can be. Mirrored pairs stay adjacent —
 * the same bearing clockwise and anticlockwise is one question asked twice,
 * and separating them buys nothing.
 *
 * Deterministic, and a permutation: the same attempts, in a different order.
 */
export function spreadAcrossCompass(attempts: LoopAttempt[]): LoopAttempt[] {
  const pairs = attempts.length / 2
  if (pairs < 2) return attempts
  const bits = Math.ceil(Math.log2(pairs))
  const order: number[] = []
  for (let reversed = 0; reversed < 1 << bits; reversed++) {
    const pair = reverseBits(reversed, bits)
    if (pair < pairs) order.push(pair)
  }
  return order
    .flatMap(pair => [attempts[pair * 2], attempts[pair * 2 + 1]])
    .map((attempt, index) => ({ ...attempt, index }))
}

function reverseBits(value: number, bits: number): number {
  let out = 0
  for (let bit = 0; bit < bits; bit++) out |= ((value >> bit) & 1) << (bits - 1 - bit)
  return out
}
