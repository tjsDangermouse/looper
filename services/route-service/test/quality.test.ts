import { describe, expect, it } from 'vitest'
import { MAX_BOUNDING_BOX_RATIO, MAX_DISTANCE_ERROR, MAX_OUT_AND_BACK_SPUR_METRES, MAX_REPEATED_FRACTION, MAX_U_TURNS, analyseRouteQuality, countUTurns, findRepeatedCorridors, sharedCorridorMetres } from '../src/loops/quality.js'
import { pathLength, type LngLat } from '../src/loops/geo.js'
import { FIXTURE_ORIGIN, cleanLoop, longOutAndBack, narrowElongated, polyline, repeatedBridge, sharedStartLoop, simpleCrossing, twinA, twinB } from './fixtures/routes.js'

const START: LngLat = FIXTURE_ORIGIN

/** A candidate whose legs are even quarters, judged against its own length. */
const judge = (coordinates: LngLat[], overrides: Partial<Parameters<typeof analyseRouteQuality>[0]> = {}) => {
  const distanceMeters = pathLength(coordinates)
  return analyseRouteQuality({
    coordinates,
    start: START,
    distanceMeters,
    durationSeconds: distanceMeters / (5000 / 3600),
    targetMetres: distanceMeters,
    legDistances: [distanceMeters / 4, distanceMeters / 4, distanceMeters / 4, distanceMeters / 4],
    ...overrides,
  })
}

describe('repeated corridor detection', () => {
  it('finds nothing repeated on a clean circular loop', () => {
    expect(findRepeatedCorridors(cleanLoop).repeatedMeters).toBe(0)
  })
  it('ignores a short shared section at the start and finish', () => {
    // Down a 60 m lane and back up it at the end: every loop has a doorstep.
    expect(findRepeatedCorridors(sharedStartLoop).repeatedMeters).toBe(0)
  })
  it('counts a there-and-back as repeating most of itself', () => {
    const report = findRepeatedCorridors(longOutAndBack)
    expect(report.repeatedPercent).toBeGreaterThan(40)
  })
  it('finds a path section walked in both directions', () => {
    const report = findRepeatedCorridors(repeatedBridge)
    expect(report.repeatedMeters).toBeGreaterThan(200)
    expect(report.longestReverseRunMetres).toBeGreaterThan(MAX_OUT_AND_BACK_SPUR_METRES)
  })
  it('does not call a crossroads an overlap', () => {
    // The figure of eight touches itself once, at right angles. Walkers cross
    // their own path all the time and think nothing of it.
    expect(findRepeatedCorridors(simpleCrossing).repeatedMeters).toBe(0)
  })
  it('holds reverse-direction overlap against a route more heavily', () => {
    const report = findRepeatedCorridors(repeatedBridge)
    expect(report.weightedRepeatedMeters).toBeGreaterThan(report.repeatedMeters)
  })
  it('needs a shared stretch to continue before it counts', () => {
    // A 20 m brush past an earlier corridor: below the continuous-length floor.
    const brush = polyline([[0, 0], [600, 0], [600, 600], [-20, 600], [-20, 20], [0, 20], [0, 0]])
    const report = findRepeatedCorridors(brush)
    expect(report.repeatedMeters).toBe(0)
  })
})

describe('U-turns', () => {
  it('sees none on a circle', () => expect(countUTurns(cleanLoop)).toBe(0))
  it('sees the turn-around at the end of a there-and-back', () =>
    expect(countUTurns(longOutAndBack)).toBeGreaterThanOrEqual(1))
  it('trusts geometry even when the instructions never mention one', () => {
    expect(countUTurns(longOutAndBack, [0, 0, 4])).toBeGreaterThanOrEqual(1)
  })
  it('takes the engine’s own U-turn signs as a supporting signal', () => {
    expect(countUTurns(cleanLoop, [0, -8, 2, 8, 4])).toBe(2)
  })
  it('is not fooled by an ordinary sharp corner', () => {
    expect(countUTurns(polyline([[0, 0], [400, 0], [400, 400], [0, 400], [0, 0]]))).toBe(0)
  })
})

