import booleanPointInPolygon from '@turf/boolean-point-in-polygon'
import { describe, expect, it } from 'vitest'
import { AVOID_PRIORITY, MAX_AVOIDANCE_AREAS, RELAXED_AVOID_PRIORITY, START_EXCLUSION_RADIUS_METRES, avoidanceCustomModel, buildAvoidanceAreas } from '../src/loops/avoidance.js'
import { destination, type LngLat } from '../src/loops/geo.js'
import { FIXTURE_ORIGIN, at, cleanLoop, polyline } from './fixtures/routes.js'

const START: LngLat = FIXTURE_ORIGIN
const inside = (areas: ReturnType<typeof buildAvoidanceAreas>, point: LngLat) =>
  areas.some(area => booleanPointInPolygon(point, area))

const leg = polyline([[0, 0], [0, 800]])

describe('avoidance corridors', () => {
  it('covers the ground the leg walked', () => {
    const areas = buildAvoidanceAreas([leg], START)
    expect(areas.length).toBeGreaterThan(0)
    expect(inside(areas, at(0, 400))).toBe(true)
    expect(inside(areas, at(15, 600))).toBe(true)
  })
  it('does not reach the next street over', () => {
    const areas = buildAvoidanceAreas([leg], START)
    expect(inside(areas, at(120, 400))).toBe(false)
  })
  it('leaves the streets around the start alone', () => {
    const areas = buildAvoidanceAreas([leg], START)
    // A shared first street is often the only way off the doorstep.
    expect(inside(areas, at(0, 30))).toBe(false)
    expect(inside(areas, at(0, 60))).toBe(false)
    expect(inside(areas, at(0, START_EXCLUSION_RADIUS_METRES + 25))).toBe(true)
  })
  it('honours a different exclusion radius', () => {
    const areas = buildAvoidanceAreas([leg], START, { startExclusionMetres: 200 })
    expect(inside(areas, at(0, 150))).toBe(false)
    expect(inside(areas, at(0, 260))).toBe(true)
  })
  it('accumulates every leg walked so far', () => {
    const second = polyline([[0, 800], [700, 800]])
    const areas = buildAvoidanceAreas([leg, second], START)
    expect(inside(areas, at(0, 500))).toBe(true)
    expect(inside(areas, at(400, 800))).toBe(true)
  })
  it('returns plain polygons, which is what the engine documents', () => {
    const apart = polyline([[2000, 2000], [2600, 2000]])
    const areas = buildAvoidanceAreas([leg, apart], START)
    expect(areas.length).toBeGreaterThanOrEqual(2)
    for (const area of areas) expect(area.geometry.type).toBe('Polygon')
  })
  it('caps how many areas one request carries', () => {
    const many = Array.from({ length: 30 }, (_, i) => polyline([[i * 400, 3000], [i * 400 + 200, 3000]]))
    expect(buildAvoidanceAreas(many, START).length).toBeLessThanOrEqual(MAX_AVOIDANCE_AREAS)
  })
  it('has nothing to avoid when the whole leg is on the doorstep', () => {
    const stub = polyline([[0, 0], [0, 40]])
    expect(buildAvoidanceAreas([stub], START)).toHaveLength(0)
  })
  it('ignores a leg that never moved', () => {
    expect(buildAvoidanceAreas([[START, START]], START)).toHaveLength(0)
  })
  it('handles a whole loop without falling over', () => {
    const areas = buildAvoidanceAreas([cleanLoop], START)
    expect(areas.length).toBeGreaterThan(0)
  })
})

describe('custom model', () => {
  const areas = buildAvoidanceAreas([leg], START)
  const model = avoidanceCustomModel(areas)!

  it('discourages each area at a twenty-fold cost', () => {
    expect(AVOID_PRIORITY).toBeCloseTo(0.05, 5)
    expect(1 / AVOID_PRIORITY).toBeCloseTo(20, 5)
    for (const rule of model.priority!) expect(rule.multiply_by).toBe('0.05')
  })
  it('names every area and refers to it with the in_ prefix the engine expects', () => {
    const ids = model.areas!.features.map(feature => feature.id as string)
    expect(ids).toEqual(ids.map((_, i) => `looper_avoid_${i}`))
    expect(model.priority!.map(rule => rule.if)).toEqual(ids.map(id => `in_${id}`))
  })
  it('sends the areas as a GeoJSON FeatureCollection', () => {
    expect(model.areas!.type).toBe('FeatureCollection')
    for (const feature of model.areas!.features) {
      expect(feature.type).toBe('Feature')
      expect(feature.geometry.type).toBe('Polygon')
      const ring = feature.geometry.coordinates[0]
      expect(ring[0]).toEqual(ring[ring.length - 1])
    }
  })
  it('discourages rather than forbids, so an unavoidable street stays walkable', () => {
    expect(AVOID_PRIORITY).toBeGreaterThan(0)
    expect(RELAXED_AVOID_PRIORITY).toBeGreaterThan(AVOID_PRIORITY)
    expect(RELAXED_AVOID_PRIORITY).toBeLessThan(1)
  })
  it('sends no custom model at all when there is nothing to avoid', () => {
    expect(avoidanceCustomModel([])).toBeUndefined()
  })
  it('can be asked for the reduced penalty used on a retry', () => {
    const relaxed = avoidanceCustomModel(areas, RELAXED_AVOID_PRIORITY)!
    for (const rule of relaxed.priority!) expect(rule.multiply_by).toBe('0.2')
  })
})

describe('corridor width', () => {
  it('is wide enough to catch the pavement on the other side of the road', () => {
    const areas = buildAvoidanceAreas([leg], START)
    expect(inside(areas, destination(at(0, 400), 20, 90))).toBe(true)
    expect(inside(areas, destination(at(0, 400), 40, 90))).toBe(false)
  })
})
