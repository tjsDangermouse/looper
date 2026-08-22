import { describe, expect, it } from 'vitest'
import booleanPointInPolygon from '@turf/boolean-point-in-polygon'
import { AVOID_PRIORITY, RELAXED_AVOID_PRIORITY } from '../src/loops/avoidance.js'
import { generateCandidateShapes, shapeToLegPoints } from '../src/loops/candidates.js'
import { buildRouteBody, GraphHopperError, parseLeg, maneuverName, isUTurnSign, type GraphHopperLeg } from '../src/graphhopper.js'
import { LEG_BUDGET_SHARE, joinLegGeometries, routeCandidateSequentially } from '../src/loops/routing.js'
import type { LngLat } from '../src/loops/geo.js'
import { FIXTURE_ORIGIN, at, polyline } from './fixtures/routes.js'

const START: LngLat = FIXTURE_ORIGIN
const shape = generateCandidateShapes(START, 5000, 12345)[0]

/** A router that answers every leg with a straight line between its points. */
function straightRouter(record: Array<{ points: LngLat[]; model: any }> = []) {
  const route = async (points: LngLat[], model: any): Promise<GraphHopperLeg> => {
    record.push({ points, model })
    const coordinates = densify(points[0], points[1])
    const distanceMeters = metres(points[0], points[1])
    return {
      coordinates,
      distanceMeters,
      durationSeconds: distanceMeters / (5000 / 3600),
      steps: [
        { instruction: 'Continue', distanceMeters, durationSeconds: distanceMeters / 1.39, sign: 0, startIndex: 0, endIndex: coordinates.length - 1 },
        { instruction: 'Arrive at destination', distanceMeters: 0, durationSeconds: 0, sign: 4, startIndex: coordinates.length - 1, endIndex: coordinates.length - 1 },
      ],
    }
  }
  return { route, record }
}

const metres = (a: LngLat, b: LngLat) => {
  const dy = (b[1] - a[1]) * 111195
  const dx = (b[0] - a[0]) * 111195 * Math.cos((a[1] * Math.PI) / 180)
  return Math.hypot(dx, dy)
}
function densify(a: LngLat, b: LngLat): LngLat[] {
  const steps = Math.max(2, Math.round(metres(a, b) / 25))
  return Array.from({ length: steps + 1 }, (_, i) => [a[0] + (b[0] - a[0]) * (i / steps), a[1] + (b[1] - a[1]) * (i / steps)] as LngLat)
}

describe('the request sent to the routing engine', () => {
  it('asks for one ordinary leg, not a round trip', () => {
    const body = buildRouteBody([START, at(500, 500)], { profile: 'foot' })
    expect(body.points).toHaveLength(2)
    expect(JSON.stringify(body)).not.toContain('round_trip')
    expect(body.profile).toBe('foot')
  })
  it('turns off contraction hierarchies, which a per-request custom model needs', () => {
    expect(buildRouteBody([START, at(1, 1)], { profile: 'foot' })['ch.disable']).toBe(true)
  })
  it('asks for plain coordinates and turn instructions the walk screen can use', () => {
    const body = buildRouteBody([START, at(1, 1)], { profile: 'foot' })
    expect(body.points_encoded).toBe(false)
    expect(body.instructions).toBe(true)
    expect(body.details).toContain('street_name')
  })
  it('carries the custom model only when there is something to avoid', () => {
    expect(buildRouteBody([START, at(1, 1)], { profile: 'foot' }).custom_model).toBeUndefined()
    const model = { priority: [{ if: 'in_looper_avoid_0', multiply_by: '0.05' }] }
    expect(buildRouteBody([START, at(1, 1)], { profile: 'foot', customModel: model }).custom_model).toBe(model)
  })
})

describe('reading the engine’s answer', () => {
  const payload = {
    paths: [{
      distance: 1200.5,
      time: 900000,
      points: { type: 'LineString', coordinates: [[-4.48, 54.15], [-4.47, 54.16]] },
      instructions: [
        { text: 'Turn left onto Quay Road', distance: 800, time: 600000, sign: -2, street_name: 'Quay Road', interval: [0, 1] },
        { text: 'Arrive at destination', distance: 0, time: 0, sign: 4, street_name: '', interval: [1, 1] },
      ],
      details: { street_name: [[0, 1, 'Quay Road']] },
    }],
  }
  it('reads distance, duration and geometry', () => {
    const leg = parseLeg(payload)
    expect(leg.distanceMeters).toBe(1200.5)
    expect(leg.durationSeconds).toBe(900)
    expect(leg.coordinates).toHaveLength(2)
  })
  it('keeps the street name the walk screen reads aloud', () => {
    expect(parseLeg(payload).steps[0].road).toBe('Quay Road')
  })
  it('names the manoeuvre without exposing the engine’s numbering', () => {
    expect(maneuverName(-2)).toBe('turn-left')
    expect(maneuverName(4)).toBe('finish')
    expect(isUTurnSign(-98)).toBe(true)
    expect(isUTurnSign(2)).toBe(false)
  })
  it('treats a pathless answer as a leg that cannot be walked', () => {
    expect(() => parseLeg({ paths: [] })).toThrow(GraphHopperError)
  })
})

