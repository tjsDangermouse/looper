import { describe, expect, it } from 'vitest'
import { ESSENTIAL_REJECTIONS, MAX_BOUNDING_BOX_RATIO, MAX_START_STUB_METRES, MIN_BACKTRACK_METRES, MIN_COMPACTNESS, spurLimitMetres, startStubMetres, MAX_DISTANCE_ERROR, MAX_U_TURNS, analyseRouteQuality, countUTurns, findRepeatedCorridors, sharedCorridorMetres } from '../src/loops/quality.js'
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
    expect(report.longestReverseRunMetres).toBeGreaterThan(400)
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

describe('how long a backtrack may be', () => {
  it('always holds a short backtrack against a walk', () => {
    // 420 m walked both ways — nearly the length of a real promenade, but
    // not quite: too short to be a destination, too long to be a shrug.
    const report = judge(repeatedBridge)
    expect(report.pass).toBe(false)
    expect(report.rejections).toContain('out-and-back-spur')
  })
  it('never holds a long one against a walk on length alone', () => {
    // Walking to the end of a promenade and back is the walk, not a defect.
    expect(judge(longOutAndBack).rejections).not.toContain('out-and-back-spur')
    expect(MIN_BACKTRACK_METRES).toBe(500)
  })
  it('offers a promenade walked out and back outright, not only as a last resort', () => {
    const report = judge(longOutAndBack)
    expect(report.pass).toBe(true)
  })
  it('still offers a loop with one long, legitimate crossing off to the side', () => {
    // Two lobes joined by a 700 m bridge with no second crossing.
    const bigBridge = polyline([
      [0, 0], [0, 700], [400, 700], [400, 1100], [0, 1100], [0, 700], [0, 0],
    ])
    const report = judge(bigBridge)
    expect(report.longestReverseRunMetres).toBeGreaterThan(MIN_BACKTRACK_METRES)
    expect(report.pass).toBe(true)
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
    expect(judge(narrowElongated, { targetSeconds: 600 }).durationOnly).toBe(false)
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
  it('never holds leg balance against a two-leg shape, which can never satisfy it', () => {
    // Out one way and home a different way, no third corner: two shares
    // summing to the whole walk always put one of them past 45% — that is
    // what a two-leg shape is, not lopsided.
    const total = pathLength(cleanLoop)
    const report = judge(cleanLoop, { legDistances: [total * .55, total * .45] })
    expect(report.rejections).not.toContain('leg-too-long')
  })
  it('refuses a route with a token leg round the outer ring', () => {
    const total = pathLength(cleanLoop)
    const report = judge(cleanLoop, { legDistances: [total * .4, total * .03, total * .37, total * .2] })
    expect(report.rejections).toContain('leg-too-short')
  })
  it('allows a short spoke out to the ring, which is where the door happens to be', () => {
    // The first waypoint snapped to a street just round the corner. That is not
    // a fault in the walk, and rejecting it threw out good loops.
    const total = pathLength(cleanLoop)
    const report = judge(cleanLoop, { legDistances: [total * .03, total * .4, total * .37, total * .2] })
    expect(report.rejections).not.toContain('leg-too-short')
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

describe('what can be set aside when nothing clean exists', () => {
  it('treats the wrong length, the wrong time and an open end as never negotiable', () => {
    expect([...ESSENTIAL_REJECTIONS]).toEqual(['distance', 'duration', 'open-ended'])
  })
  it('would offer a route with a too-short backtrack as a last resort', () => {
    const report = judge(repeatedBridge)
    expect(report.pass).toBe(false)
    expect(report.passesEssentials).toBe(true)
  })
  it('would offer a long thin valley walk', () => {
    expect(judge(narrowElongated).passesEssentials).toBe(true)
  })
  it('would never offer one of the wrong length, however clean its shape', () => {
    expect(judge(cleanLoop, { targetMetres: pathLength(cleanLoop) / 1.4 }).passesEssentials).toBe(false)
  })
  it('would never offer one that fails to come back', () => {
    expect(judge(polyline([[0, 0], [900, 0], [900, 900]])).passesEssentials).toBe(false)
  })
  it('would never offer one that takes the wrong amount of time', () => {
    expect(judge(cleanLoop, { targetSeconds: 600 }).passesEssentials).toBe(false)
  })
})

describe('the stub at the door', () => {
  it('finds none on a loop that starts on the circuit', () => {
    expect(startStubMetres(cleanLoop)).toBeLessThan(20)
  })
  it('measures the shared lane a loop is reached down', () => {
    // 60 m out to the circle and 60 m back at the end.
    expect(startStubMetres(sharedStartLoop)).toBeGreaterThan(40)
    expect(startStubMetres(sharedStartLoop)).toBeLessThan(80)
  })
  it('judges the doorstep stub in proportion, like any other spur, below the backtrack minimum', () => {
    // Below about 12.5 km the flat 150 m floor is the more generous of the
    // two and governs; past it, 4% of a long day out is bigger than 150 m and
    // takes over — but only up to the 500 m point where a stub this long is
    // its own destination rather than a lane to the loop.
    expect(spurLimitMetres(2000, MAX_START_STUB_METRES)).toBe(150)
    expect(spurLimitMetres(20000, MAX_START_STUB_METRES)).toBeGreaterThan(150)
  })
  it('forgives a doorstep but not a middling stub', () => {
    expect(judge(sharedStartLoop).rejections).not.toContain('start-spur')
    // 300 m: long enough to be "a there-and-back with a loop stuck on the
    // end," not long enough to be a promenade in its own right.
    const spike = polyline([
      [0, 0], [0, 300],
      ...[[0, 300], [500, 300], [500, 800], [0, 800], [0, 300]] as [number, number][],
      [0, 0],
    ])
    expect(startStubMetres(spike)).toBeGreaterThan(MAX_START_STUB_METRES)
    expect(startStubMetres(spike)).toBeLessThan(MIN_BACKTRACK_METRES)
    expect(judge(spike).rejections).toContain('start-spur')
  })
  it('forgives a doorstep stub long enough to be a destination in its own right', () => {
    // 700 m out to a promenade the walk happens to start on, and back.
    const spike = polyline([
      [0, 0], [0, 700],
      ...[[0, 700], [500, 700], [500, 1200], [0, 1200], [0, 700]] as [number, number][],
      [0, 0],
    ])
    expect(startStubMetres(spike)).toBeGreaterThan(MIN_BACKTRACK_METRES)
    expect(judge(spike).rejections).not.toContain('start-spur')
  })
  it('lets a walk that doubles back at the door be offered only as a last resort', () => {
    const spike = polyline([[0, 0], [0, 300], [500, 300], [500, 800], [0, 800], [0, 300], [0, 0]])
    expect(judge(spike).passesEssentials).toBe(true)
  })
})

describe('walks that enclose nothing', () => {
  it('sets the bar below what the generator’s own ring can reach', () => {
    expect(MIN_COMPACTNESS).toBeLessThan(0.37)
    expect(MIN_COMPACTNESS).toBeGreaterThan(0.15)
  })
  it('offers a proper circuit', () => {
    expect(judge(cleanLoop).rejections).not.toContain('shapeless')
  })
  it('refuses a figure of eight, which encloses nothing on balance', () => {
    expect(judge(simpleCrossing).rejections).toContain('shapeless')
  })
  it('refuses a walk threaded back through the same blocks', () => {
    // Out along one street and back along the next one over: never repeats a
    // step, never turns round, and is not a loop.
    const zigzag = polyline([
      [0, 0], [1200, 0], [1200, 60], [40, 60], [40, 120], [1200, 120], [1200, 180], [0, 180], [0, 0],
    ])
    const report = judge(zigzag)
    expect(report.quality.repeatedPercent).toBeLessThan(12)
    expect(report.rejections).toContain('shapeless')
  })
  it('still lets it through as a last resort', () => {
    expect(judge(simpleCrossing).passesEssentials).toBe(true)
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
