import { describe, expect, it } from 'vitest'
import { constructRemainingShape, estimateFullShape } from '../src/loops/fullShape.js'

describe('full-shape distance prediction', () => {
  const start: [number, number] = [-4.48, 54.15]

  it('constructs every remaining corner segment and the final closure as one shape', () => {
    const shape = constructRemainingShape(start, start, 3, 1_000, 0, 'clockwise', 3)
    expect(shape.segmentMetres).toHaveLength(4)
    expect(shape.segmentMetres.slice(0, 3)).toEqual(expect.arrayContaining([
      expect.closeTo(1_000, 0), expect.closeTo(1_000, 0), expect.closeTo(1_000, 0),
    ]))
    expect(shape.segmentMetres[3]).toBeGreaterThan(0)
  })

  it('keeps F1 neutral and blends local evidence conservatively', () => {
    const shape = constructRemainingShape(start, start, 1, 1_000, 90, 'clockwise', 3)
    const leg = { distanceMeters: 2_000, coordinates: [start, [-4.4646, 54.15] as [number, number]] }
    const predicted = estimateFullShape(500, shape, [leg])
    expect(predicted.f1).toBeCloseTo(500 + shape.crowMetres * 1.35, 6)
    expect(predicted.localStretch).toBeGreaterThan(predicted.blendedStretch)
    expect(predicted.blendedStretch).toBeGreaterThan(1.35)
  })
})