describe('sequential leg routing', () => {
  it('routes the four legs of the ring in order', async () => {
    const { route, record } = straightRouter()
    const candidate = await routeCandidateSequentially(START, shape, route)
    expect(candidate).toBeDefined()
    expect(record).toHaveLength(4)
    const expected = shapeToLegPoints(START, shape)
    record.forEach((call, index) => {
      expect(call.points[0]).toEqual(expected[index])
      expect(call.points[1]).toEqual(expected[index + 1])
    })
  })
  it('sends no avoidance on the first leg and some on every leg after', async () => {
    const { route, record } = straightRouter()
    await routeCandidateSequentially(START, shape, route)
    expect(record[0].model).toBeUndefined()
    for (const call of record.slice(1)) {
      expect(call.model.priority.length).toBeGreaterThan(0)
      expect(call.model.priority[0].multiply_by).toBe(String(AVOID_PRIORITY))
    }
  })
  it('hands on the ground every earlier leg covered', async () => {
    const { route, record } = straightRouter()
    await routeCandidateSequentially(START, shape, route)
    const areas = record[3].model.areas.features
    const midpointOfLegOne = midpoint(record[0].points[0], record[0].points[1])
    const midpointOfLegTwo = midpoint(record[1].points[0], record[1].points[1])
    expect(areas.some((area: any) => booleanPointInPolygon(midpointOfLegOne, area))).toBe(true)
    expect(areas.some((area: any) => booleanPointInPolygon(midpointOfLegTwo, area))).toBe(true)
  })
  it('never penalises the streets on the doorstep', async () => {
    const { route, record } = straightRouter()
    await routeCandidateSequentially(START, shape, route)
    for (const call of record.slice(1)) {
      for (const area of call.model.areas.features) expect(booleanPointInPolygon(START, area)).toBe(false)
    }
  })
  it('retries a blocked leg once, still penalised but less absolutely', async () => {
    const calls: any[] = []
    let refused = false
    const route = async (points: LngLat[], model: any) => {
      calls.push({ points, model })
      if (model && model.priority[0].multiply_by === String(AVOID_PRIORITY) && !refused) {
        refused = true
        throw new GraphHopperError('Connection between locations not found', 400, 'unreachable')
      }
      return straightRouter().route(points, model)
    }
    const candidate = await routeCandidateSequentially(START, shape, route)
    expect(candidate).toBeDefined()
    expect(calls[2].model.priority[0].multiply_by).toBe(String(RELAXED_AVOID_PRIORITY))
    expect(calls[2].points).toEqual(calls[1].points)
  })
  it('spends the retry when the penalty buys an absurd detour, not only on a refusal', async () => {
    // The real failure in open country: the engine never refuses a penalised
    // corridor, it walks six kilometres round it. Nothing throws, so a retry
    // that only fires on an exception never fires at all.
    const calls: any[] = []
    const route = async (points: LngLat[], model: any) => {
      calls.push({ points, model })
      const leg = await straightRouter().route(points, model)
      const heavilyPenalised = model?.priority?.[0]?.multiply_by === String(AVOID_PRIORITY)
      return heavilyPenalised ? { ...leg, distanceMeters: 9000 } : leg
    }
    const candidate = await routeCandidateSequentially(START, shape, route, { legBudgetMetres: 2500 })
    expect(candidate).toBeDefined()
    // Leg one is unpenalised; legs two to four each get a second, cheaper try.
    expect(calls.filter(call => call.model?.priority?.[0]?.multiply_by === String(RELAXED_AVOID_PRIORITY))).toHaveLength(3)
    expect(candidate!.legs.slice(1).every(leg => leg.relaxed)).toBe(true)
    expect(candidate!.distanceMeters).toBeLessThan(9000 * 3)
  })

  it('keeps the strongly penalised leg when relaxing it does not actually help', async () => {
    const route = async (points: LngLat[], model: any) => {
      const leg = await straightRouter().route(points, model)
      return model ? { ...leg, distanceMeters: 9000 } : leg
    }
    const candidate = await routeCandidateSequentially(START, shape, route, { legBudgetMetres: 2500 })
    expect(candidate!.legs.slice(1).every(leg => leg.relaxed)).toBe(false)
  })

  it('leaves a leg inside its budget alone', async () => {
    const { route, record } = straightRouter()
    await routeCandidateSequentially(START, shape, route, { legBudgetMetres: 50_000 })
    expect(record).toHaveLength(4)
  })

  it('holds one leg to half the walk before calling the penalty the problem', () => {
    expect(LEG_BUDGET_SHARE).toBe(0.5)
  })

  it('pulls a dead-ending waypoint back toward the start and re-routes both legs that meet there', async () => {
    // Waypoint 1 is only reachable via a spur through D: the leg arriving there
    // and the leg leaving it both detour via D, so the walk arrives at the
    // waypoint heading one way and immediately leaves heading back the way it
    // came — exactly what a cul-de-sac produces. Any other pair of points,
    // including whatever pulled-in point the retry asks for, routes straight.
    const points = shapeToLegPoints(START, shape)
    const waypoint1 = points[1]
    const D: LngLat = [START[0] + (waypoint1[0] - START[0]) * 0.4, START[1] + (waypoint1[1] - START[1]) * 0.4]
    const same = (a: LngLat, b: LngLat) => Math.abs(a[0] - b[0]) < 1e-9 && Math.abs(a[1] - b[1]) < 1e-9
    const calls: Array<{ points: LngLat[] }> = []
    const route = async (legPoints: LngLat[], model: any): Promise<GraphHopperLeg> => {
      calls.push({ points: legPoints })
      const [a, b] = legPoints
      if (same(a, waypoint1) || same(b, waypoint1)) {
        const viaD = joinLegGeometries([await straightRouter().route([a, D], model), await straightRouter().route([D, b], model)])
        return { ...viaD, steps: [] }
      }
      return straightRouter().route(legPoints, model)
    }
    const candidate = await routeCandidateSequentially(START, shape, route)
    expect(candidate).toBeDefined()
    // The dead end was tried at least once, and both legs meeting there were
    // then routed a second time to or from some other point — the pulled-in
    // replacement, not the original waypoint.
    const toOrFromWaypoint1 = calls.filter(call => same(call.points[0], waypoint1) || same(call.points[1], waypoint1))
    expect(toOrFromWaypoint1.length).toBeGreaterThan(0)
    const avoidingWaypoint1 = calls.filter(call => !same(call.points[0], waypoint1) && !same(call.points[1], waypoint1))
    expect(avoidingWaypoint1.length).toBeGreaterThan(2) // the untouched legs 2 and 3, plus the two re-routed legs
    // The pulled-in point replaces the original in the final route: nothing in
    // the joined geometry sits exactly on the dead end any more.
    expect(candidate!.coordinates.some(point => same(point, waypoint1))).toBe(false)
  })

  it('gives the candidate up rather than routing it without any penalty at all', async () => {
    const attempts: any[] = []
    const route = async (points: LngLat[], model: any) => {
      attempts.push(model)
      if (model) throw new GraphHopperError('no path', 400, 'unreachable')
      return straightRouter().route(points, model)
    }
    const candidate = await routeCandidateSequentially(START, shape, route)
    expect(candidate).toBeUndefined()
    // Leg one unpenalised, then the strong and relaxed attempts at leg two.
    expect(attempts).toHaveLength(3)
    expect(attempts.filter(model => model === undefined)).toHaveLength(1)
  })
  it('lets the engine being unreachable surface rather than swallowing it', async () => {
    const route = async () => { throw new GraphHopperError('down', undefined, 'transport') }
    await expect(routeCandidateSequentially(START, shape, route)).rejects.toThrow(GraphHopperError)
  })
  it('abandons a candidate that has already overshot', async () => {
    const { route } = straightRouter()
    const candidate = await routeCandidateSequentially(START, shape, route, { abandonAboveMetres: 100 })
    expect(candidate).toBeUndefined()
  })
})

