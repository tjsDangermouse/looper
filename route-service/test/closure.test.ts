import { describe, expect, it } from 'vitest'
import { estimateClosure, observedStretch } from '../src/loops/closure.js'
import { destination, type LngLat } from '../src/loops/geo.js'

const START: LngLat = [-4.4816, 54.1506]
const leg = (bearing: number, crow: number, stretch: number) => {
  const end = destination(START, crow, bearing)
  return { distanceMeters: crow * stretch, coordinates: [START, end] }
}

describe('closure estimator', () => {
  it('uses the median stretch already observed on this candidate', () => {
    const legs = [leg(0, 500, 1.1), leg(90, 500, 1.5), leg(180, 500, 1.9)]
    observedStretch(legs).forEach((value, index) => expect(value).toBeCloseTo([1.1, 1.5, 1.9][index], 6))
    const from = destination(START, 1000, 45)
    const estimate = estimateClosure(START, from, legs)
    expect(estimate.source).toBe('candidate-local')
    expect(estimate.stretch).toBeCloseTo(1.5, 6)
    expect(estimate.metres).toBeCloseTo(1500, 0)
  })

  it('uses a bounded global fallback before a candidate has any usable leg', () => {
    const from = destination(START, 1000, 45)
    const estimate = estimateClosure(START, from, [], { globalStretch: 3, maxStretch: 2 })
    expect(estimate.source).toBe('global')
    expect(estimate.stretch).toBe(2)
    expect(estimate.metres).toBeCloseTo(2000, 0)
  })

})
