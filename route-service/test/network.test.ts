import { describe, expect, it } from 'vitest'
import {
  EXPLORATION_SHARE,
  MIN_SECTOR_SAMPLES,
  REACH_SHARE_OF_TARGET,
  bearingIsPromising,
  biasAttemptsToNetwork,
  sectorFor,
  summariseNetwork,
  type ReachedPoint,
} from '../src/loops/network.js'
import { generateLoopAttempts } from '../src/loops/candidates.js'
import { parseShortestPathTree } from '../src/graphhopper.js'
import { destination, type LngLat } from '../src/loops/geo.js'
import { FIXTURE_ORIGIN } from './fixtures/routes.js'

const START: LngLat = FIXTURE_ORIGIN

/** Points spread along a bearing, with a network distance that stretches. */
const spoke = (bearing: number, furthestMetres: number, stretch = 1.3, count = 8): ReachedPoint[] =>
  Array.from({ length: count }, (_, index) => {
    const crow = (furthestMetres / stretch) * ((index + 1) / count)
    return { point: destination(START, crow, bearing), networkMetres: crow * stretch }
  })

/** A seafront: everything to the south is water. */
const seafront = (): ReachedPoint[] =>
  [270, 300, 330, 0, 30, 60, 90].flatMap(bearing => spoke(bearing, 1800))

describe('summarising what the network reaches', () => {
  it('finds the furthest the network goes in each direction', () => {
    const summary = summariseNetwork(START, [...spoke(90, 2000), ...spoke(270, 400)])
    expect(sectorFor(summary, 90).reachMetres).toBeCloseTo(2000, -1)
    expect(sectorFor(summary, 270).reachMetres).toBeCloseTo(400, -1)
  })

  it('measures how much further the network makes you walk than the crow flies', () => {
    const summary = summariseNetwork(START, spoke(45, 1500, 1.6))
    expect(sectorFor(summary, 45).stretch).toBeCloseTo(1.6, 1)
    expect(summary.medianStretch).toBeCloseTo(1.6, 1)
  })

  it('knows the sea is empty', () => {
    const summary = summariseNetwork(START, seafront())
    for (const bearing of [150, 180, 210]) expect(sectorFor(summary, bearing).samples).toBe(0)
    for (const bearing of [0, 90, 270]) expect(sectorFor(summary, bearing).samples).toBeGreaterThan(0)
  })

  it('ignores the doorstep, where a bearing means nothing', () => {
    const doorstep: ReachedPoint[] = Array.from({ length: 20 }, (_, index) => ({
      point: destination(START, 5 + index, index * 18),
      networkMetres: 30,
    }))
    expect(summariseNetwork(START, doorstep).sectors.every(sector => sector.samples === 0)).toBe(true)
  })

  it('answers something usable for a probe that found nothing', () => {
    const summary = summariseNetwork(START, [])
    expect(summary.medianStretch).toBe(1)
    expect(summary.samples).toBe(0)
    expect(summary.sectors.every(sector => sector.reachMetres === 0)).toBe(true)
  })
})

describe('deciding a bearing is worth trying', () => {
  const summary = summariseNetwork(START, seafront())

  it('likes a direction with a loop’s worth of network in it', () => {
    expect(bearingIsPromising(summary, 90, 5000)).toBe(true)
  })

  it('does not like the sea', () => {
    expect(bearingIsPromising(summary, 180, 5000)).toBe(false)
  })

  it('does not like a direction that runs out well short of the walk', () => {
    const shallow = summariseNetwork(START, spoke(0, 200))
    expect(bearingIsPromising(shallow, 0, 5000)).toBe(false)
    expect(bearingIsPromising(shallow, 0, 200 / REACH_SHARE_OF_TARGET)).toBe(true)
  })

  it('treats a handful of points as no evidence either way', () => {
    const thin = summariseNetwork(START, spoke(0, 4000, 1.3, MIN_SECTOR_SAMPLES - 1))
    expect(bearingIsPromising(thin, 0, 1000)).toBe(false)
  })
})

describe('aiming the batch at the network', () => {
  const attempts = generateLoopAttempts(1234, 24)
  const summary = summariseNetwork(START, seafront())

  it('is a reordering and never a cull', () => {
    const biased = biasAttemptsToNetwork(attempts, summary, 5000)
    expect(biased).toHaveLength(attempts.length)
    expect(biased.map(a => a.id).sort()).toEqual(attempts.map(a => a.id).sort())
  })

  it('puts the directions with network in them first', () => {
    const biased = biasAttemptsToNetwork(attempts, summary, 5000)
    const firstHalf = biased.slice(0, 8)
    expect(firstHalf.every(attempt => bearingIsPromising(summary, attempt.initialBearing, 5000))).toBe(true)
  })

  it('still tries some of the sea, because one probe is not the last word', () => {
    const biased = biasAttemptsToNetwork(attempts, summary, 5000)
    const unpromising = biased.filter(attempt => !bearingIsPromising(summary, attempt.initialBearing, 5000))
    expect(unpromising.length).toBeGreaterThan(0)
    expect(EXPLORATION_SHARE).toBeGreaterThan(0)
  })

  it('renumbers so the first attempt dispatched is attempt zero', () => {
    const biased = biasAttemptsToNetwork(attempts, summary, 5000)
    expect(biased.map(a => a.index)).toEqual(biased.map((_, index) => index))
  })

  it('leaves the order alone when the probe liked nothing', () => {
    const nothing = summariseNetwork(START, [])
    expect(biasAttemptsToNetwork(attempts, nothing, 5000)).toEqual(attempts)
  })

  it('is deterministic', () => {
    expect(biasAttemptsToNetwork(attempts, summary, 5000)).toEqual(biasAttemptsToNetwork(attempts, summary, 5000))
  })
})

describe('reading a shortest-path tree off the wire', () => {
  it('reads the rows it understands', () => {
    const reached = parseShortestPathTree('longitude,latitude,distance\n-4.48,54.15,120\n-4.47,54.16,340\n')!
    expect(reached).toHaveLength(2)
    expect(reached[0]).toEqual({ point: [-4.48, 54.15], networkMetres: 120 })
  })

  it('skips the header and anything else that is not three numbers', () => {
    const reached = parseShortestPathTree('longitude,latitude,distance\n-4.48,54.15,120\nnonsense\n1,2\n999,54,10\n')!
    expect(reached).toEqual([{ point: [-4.48, 54.15], networkMetres: 120 }])
  })

  it('says nothing at all when the answer was not a table of numbers', () => {
    expect(parseShortestPathTree('<html>Not Found</html>')).toBeUndefined()
    expect(parseShortestPathTree('')).toBeUndefined()
    expect(parseShortestPathTree('longitude,latitude,distance\n')).toBeUndefined()
  })
})