describe('joining the legs into one walk', () => {
  const leg = (from: LngLat, to: LngLat, instruction: string): GraphHopperLeg => {
    const coordinates = densify(from, to)
    return {
      coordinates,
      distanceMeters: metres(from, to),
      durationSeconds: 100,
      steps: [
        { instruction, distanceMeters: metres(from, to), durationSeconds: 100, sign: 0, startIndex: 0, endIndex: coordinates.length - 1 },
        { instruction: 'Arrive at destination', distanceMeters: 0, durationSeconds: 0, sign: 4, startIndex: coordinates.length - 1, endIndex: coordinates.length - 1 },
      ],
    }
  }
  const a = at(0, 0), b = at(600, 0), c = at(600, 600)
  const joined = joinLegGeometries([leg(a, b, 'Head east'), leg(b, c, 'Turn left')])

  it('does not repeat the point where two legs meet', () => {
    const seam = joined.coordinates.filter(point => point[0] === b[0] && point[1] === b[1])
    expect(seam).toHaveLength(1)
  })
  it('drops the arrival at every waypoint but the last', () => {
    const arrivals = joined.steps.filter(step => step.sign === 4)
    expect(arrivals).toHaveLength(1)
    expect(joined.steps[joined.steps.length - 1].sign).toBe(4)
  })
  it('adds up the distance and the time', () => {
    expect(joined.distanceMeters).toBeCloseTo(1200, 0)
    expect(joined.durationSeconds).toBe(200)
  })
  it('rebases each step onto the joined line', () => {
    for (const step of joined.steps) {
      expect(step.startIndex!).toBeGreaterThanOrEqual(0)
      expect(step.endIndex!).toBeLessThan(joined.coordinates.length)
    }
    expect(joined.steps[1].startIndex).toBeGreaterThan(joined.steps[0].endIndex! - 1)
  })
})

const midpoint = (a: LngLat, b: LngLat): LngLat => [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2]
void polyline
