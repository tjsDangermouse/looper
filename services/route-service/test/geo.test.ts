import { describe, expect, it } from 'vitest'
import { bearingBetween, boundingBoxSides, compactness, destination, haversine, normaliseBearing, normaliseLongitude, pathLength, projector, resample } from '../src/loops/geo.js'
import { at, cleanLoop, longOutAndBack, narrowElongated } from './fixtures/routes.js'

const DOUGLAS: [number, number] = [-4.4816, 54.1506]

describe('geodesic destination point', () => {
  it('walks the distance it was asked to walk', () => {
    for (const bearing of [0, 45, 90, 135, 180, 270, 359]) {
      expect(haversine(DOUGLAS, destination(DOUGLAS, 1200, bearing))).toBeCloseTo(1200, 3)
    }
  })
  it('sets off on the bearing it was given', () => {
    for (const bearing of [0, 37, 120, 240, 359]) {
      expect(bearingBetween(DOUGLAS, destination(DOUGLAS, 900, bearing))).toBeCloseTo(bearing, 4)
    }
  })
  it('does not simply add degrees to the longitude', () => {
    // At 54°N a degree of longitude is 59% of a degree of latitude. Naively
    // adding metres-as-degrees would put an easterly waypoint 41% too close.
    const east = destination(DOUGLAS, 1000, 90)
    const naive = DOUGLAS[0] + 1000 / 111320
    expect(east[0] - DOUGLAS[0]).toBeGreaterThan((naive - DOUGLAS[0]) * 1.5)
  })
  it('keeps a due-north step on the same meridian', () => {
    const north = destination(DOUGLAS, 2000, 0)
    expect(north[0]).toBeCloseTo(DOUGLAS[0], 9)
    expect(north[1]).toBeGreaterThan(DOUGLAS[1])
  })
  it('wraps across the antimeridian rather than running off the map', () => {
    const past = destination([179.99, 0], 5000, 90)
    expect(past[0]).toBeLessThan(0)
    expect(haversine([179.99, 0], past)).toBeCloseTo(5000, 2)
  })
  it('normalises longitudes and bearings', () => {
    expect(normaliseLongitude(190)).toBeCloseTo(-170, 9)
    expect(normaliseBearing(-30)).toBe(330)
  })
})

describe('local projection', () => {
  it('is the exact inverse of the fixture helper', () => {
    const project = projector([-4.4816, 54.1506])
    const [x, y] = project(at(250, -400))
    expect(x).toBeCloseTo(250, 3)
    expect(y).toBeCloseTo(-400, 3)
  })
})

describe('resampling', () => {
  it('cuts a path into near-uniform samples', () => {
    const { samples, totalMetres } = resample(cleanLoop, 15)
    expect(totalMetres).toBeCloseTo(pathLength(cleanLoop), 0)
    expect(samples.length).toBeGreaterThan(190)
    for (const sample of samples.slice(0, -1)) expect(sample.length).toBeLessThanOrEqual(15.001)
  })
  it('records how far along the route each sample sits', () => {
    const { samples } = resample(cleanLoop, 15)
    for (let i = 1; i < samples.length; i++) expect(samples[i].along).toBeGreaterThan(samples[i - 1].along)
  })
  it('gives back nothing for a path with no length', () => {
    expect(resample([[0, 0]], 15).samples).toHaveLength(0)
  })
})

describe('shape measures', () => {
  it('rates a circle as compact', () => expect(compactness(cleanLoop)).toBeGreaterThan(.98))
  it('rates a there-and-back as enclosing nothing', () => expect(compactness(longOutAndBack)).toBeLessThan(.01))
  it('measures a bounding box in metres', () => {
    const { longMetres, shortMetres } = boundingBoxSides(narrowElongated)
    expect(longMetres).toBeCloseTo(2000, 0)
    expect(shortMetres).toBeCloseTo(200, 0)
  })
})
