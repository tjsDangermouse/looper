import { describe, expect, it } from 'vitest'
import {
  EDGE_START_IGNORE_METRES,
  REVERSE_REPEAT_WEIGHT,
  edgeRepeatReport,
  longestRepeatedSection,
  measureTraversals,
  sharedEdgeMetres,
  type EdgeSpan,
} from '../src/loops/edges.js'
import { parseLeg } from '../src/graphhopper.js'
import { analyseRouteQuality } from '../src/loops/quality.js'
import { sharedFraction, mutualSharedFraction } from '../src/loops/diversity.js'
import { at, cleanLoop, longOutAndBack, twinA, twinB } from './fixtures/routes.js'
import type { LngLat } from '../src/loops/geo.js'

/**
 * A straight line east, one vertex every 100 m, so a span from index i to
 * index j is exactly `(j - i) * 100` metres and every answer below can be
 * checked by hand rather than by running the code.
 */
const straightEast = (points: number): LngLat[] => Array.from({ length: points }, (_, index) => at(index * 100, 0))

describe('measuring which edges a walk used', () => {
  it('measures a span from the walk it actually covers', () => {
    const traversals = measureTraversals(straightEast(5), [
      { id: 10, startIndex: 0, endIndex: 2 },
      { id: 11, startIndex: 2, endIndex: 4 },
    ])!
    expect(traversals).toHaveLength(2)
    expect(traversals[0].metres).toBeCloseTo(200, 0)
    expect(traversals[1].metres).toBeCloseTo(200, 0)
    expect(traversals[0].along).toBeCloseTo(100, 0)
    expect(traversals[1].along).toBeCloseTo(300, 0)
  })

  it('counts only the part of an edge that was walked', () => {
    // The walk joined this edge halfway along, so half of it is what it cost.
    const traversals = measureTraversals(straightEast(3), [{ id: 7, startIndex: 1, endIndex: 2 }])!
    expect(traversals[0].metres).toBeCloseTo(100, 0)
  })

  it('drops a span that does not describe a real stretch of the line', () => {
    const line = straightEast(4)
    const nonsense: EdgeSpan[] = [
      { id: 1, startIndex: 2, endIndex: 1 },   // backwards
      { id: 2, startIndex: 1, endIndex: 1 },   // a point
      { id: 3, startIndex: 0, endIndex: 99 },  // past the end
      { id: 4, startIndex: -1, endIndex: 2 },  // before the start
    ]
    expect(measureTraversals(line, nonsense)).toBeUndefined()
  })

  it('says nothing rather than something wrong when there are no spans', () => {
    expect(measureTraversals(straightEast(4), undefined)).toBeUndefined()
    expect(measureTraversals(straightEast(4), [])).toBeUndefined()
    expect(measureTraversals([at(0, 0)], [{ id: 1, startIndex: 0, endIndex: 1 }])).toBeUndefined()
  })
})

