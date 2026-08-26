import { describe, expect, it } from 'vitest'
import {
  DETOUR_SHARES,
  FEASIBILITY_TOLERANCE,
  allocateSlack,
  fitsInPlan,
  gapsDifferingBetween,
  guideForDetour,
  planSegmentOptions,
  spreadAllocations,
  type Allocation,
  type SegmentOption,
} from '../src/loops/waypoints.js'
import { haversine, type LngLat } from '../src/loops/geo.js'
import { at, FIXTURE_ORIGIN } from './fixtures/routes.js'

const A: LngLat = FIXTURE_ORIGIN
const B: LngLat = at(1000, 0)

describe('placing a shaping point to lengthen a gap', () => {
  it('makes the way round about as much longer as was asked for', () => {
    for (const extra of [200, 600, 1500]) {
      const guide = guideForDetour(A, B, extra, 1)
      const viaGuide = haversine(A, guide) + haversine(guide, B)
      expect(viaGuide - haversine(A, B)).toBeCloseTo(extra, -1)
    }
  })

  it('puts it on the side it was asked for, and the two are not the same place', () => {
    const left = guideForDetour(A, B, 600, 1)
    const right = guideForDetour(A, B, 600, -1)
    expect(haversine(left, right)).toBeGreaterThan(100)
  })

  it('never asks for a detour on top of the walk itself', () => {
    const guide = guideForDetour(A, B, 0, 1)
    expect(haversine(A, guide) + haversine(guide, B) - haversine(A, B)).toBeLessThan(10)
  })

  it('allows for the network making a crow-flight detour longer than asked', () => {
    const flat = planSegmentOptions(0, A, B, 1000, 1)
    const stretched = planSegmentOptions(0, A, B, 1000, 2)
    const reach = (plan: { guides: LngLat[] }) => plan.guides.length ? haversine(A, plan.guides[0]) : 0
    // Where the network doubles every crow-flight metre, the shaping point has
    // to sit closer in for the walk to come out the same length.
    expect(reach(stretched[1])).toBeLessThan(reach(flat[1]))
  })
})

describe('what each gap is offered', () => {
  it('always offers the shortest way, whatever the slack', () => {
    for (const slack of [0, 100, 5000]) {
      expect(planSegmentOptions(0, A, B, slack)[0].guides).toEqual([])
    }
  })

  it('offers nothing but the shortest way when there is nothing to spend', () => {
    expect(planSegmentOptions(0, A, B, 0)).toHaveLength(1)
    expect(planSegmentOptions(0, A, B, -500)).toHaveLength(1)
  })

  it('offers each detour size both ways round', () => {
    const planned = planSegmentOptions(0, A, B, 1000)
    expect(planned).toHaveLength(1 + (DETOUR_SHARES.length - 1) * 2)
    expect(new Set(planned.map(plan => plan.id)).size).toBe(planned.length)
  })

  it('never invents a place the walker did not choose as an anchor', () => {
    // Guides are shaping points between anchors, never anchors themselves:
    // every plan still runs from exactly `from` to exactly `to`.
    for (const plan of planSegmentOptions(0, A, B, 1200)) {
      expect(plan.guides.length).toBeLessThanOrEqual(2)
      for (const guide of plan.guides) {
        expect(guide).not.toEqual(A)
        expect(guide).not.toEqual(B)
      }
    }
  })
})

