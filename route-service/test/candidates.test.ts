import { describe, expect, it } from 'vitest'
import { BEARING_JITTER_DEGREES, DEFAULT_ATTEMPT_COUNT, generateLoopAttempts, spreadAcrossCompass } from '../src/loops/candidates.js'
import { hashString, mulberry32, seedFor } from '../src/loops/random.js'

const START: [number, number] = [-4.4816, 54.1506]
const TARGET = 5000

describe('seeded randomness', () => {
  it('gives the same stream for the same seed', () => {
    const a = mulberry32(42)
    const b = mulberry32(42)
    expect([a(), a(), a()]).toEqual([b(), b(), b()])
  })
  it('gives a different stream for a different seed', () => {
    expect(mulberry32(1)()).not.toBe(mulberry32(2)())
  })
  it('stays inside the unit interval', () => {
    const random = mulberry32(hashString('looper'))
    for (let i = 0; i < 500; i++) {
      const value = random()
      expect(value).toBeGreaterThanOrEqual(0)
      expect(value).toBeLessThan(1)
    }
  })
  it('ignores GPS drift of a few metres in the start point', () => {
    expect(seedFor([-4.48161, 54.15062], 5000, 0)).toBe(seedFor([-4.48163, 54.15061], 5000, 0))
  })
  it('moves when the walker asks for a different set', () => {
    expect(seedFor(START, 5000, 1)).not.toBe(seedFor(START, 5000, 0))
  })
  it('moves when the distance changes', () => {
    expect(seedFor(START, 6000, 0)).not.toBe(seedFor(START, 5000, 0))
  })
})

describe('loop attempts', () => {
  const seed = seedFor(START, TARGET, 0)
  const attempts = generateLoopAttempts(seed)

  it('makes sixteen of them by default', () => {
    expect(DEFAULT_ATTEMPT_COUNT).toBe(16)
    expect(attempts).toHaveLength(16)
  })
  it('is deterministic for the same seed', () => {
    expect(generateLoopAttempts(seed)).toEqual(attempts)
  })
  it('produces a different set for a different variation', () => {
    const other = generateLoopAttempts(seedFor(START, TARGET, 1))
    expect(other[0].initialBearing).not.toBe(attempts[0].initialBearing)
  })
  it('pairs every clockwise attempt with its counter-clockwise mirror at the same bearing', () => {
    for (let i = 0; i < attempts.length; i += 2) {
      expect(attempts[i].direction).toBe('clockwise')
      expect(attempts[i + 1].direction).toBe('counter-clockwise')
      expect(attempts[i + 1].initialBearing).toBe(attempts[i].initialBearing)
    }
  })
  it('spreads the attempts around the compass', () => {
    const octants = new Set(attempts.map(attempt => Math.round(attempt.initialBearing / 45) % 8))
    // One octant per mirrored pair — every pair shares a bearing.
    expect(octants.size).toBe(attempts.length / 2)
  })
  it('nudges each slot by no more than the stated jitter', () => {
    expect(BEARING_JITTER_DEGREES).toBe(12)
    const pairs = attempts.length / 2
    for (let pair = 0; pair < pairs; pair++) {
      const slot = (pair * 360) / pairs
      const attempt = attempts[pair * 2]
      const drift = Math.abs(((attempt.initialBearing - slot + 540) % 360) - 180)
      expect(drift).toBeLessThanOrEqual(BEARING_JITTER_DEGREES + 1e-9)
    }
  })
  it('refuses an odd attempt count, which would leave a bearing without a mirror', () => {
    expect(() => generateLoopAttempts(seed, 7)).toThrow()
  })
})

/**
 * The order attempts are dispatched in only matters because the generator can
 * stop partway. Once it can, "the first six of twenty-four" has to mean a
 * sample of the compass rather than a quarter of it.
 */
describe('spreading attempts round the compass', () => {
  const attempts = generateLoopAttempts(seedFor(START, TARGET, 0), 24)

  it('is the same attempts in a different order, and nothing else', () => {
    const spread = spreadAcrossCompass(attempts)
    expect(spread).toHaveLength(attempts.length)
    expect([...spread].map(a => a.id).sort()).toEqual([...attempts].map(a => a.id).sort())
  })

  it('renumbers so the first attempt dispatched is attempt zero', () => {
    const spread = spreadAcrossCompass(attempts)
    expect(spread.map(a => a.index)).toEqual(spread.map((_, index) => index))
  })

  it('keeps each bearing next to its mirror, because that is one question asked twice', () => {
    const spread = spreadAcrossCompass(attempts)
    for (let index = 0; index < spread.length; index += 2) {
      expect(spread[index].initialBearing).toBe(spread[index + 1].initialBearing)
      expect(spread[index].direction).not.toBe(spread[index + 1].direction)
    }
  })

  it('covers the compass in the first few attempts, which is the whole point', () => {
    const spread = spreadAcrossCompass(attempts)
    const octantsIn = (count: number) => new Set(spread.slice(0, count).map(a => Math.round(a.initialBearing / 45) % 8)).size
    // In dispatch order, six attempts is three bearings; unspread, all three
    // are neighbours and land in one or two octants.
    expect(octantsIn(6)).toBeGreaterThanOrEqual(3)
    expect(new Set(attempts.slice(0, 6).map(a => Math.round(a.initialBearing / 45) % 8)).size).toBeLessThanOrEqual(2)
    expect(octantsIn(12)).toBeGreaterThanOrEqual(5)
  })

  it('is deterministic', () => {
    expect(spreadAcrossCompass(attempts)).toEqual(spreadAcrossCompass(generateLoopAttempts(seedFor(START, TARGET, 0), 24)))
  })

  it('leaves a single mirrored pair alone', () => {
    const pair = generateLoopAttempts(seedFor(START, TARGET, 0), 2)
    expect(spreadAcrossCompass(pair)).toEqual(pair)
  })

  it('handles a count that is not a power of two', () => {
    for (const count of [6, 10, 14, 18, 22]) {
      const set = generateLoopAttempts(seedFor(START, TARGET, 0), count)
      const spread = spreadAcrossCompass(set)
      expect(spread).toHaveLength(count)
      expect(new Set(spread.map(a => a.id)).size).toBe(count)
    }
  })
})