describe('retracing, measured on the network', () => {
  /** Far enough along that the doorstep allowance never reaches it. */
  const away = EDGE_START_IGNORE_METRES + 50

  it('charges the second walk down a street, not the first', () => {
    const traversals = [
      { id: 1, metres: 300, along: away, direction: [1, 0] as [number, number] },
      { id: 1, metres: 300, along: away + 400, direction: [-1, 0] as [number, number] },
    ]
    const report = edgeRepeatReport(traversals, 2000)
    expect(report.repeatedMeters).toBe(300)
    expect(report.repeatedPercent).toBeCloseTo(15, 5)
  })

  it('charges a third walk down it as well', () => {
    const pass = (along: number, direction: [number, number]) => ({ id: 1, metres: 300, along, direction })
    const report = edgeRepeatReport([
      pass(away, [1, 0]),
      pass(away + 400, [-1, 0]),
      pass(away + 800, [1, 0]),
    ], 3000)
    expect(report.repeatedMeters).toBe(600)
  })

  it('weights walking a street back the other way above walking it again the same way', () => {
    const forward = edgeRepeatReport([
      { id: 1, metres: 200, along: away, direction: [1, 0] },
      { id: 1, metres: 200, along: away + 500, direction: [1, 0] },
    ], 2000)
    const backward = edgeRepeatReport([
      { id: 1, metres: 200, along: away, direction: [1, 0] },
      { id: 1, metres: 200, along: away + 500, direction: [-1, 0] },
    ], 2000)
    expect(forward.weightedRepeatedMeters).toBe(200)
    expect(backward.weightedRepeatedMeters).toBe(200 * REVERSE_REPEAT_WEIGHT)
    expect(backward.longestReverseRunMetres).toBe(200)
    expect(forward.longestReverseRunMetres).toBe(0)
  })

  it('does not call the shared doorstep at either end retracing', () => {
    const report = edgeRepeatReport([
      { id: 1, metres: 40, along: 20, direction: [1, 0] },
      { id: 1, metres: 40, along: 1980, direction: [-1, 0] },
    ], 2000)
    expect(report.repeatedMeters).toBe(0)
  })

  it('adds up an unbroken repeated stretch and reports its length', () => {
    const out = [200, 600, 1000].map((along, index) => ({ id: index, metres: 200, along, direction: [1, 0] as [number, number] }))
    const back = [1400, 1800, 2200].map((along, index) => ({ id: 2 - index, metres: 200, along, direction: [-1, 0] as [number, number] }))
    const report = edgeRepeatReport([...out, ...back], 3000)
    expect(report.repeatedMeters).toBe(600)
    expect(report.longestRepeatedRunMetres).toBe(600)
    expect(report.longestReverseRunMetres).toBe(600)
  })

  it('answers nothing for a walk with nothing in it', () => {
    expect(edgeRepeatReport([], 1000).repeatedMeters).toBe(0)
    expect(edgeRepeatReport([{ id: 1, metres: 100, along: 500, direction: [1, 0] }], 0).repeatedMeters).toBe(0)
  })
})

describe('two walks compared on the network', () => {
  const walk = (ids: number[], from = 200) => ids.map((id, index) => ({
    id,
    metres: 200,
    along: from + index * 200,
    direction: [1, 0] as [number, number],
  }))

  it('counts the ground two walks genuinely share', () => {
    const shared = sharedEdgeMetres(walk([1, 2, 3, 4]), walk([3, 4, 5, 6]), 1600)
    expect(shared.metres).toBe(400)
    expect(shared.fraction).toBeCloseTo(0.25, 5)
  })

  it('finds nothing shared between two walks with no street in common', () => {
    expect(sharedEdgeMetres(walk([1, 2, 3]), walk([7, 8, 9]), 1200).metres).toBe(0)
  })

  it('is deliberately asymmetric, because containment is', () => {
    const short = walk([1, 2, 3, 4])
    const long = walk([1, 2, 3, 4, 5, 6, 7, 8])
    // Every street of the short walk is in the long one; only some of the
    // long walk's streets are in the short one.
    expect(sharedEdgeMetres(short, long, 1000).fraction).toBeGreaterThan(0.75)
    expect(sharedEdgeMetres(long, short, 1800).fraction).toBeLessThan(0.5)
  })
})

/**
 * The whole reason this exists. A pavement on the other side of the road, a
 * back lane, a towpath under a bridge: all within a street's width of the
 * route, all running parallel to it, and none of them the same walk.
 */
describe('parallel but distinct ground', () => {
  const northSide = (points: number): LngLat[] => Array.from({ length: points }, (_, i) => at(i * 100, 6))
  const southSide = (points: number): LngLat[] => Array.from({ length: points }, (_, i) => at(i * 100, -6))
  const spans = (count: number, firstId: number): EdgeSpan[] =>
    Array.from({ length: count }, (_, i) => ({ id: firstId + i, startIndex: i, endIndex: i + 1 }))

  it('geometry calls two pavements twelve metres apart the same ground', () => {
    const north = { coordinates: northSide(12), quality: { score: 1 }, bearing: 90 }
    const south = { coordinates: southSide(12), quality: { score: 1 }, bearing: 90 }
    expect(sharedFraction(north, south)).toBeGreaterThan(0.5)
  })

  it('the network knows they are different streets', () => {
    const north = {
      coordinates: northSide(12),
      quality: { score: 1 },
      bearing: 90,
      traversals: measureTraversals(northSide(12), spans(11, 100)),
      totalMetres: 1100,
    }
    const south = {
      coordinates: southSide(12),
      quality: { score: 1 },
      bearing: 90,
      traversals: measureTraversals(southSide(12), spans(11, 900)),
      totalMetres: 1100,
    }
    expect(mutualSharedFraction(north, south)).toBe(0)
  })

  it('and still knows when they really are the same street', () => {
    const one = {
      coordinates: northSide(12),
      quality: { score: 1 },
      bearing: 90,
      traversals: measureTraversals(northSide(12), spans(11, 100)),
      totalMetres: 1100,
    }
    expect(mutualSharedFraction(one, { ...one })).toBeGreaterThan(0.8)
  })
})