describe('hard rejections', () => {
  it('offers a clean loop', () => {
    const report = judge(cleanLoop)
    expect(report.rejections).toEqual([])
    expect(report.pass).toBe(true)
  })
  it('offers a loop with an honest shared doorstep', () => {
    expect(judge(sharedStartLoop).pass).toBe(true)
  })
  it('refuses a long out-and-back', () => {
    const report = judge(longOutAndBack)
    expect(report.pass).toBe(false)
    expect(report.rejections).toContain('out-and-back-spur')
  })
  it('refuses a route that repeats too much of itself', () => {
    const report = judge(repeatedBridge)
    expect(report.pass).toBe(false)
    expect(report.quality.repeatedPercent).toBeGreaterThan(MAX_REPEATED_FRACTION * 100)
    expect(report.rejections).toContain('repeated-corridor')
  })
  it('refuses a route that is far from the distance asked for', () => {
    const long = judge(cleanLoop, { targetMetres: pathLength(cleanLoop) / 1.3 })
    expect(long.rejections).toContain('distance')
    const near = judge(cleanLoop, { targetMetres: pathLength(cleanLoop) / 1.05 })
    expect(near.rejections).not.toContain('distance')
    expect(MAX_DISTANCE_ERROR).toBe(.12)
  })
  it('refuses a time-mode route that takes far longer than asked', () => {
    const report = judge(cleanLoop, { targetSeconds: 600 })
    expect(report.rejections).toContain('duration')
    expect(report.durationOnly).toBe(true)
  })
  it('says when the time is the only thing wrong, so one retry can fix it', () => {
    expect(judge(cleanLoop, { targetSeconds: 600 }).durationOnly).toBe(true)
    expect(judge(longOutAndBack, { targetSeconds: 600 }).durationOnly).toBe(false)
  })
  it('refuses more than one genuine U-turn', () => {
    const report = judge(cleanLoop, { maneuverSigns: [-8, 8, -98] })
    expect(report.rejections).toContain('u-turns')
    expect(MAX_U_TURNS).toBe(1)
  })
  it('refuses a route where one leg is most of the walk', () => {
    const total = pathLength(cleanLoop)
    const report = judge(cleanLoop, { legDistances: [total * .6, total * .2, total * .1, total * .1] })
    expect(report.rejections).toContain('leg-too-long')
  })
  it('refuses a route with a token leg', () => {
    const total = pathLength(cleanLoop)
    const report = judge(cleanLoop, { legDistances: [total * .4, total * .37, total * .2, total * .03] })
    expect(report.rejections).toContain('leg-too-short')
  })
  it('refuses a long thin route', () => {
    const report = judge(narrowElongated)
    expect(report.rejections).toContain('elongated')
    expect(report.boundingBoxRatio).toBeGreaterThan(MAX_BOUNDING_BOX_RATIO)
  })
  it('refuses a route that never comes back', () => {
    const open = polyline([[0, 0], [900, 0], [900, 900]])
    expect(judge(open).rejections).toContain('open-ended')
  })
})

describe('scoring', () => {
  it('scores a clean loop above one that repeats itself', () => {
    expect(judge(cleanLoop).quality.score).toBeGreaterThan(judge(repeatedBridge).quality.score)
  })
  it('scores a loop above a there-and-back', () => {
    expect(judge(repeatedBridge).quality.score).toBeGreaterThan(judge(longOutAndBack).quality.score)
  })
  it('marks a route down for missing the requested distance', () => {
    const exact = judge(cleanLoop).quality.score
    const off = judge(cleanLoop, { targetMetres: pathLength(cleanLoop) / 1.08 }).quality.score
    expect(off).toBeLessThan(exact)
  })
  it('marks a route down for lopsided legs', () => {
    const total = pathLength(cleanLoop)
    const even = judge(cleanLoop).quality.score
    const lopsided = judge(cleanLoop, { legDistances: [total * .44, total * .3, total * .17, total * .09] }).quality.score
    expect(lopsided).toBeLessThan(even)
  })
  it('reports the numbers behind the score', () => {
    const { quality } = judge(repeatedBridge)
    expect(quality.repeatedMeters).toBeGreaterThan(0)
    expect(quality.repeatedPercent).toBeGreaterThan(0)
    expect(quality.compactness).toBeGreaterThan(0)
    expect(quality.score).toBeGreaterThanOrEqual(0)
    expect(quality.score).toBeLessThanOrEqual(100)
  })
})

describe('shared ground between two routes', () => {
  it('finds two near-identical loops nearly identical', () => {
    expect(sharedCorridorMetres(twinA, twinB).fraction).toBeGreaterThan(.9)
  })
  it('finds nothing shared between loops that go opposite ways', () => {
    const away = polyline([[3000, 3000], [3600, 3000], [3600, 3600], [3000, 3600], [3000, 3000]])
    expect(sharedCorridorMetres(cleanLoop, away).fraction).toBe(0)
  })
  it('ignores the shared doorstep at either end', () => {
    expect(sharedCorridorMetres(sharedStartLoop, polyline([[0, -560], [0, -500]])).fraction).toBe(0)
  })
})
