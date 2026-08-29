import { describe, expect, it } from 'vitest'
import { RequestMetrics, classifyRequest, countingRouter, percentiles, quantile } from '../src/loops/metrics.js'
import { AVOID_PRIORITY, RELAXED_AVOID_PRIORITY, avoidanceCustomModel, shortestPathCustomModel } from '../src/loops/avoidance.js'
import { measureOffered } from '../src/loops/generate.js'
import { cleanLoop, twinA, twinB, longOutAndBack } from './fixtures/routes.js'
import type { GraphHopperLeg } from '../src/graphhopper.js'

const leg = (): GraphHopperLeg => ({ coordinates: [[0, 0], [0, 1]], distanceMeters: 100, durationSeconds: 60, steps: [] })

describe('what a request cost', () => {
  it('counts every engine call against the reason it was made', async () => {
    const metrics = new RequestMetrics()
    const route = countingRouter(async () => leg(), metrics)
    await route([], undefined, 'leg')
    await route([], undefined, 'leg')
    await route([], undefined, 'spike')

    const snapshot = metrics.snapshot()
    expect(snapshot.graphhopperCalls).toBe(3)
    expect(snapshot.callsByPurpose.leg).toBe(2)
    expect(snapshot.callsByPurpose.spike).toBe(1)
    expect(snapshot.callsByPurpose['join-pullback']).toBe(0)
  })

  it('still counts a call the engine refused, because the engine still did the work', async () => {
    const metrics = new RequestMetrics()
    const route = countingRouter(async () => { throw new Error('no path') }, metrics)
    await expect(route([], undefined, 'leg')).rejects.toThrow('no path')
    expect(metrics.snapshot().graphhopperCalls).toBe(1)
  })

  it('does not count the same call twice when the generator recurses', async () => {
    const metrics = new RequestMetrics()
    const once = countingRouter(async () => leg(), metrics)
    const twice = countingRouter(once, metrics)
    await twice([], undefined, 'leg')
    expect(metrics.snapshot().graphhopperCalls).toBe(1)
  })

  it('counts separately for separate requests', async () => {
    const first = new RequestMetrics()
    const second = new RequestMetrics()
    const shared = async () => leg()
    await countingRouter(shared, first)([], undefined, 'leg')
    await countingRouter(shared, second)([], undefined, 'leg')
    expect(first.snapshot().graphhopperCalls).toBe(1)
    expect(second.snapshot().graphhopperCalls).toBe(1)
  })

  it('reads the same however the work happened to interleave', async () => {
    const build = async (order: number[]) => {
      const metrics = new RequestMetrics(() => 0)
      for (const which of order) {
        if (which === 0) metrics.countCall('leg')
        if (which === 1) metrics.countRejection('shapeless')
        if (which === 2) metrics.countCandidatePassed()
      }
      return metrics.snapshot()
    }
    expect(await build([0, 1, 2, 0, 1])).toEqual(await build([1, 0, 0, 2, 1]))
  })

  it('sorts rejection reasons so two runs can be diffed', () => {
    const metrics = new RequestMetrics(() => 0)
    for (const reason of ['u-turns', 'distance', 'shapeless', 'distance']) metrics.countRejection(reason)
    const snapshot = metrics.snapshot()
    expect(Object.keys(snapshot.rejectionReasons)).toEqual(['distance', 'shapeless', 'u-turns'])
    expect(snapshot.rejectionReasons.distance).toBe(2)
    expect(snapshot.candidatesRejected).toBe(4)
  })

  it('leaves the router untouched when nothing is being measured', async () => {
    const original = async () => leg()
    expect(countingRouter(original, undefined)).toBe(original)
  })
})

describe('percentiles', () => {
  it('answers zero for no measurements at all', () => {
    expect(percentiles([])).toEqual({ median: 0, p95: 0, max: 0 })
  })

  it('reports a value that was actually measured, never one between two', () => {
    expect(quantile([10, 20, 30, 40], 0.5)).toBe(20)
    expect(quantile([10, 20, 30, 40], 0.95)).toBe(40)
    expect(quantile([7], 0.5)).toBe(7)
  })
})

describe('measuring what the walker was offered', () => {
  it('reports nothing rather than NaN when nothing was offered', () => {
    expect(measureOffered([], 5000).count).toBe(0)
    expect(measureOffered([], 5000).maxPairSharedPercent).toBe(0)
  })

  it('calls two loops eight metres apart nearly the same walk', () => {
    const quality = { repeatedPercent: 0, uTurnCount: 0 }
    const measured = measureOffered([
      { coordinates: twinA, distanceMeters: 3140, quality },
      { coordinates: twinB, distanceMeters: 3190, quality },
    ], 3140)
    expect(measured.maxPairSharedPercent).toBeGreaterThan(80)
  })

  it('calls two genuinely different walks different', () => {
    const quality = { repeatedPercent: 0, uTurnCount: 0 }
    const measured = measureOffered([
      { coordinates: cleanLoop, distanceMeters: 3140, quality },
      { coordinates: longOutAndBack, distanceMeters: 3000, quality },
    ], 3140)
    expect(measured.maxPairSharedPercent).toBeLessThan(30)
  })

  it('reports distance error against what the walker asked for', () => {
    const quality = { repeatedPercent: 4, uTurnCount: 1 }
    const measured = measureOffered([
      { coordinates: cleanLoop, distanceMeters: 5500, quality },
      { coordinates: twinA, distanceMeters: 4750, quality },
    ], 5000)
    expect(measured.maxDistanceErrorPercent).toBe(10)
    expect(measured.totalUTurns).toBe(2)
    expect(measured.maxRepeatedPercent).toBe(4)
  })
})

describe('classifying a call by the weighting it carried', () => {
  const areas = [{ type: 'Feature' as const, properties: {}, geometry: { type: 'Polygon' as const, coordinates: [[[0, 0], [0, 1], [1, 1], [0, 0]]] } }]

  it('calls a request with no model plain', () => {
    expect(classifyRequest(undefined)).toBe('plain')
    expect(classifyRequest(avoidanceCustomModel([]))).toBe('plain')
  })

  it('separates the two avoidance strengths, because they search differently', () => {
    expect(classifyRequest(avoidanceCustomModel(areas, AVOID_PRIORITY))).toBe('avoid-strong')
    expect(classifyRequest(avoidanceCustomModel(areas, RELAXED_AVOID_PRIORITY))).toBe('avoid-relaxed')
  })

  it('recognises a strength that is neither, rather than filing it as one of them', () => {
    expect(classifyRequest(avoidanceCustomModel(areas, 0.5))).toBe('avoid-other')
  })

  it('calls the shortest-path model a lower bound', () => {
    expect(classifyRequest(shortestPathCustomModel())).toBe('lower-bound')
  })

  it('does not let a model that is both pass as either', () => {
    expect(classifyRequest({ ...avoidanceCustomModel(areas)!, distance_influence: 2000 })).toBe('mixed')
  })
})