describe('falling back to geometry', () => {
  it('measures retracing geometrically when the engine reported no edges', () => {
    const report = analyseRouteQuality({
      coordinates: longOutAndBack,
      start: longOutAndBack[0],
      distanceMeters: 3000,
      durationSeconds: 2160,
      targetMetres: 3000,
      legDistances: [1500, 1500],
    })
    expect(report.overlapSource).toBe('geometry')
    expect(report.quality.repeatedPercent).toBeGreaterThan(20)
  })

  it('measures on the network when it did', () => {
    const half = Math.floor((cleanLoop.length - 1) / 2)
    const traversals = measureTraversals(cleanLoop, [
      { id: 1, startIndex: 0, endIndex: half },
      { id: 2, startIndex: half, endIndex: cleanLoop.length - 1 },
    ])
    const report = analyseRouteQuality({
      traversals,
      coordinates: cleanLoop,
      start: cleanLoop[0],
      distanceMeters: 3140,
      durationSeconds: 2260,
      targetMetres: 3140,
      legDistances: [3140],
    })
    expect(report.overlapSource).toBe('edges')
  })

  it('compares two routes geometrically when only one of them knows its edges', () => {
    const withEdges = {
      coordinates: twinA,
      quality: { score: 1 },
      bearing: 0,
      traversals: measureTraversals(twinA, [{ id: 1, startIndex: 0, endIndex: twinA.length - 1 }]),
      totalMetres: 3140,
    }
    const without = { coordinates: twinB, quality: { score: 1 }, bearing: 0 }
    expect(sharedFraction(withEdges, without)).toBeGreaterThan(0.5)
  })
})

describe('reading edge ids off a GraphHopper answer', () => {
  const payload = (details: unknown) => ({
    paths: [{
      points: { coordinates: [[0, 54], [0.001, 54], [0.002, 54]] },
      distance: 200,
      time: 144000,
      instructions: [{ text: 'Continue', distance: 200, time: 144000, sign: 0, interval: [0, 2] }],
      details: { edge_id: details },
    }],
  })

  it('reads well-formed intervals', () => {
    const leg = parseLeg(payload([[0, 1, 42], [1, 2, 43]]))
    expect(leg.edges).toEqual([{ id: 42, startIndex: 0, endIndex: 1 }, { id: 43, startIndex: 1, endIndex: 2 }])
  })

  it('reports nothing at all when the engine did not send the detail', () => {
    expect(parseLeg(payload(undefined)).edges).toBeUndefined()
    expect(parseLeg(payload([])).edges).toBeUndefined()
  })

  it('drops an entry it cannot trust rather than half-trusting it', () => {
    const leg = parseLeg(payload([[0, 1, 42], [1, 'x', 43], [5, 9, 44], [1, 2, 1.5]]))
    expect(leg.edges).toEqual([{ id: 42, startIndex: 0, endIndex: 1 }])
  })
})

describe('the longest stretch walked twice', () => {
  it('finds where it is, so a repair can aim at it', () => {
    const traversals = [
      { id: 1, metres: 100, along: 150, direction: [1, 0] as [number, number] },
      { id: 2, metres: 100, along: 250, direction: [1, 0] as [number, number] },
      { id: 2, metres: 100, along: 450, direction: [-1, 0] as [number, number] },
      { id: 1, metres: 100, along: 550, direction: [-1, 0] as [number, number] },
    ]
    const section = longestRepeatedSection(traversals)!
    expect(section.metres).toBe(200)
    expect(section.fromAlong).toBeCloseTo(400, 0)
    expect(section.toAlong).toBeCloseTo(600, 0)
  })

  it('finds nothing in a walk that never repeats', () => {
    expect(longestRepeatedSection([
      { id: 1, metres: 100, along: 150, direction: [1, 0] },
      { id: 2, metres: 100, along: 250, direction: [1, 0] },
    ])).toBeUndefined()
  })
})
