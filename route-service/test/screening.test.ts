import { describe, expect, it } from 'vitest'
import { DEFAULT_SCREEN_THRESHOLDS, pickForRefinement, screenSkeleton, type ScreenVerdict } from '../src/loops/screening.js'
import { cleanLoop, longOutAndBack, narrowElongated, FIXTURE_ORIGIN, polyline } from './fixtures/routes.js'
import type { LngLat } from '../src/loops/geo.js'

const START: LngLat = FIXTURE_ORIGIN
const skeleton = (coordinates: LngLat[], distanceMeters: number, bearing = 0) =>
  ({ attemptId: 'a', bearing, coordinates, distanceMeters })

const TARGET = 3140

describe('screening a bare ring', () => {
  it('keeps a ring of about the right length and shape', () => {
    expect(screenSkeleton(skeleton(cleanLoop, TARGET), START, TARGET).keep).toBe(true)
  })

  it('drops one that came back far too long', () => {
    const verdict = screenSkeleton(skeleton(cleanLoop, TARGET * 3), START, TARGET)
    expect(verdict.keep).toBe(false)
    expect(verdict.reason).toBe('far-too-long')
  })

  it('drops one that barely got going', () => {
    const verdict = screenSkeleton(skeleton(cleanLoop, TARGET * 0.2), START, TARGET)
    expect(verdict.reason).toBe('far-too-short')
  })

  it('drops a ring that never left the door', () => {
    const stub = polyline([[0, 0], [40, 0], [0, 0]])
    expect(screenSkeleton(skeleton(stub, TARGET), START, TARGET).reason).toBe('never-left')
  })

  it('drops a long thin there-and-back', () => {
    expect(screenSkeleton(skeleton(longOutAndBack, 3000), START, 3000).reason).toBe('no-shape')
    expect(screenSkeleton(skeleton(narrowElongated, 4400), START, 4400).reason).toBe('no-shape')
  })

  /**
   * The boundaries matter more than the middle: a screen that is a little too
   * eager throws away walks nobody ever finds out about.
   */
  describe('at the boundaries', () => {
    const { maxLengthRatio, minLengthRatio } = DEFAULT_SCREEN_THRESHOLDS

    it('keeps a ring exactly at the long limit and drops one just past it', () => {
      expect(screenSkeleton(skeleton(cleanLoop, TARGET * maxLengthRatio), START, TARGET).keep).toBe(true)
      expect(screenSkeleton(skeleton(cleanLoop, TARGET * maxLengthRatio * 1.01), START, TARGET).keep).toBe(false)
    })

    it('keeps a ring exactly at the short limit and drops one just under it', () => {
      expect(screenSkeleton(skeleton(cleanLoop, TARGET * minLengthRatio), START, TARGET).keep).toBe(true)
      expect(screenSkeleton(skeleton(cleanLoop, TARGET * minLengthRatio * 0.99), START, TARGET).keep).toBe(false)
    })

    it('is looser than the gate the walk will actually be judged by', () => {
      // Anything the real quality engine would accept must survive screening,
      // or the cheap stage is quietly deciding what the expensive one may see.
      expect(maxLengthRatio).toBeGreaterThan(1.12)
      expect(minLengthRatio).toBeLessThan(0.88)
      expect(DEFAULT_SCREEN_THRESHOLDS.minCompactness).toBeLessThan(0.2)
      expect(DEFAULT_SCREEN_THRESHOLDS.maxBoundingBoxRatio).toBeGreaterThan(4.5)
    })
  })

  it('scores a ring of exactly the right length above one that is nearly right', () => {
    const exact = screenSkeleton(skeleton(cleanLoop, TARGET), START, TARGET)
    const nearly = screenSkeleton(skeleton(cleanLoop, TARGET * 1.3), START, TARGET)
    expect(exact.score).toBeGreaterThan(nearly.score)
  })

  it('answers rather than dividing by a target of nothing', () => {
    expect(screenSkeleton(skeleton(cleanLoop, 1000), START, 0).keep).toBe(false)
  })
})

describe('choosing what to build properly', () => {
  const entry = (name: string, score: number, octant: number, keep = true) =>
    ({ item: name, verdict: { keep, score, octant } as ScreenVerdict })

  it('takes the best first', () => {
    expect(pickForRefinement([entry('a', 0.2, 0), entry('b', 0.9, 1), entry('c', 0.5, 2)], 2))
      .toEqual(['b', 'c'])
  })

  it('never takes everything from one direction while the batch has money left', () => {
    const sameWay = [0.9, 0.8, 0.7, 0.6].map((score, index) => entry(`n${index}`, score, 0))
    const elsewhere = entry('east', 0.1, 2)
    expect(pickForRefinement([...sameWay, elsewhere], 3)).toEqual(['n0', 'n1', 'east'])
  })

  it('goes back for a third from one direction rather than build nothing', () => {
    const sameWay = [0.9, 0.8, 0.7].map((score, index) => entry(`n${index}`, score, 0))
    expect(pickForRefinement(sameWay, 3)).toEqual(['n0', 'n1', 'n2'])
  })

  it('never picks something the screen dropped', () => {
    expect(pickForRefinement([entry('bad', 0.9, 0, false), entry('good', 0.1, 1)], 3)).toEqual(['good'])
  })

  it('picks nothing when nothing survived, rather than picking anyway', () => {
    expect(pickForRefinement([entry('bad', 0.9, 0, false)], 3)).toEqual([])
    expect(pickForRefinement([], 3)).toEqual([])
  })
})