describe('spending the slack across the gaps', () => {
  const option = (gap: number, id: string, distanceMeters: number): SegmentOption => ({
    gap, id: `${gap}-${id}`, guides: [], distanceMeters, durationSeconds: distanceMeters / 1.39,
  })

  it('picks the combination that adds up to the walk that was asked for', () => {
    const [best] = allocateSlack([
      [option(0, 'short', 1000), option(0, 'long', 2000)],
      [option(1, 'short', 1000), option(1, 'long', 3000)],
    ], { target: 4000 })
    expect(best.total).toBe(4000)
    expect(best.error).toBe(0)
  })

  it('spreads the detour rather than dumping it all in one gap', () => {
    // Three combinations come to exactly 3 km. Two of them spend their whole
    // detour in a single gap; one splits it. Splitting it is the better walk.
    const allocations = allocateSlack([
      [option(0, 'short', 1000), option(0, 'mid', 1500), option(0, 'long', 2000)],
      [option(1, 'short', 1000), option(1, 'mid', 1500), option(1, 'long', 2000)],
    ], { target: 3000, limit: 4 })
    expect(allocations[0].error).toBe(0)
    expect(allocations[0].chosen.map(chosen => chosen.id)).toEqual(['0-mid', '1-mid'])
    expect(allocations[0].concentration).toBeCloseTo(0.5, 5)
  })

  it('offers several different ways of spending it', () => {
    const gaps = [0, 1, 2].map(gap => [200, 400, 600, 800].map(metres => option(gap, `${metres}`, metres)))
    const allocations = allocateSlack(gaps, { target: 1500, limit: 5 })
    expect(allocations.length).toBeGreaterThan(1)
    expect(new Set(allocations.map(a => a.chosen.map(c => c.id).join('|'))).size).toBe(allocations.length)
  })

  it('keeps every gap, in order, exactly once', () => {
    const gaps = [0, 1, 2, 3].map(gap => [500, 900].map(metres => option(gap, `${metres}`, metres)))
    for (const allocation of allocateSlack(gaps, { target: 2800, limit: 4 })) {
      expect(allocation.chosen.map(chosen => chosen.gap)).toEqual([0, 1, 2, 3])
    }
  })

  it('gives the same answer every time', () => {
    const gaps = [0, 1, 2].map(gap => [300, 500, 900].map(metres => option(gap, `${metres}`, metres)))
    const once = allocateSlack(gaps, { target: 1800, limit: 4 })
    const twice = allocateSlack(gaps, { target: 1800, limit: 4 })
    expect(twice).toEqual(once)
  })

  it('does not depend on the order the options came in', () => {
    const forwards = [0, 1].map(gap => [300, 700, 1100].map(metres => option(gap, `${metres}`, metres)))
    const backwards = forwards.map(gap => [...gap].reverse())
    const key = (allocations: Allocation[]) => allocations.map(a => a.chosen.map(c => c.id).join('|'))
    expect(key(allocateSlack(backwards, { target: 1400, limit: 3 })))
      .toEqual(key(allocateSlack(forwards, { target: 1400, limit: 3 })))
  })

  it('stays bounded however many options it is handed', () => {
    const gaps = Array.from({ length: 5 }, (_, gap) =>
      Array.from({ length: 11 }, (_, index) => option(gap, `o${index}`, 200 + index * 130)))
    const allocations = allocateSlack(gaps, { target: 5000, limit: 6 })
    // Sixty-one thousand combinations; a bounded table and six answers.
    expect(allocations.length).toBeLessThanOrEqual(6)
    expect(allocations.every(a => a.chosen.length === 5)).toBe(true)
  })

  it('answers nothing when a gap has no way across it at all', () => {
    expect(allocateSlack([[option(0, 'a', 500)], []], { target: 1000 })).toEqual([])
    expect(allocateSlack([], { target: 1000 })).toEqual([])
  })
})

describe('choosing between combinations that all fit', () => {
  const allocation = (ids: string[], error: number): Allocation => ({
    chosen: ids.map((id, gap) => ({ gap, id, guides: [], distanceMeters: 100, durationSeconds: 72 })),
    total: 100 * ids.length,
    error,
    concentration: 0,
  })

  it('counts how many gaps two combinations disagree about', () => {
    expect(gapsDifferingBetween(allocation(['a', 'b', 'c'], 0), allocation(['a', 'b', 'c'], 0))).toBe(0)
    expect(gapsDifferingBetween(allocation(['a', 'b', 'c'], 0), allocation(['a', 'x', 'y'], 0))).toBe(2)
  })

  it('takes the closest first, then whatever is most unlike what it has', () => {
    const spread = spreadAllocations([
      allocation(['a', 'b', 'c'], 0),
      allocation(['a', 'b', 'x'], 10),
      allocation(['p', 'q', 'r'], 20),
    ], 2)
    expect(spread[0].chosen.map(c => c.id)).toEqual(['a', 'b', 'c'])
    expect(spread[1].chosen.map(c => c.id)).toEqual(['p', 'q', 'r'])
  })

  it('never returns more than it was asked for, or invents one', () => {
    expect(spreadAllocations([], 3)).toEqual([])
    expect(spreadAllocations([allocation(['a'], 0)], 3)).toHaveLength(1)
  })
})

describe('whether a walk through the pins fits the plan at all', () => {
  it('accepts a backbone comfortably inside the plan', () => {
    expect(fitsInPlan(4000, 5000, 0.25)).toBe(true)
  })

  it('accepts one that is over by less than the tolerance allows', () => {
    expect(fitsInPlan(5000 * 1.25, 5000, 0.25)).toBe(true)
    expect(fitsInPlan(5000 * 1.25 * (1 + FEASIBILITY_TOLERANCE) - 1, 5000, 0.25)).toBe(true)
  })

  it('refuses one that is genuinely too long', () => {
    expect(fitsInPlan(9000, 5000, 0.25)).toBe(false)
  })

  it('gives the walker the benefit of the doubt at the boundary', () => {
    // Exactly on the limit is inside it: refusing costs a walker their walk.
    const exactly = 5000 * 1.25
    expect(fitsInPlan(exactly, 5000, 0.25)).toBe(true)
    expect(fitsInPlan(exactly * (1 + FEASIBILITY_TOLERANCE * 2), 5000, 0.25)).toBe(false)
  })

  it('refuses a plan of nothing rather than dividing by it', () => {
    expect(fitsInPlan(1000, 0, 0.25)).toBe(false)
  })
})
