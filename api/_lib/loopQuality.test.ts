import { describe, expect, it } from 'vitest'
import { describeDirection, measure, nameLoops, overlapFraction, retraceFraction, roundness, scoreLoop, selectLoops, sharpTurnsPerKm, type Point } from './loopQuality'

// Roughly 111 m per 0.001° of latitude, so these shapes are a few hundred metres across.
const square: Point[] = [[0, 0], [.004, 0], [.004, .004], [0, .004], [0, 0]]
const circle: Point[] = Array.from({ length: 65 }, (_, i) => [.004 * Math.cos(i * Math.PI / 32), .004 * Math.sin(i * Math.PI / 32)] as Point)
const outAndBack: Point[] = [[0, 0], [.001, 0], [.002, 0], [.003, 0], [.002, 0], [.001, 0], [0, 0]]
// A clean square with a dead-end spur walked out and back — the reported failure.
const squareWithSpur: Point[] = [[0, 0], [.004, 0], [.004, .002], [.006, .002], [.004, .002], [.004, .004], [0, .004], [0, 0]]
const metrics = (coordinates: Point[]) => measure(coordinates, 1000, 1000, [])

describe('loop shape', () => {
  it('sees no retracing on a clean circuit', () => expect(retraceFraction(square)).toBe(0))
  it('counts an out-and-back as entirely retraced', () => expect(retraceFraction(outAndBack)).toBeCloseTo(1, 2))
  it('measures the share of a loop spent on a spur', () => {
    const fraction = retraceFraction(squareWithSpur)
    expect(fraction).toBeGreaterThan(.1)
    expect(fraction).toBeLessThan(.35)
  })
  it('rates a circle as round', () => expect(roundness(circle)).toBeGreaterThan(.95))
  it('rates a square below a circle but well clear of zero', () => {
    expect(roundness(square)).toBeGreaterThan(.7)
    expect(roundness(square)).toBeLessThan(roundness(circle))
  })
  it('rates an out-and-back as having no shape', () => expect(roundness(outAndBack)).toBeLessThan(.01))
  it('counts sharp turns and U-turns per kilometre', () => expect(sharpTurnsPerKm([0, 2, 9, 6, 3], 2000)).toBe(1.5))
})

describe('scoring', () => {
  it('prefers the clean circuit to the one with a spur', () => expect(scoreLoop(metrics(square))).toBeGreaterThan(scoreLoop(metrics(squareWithSpur))))
  it('prefers the spur to walking the same path both ways', () => expect(scoreLoop(metrics(squareWithSpur))).toBeGreaterThan(scoreLoop(metrics(outAndBack))))
  it('penalises missing the requested distance', () => expect(scoreLoop(measure(square, 1400, 1000, []))).toBeLessThan(scoreLoop(measure(square, 1000, 1000, []))))
  it('penalises a route peppered with sharp turns', () => expect(scoreLoop(measure(square, 1000, 1000, [2, 3, 9, 2, 3]))).toBeLessThan(scoreLoop(metrics(square))))
})

describe('overlap', () => {
  const shifted = square.map(([x, y]) => [x + .02, y] as Point)
  it('finds a loop identical to itself', () => expect(overlapFraction(square, square)).toBeCloseTo(1, 2))
  it('finds nothing in common between distant loops', () => expect(overlapFraction(square, shifted)).toBe(0))
  it('ignores the direction a shared street is walked in', () => expect(overlapFraction(square, [...square].reverse())).toBeCloseTo(1, 2))
})

describe('selection', () => {
  const candidate = (coordinates: Point[]) => ({ coordinates, metrics: metrics(coordinates) })
  const east = candidate(square.map(([x, y]) => [x + .02, y] as Point))
  const north = candidate(square.map(([x, y]) => [x, y + .02] as Point))

  it('drops loops that mostly retrace themselves', () => {
    const chosen = selectLoops([candidate(outAndBack), candidate(square), east, north])
    expect(chosen.map(c => c.coordinates)).not.toContain(outAndBack)
    expect(chosen).toHaveLength(3)
  })
  it('offers distinct walks rather than three near-copies', () => {
    const chosen = selectLoops([candidate(square), candidate([...square].reverse()), east, north])
    expect(chosen).toHaveLength(3)
    for (let i = 0; i < chosen.length; i++) for (let j = i + 1; j < chosen.length; j++) expect(overlapFraction(chosen[i].coordinates, chosen[j].coordinates)).toBeLessThan(.55)
  })
  it('ranks the best loop first', () => expect(selectLoops([candidate(squareWithSpur), candidate(square)], 2)[0].coordinates).toBe(square))
  it('would rather offer a poor loop than none at all', () => expect(selectLoops([candidate(outAndBack)])).toHaveLength(1))
  it('never offers a walk near double the length asked for', () => {
    const doubled = { coordinates: square, metrics: measure(square, 1900, 1000, []) }
    expect(selectLoops([doubled])).toHaveLength(0)
  })
  it('drops loops that badly miss the distance asked for', () => {
    const overshoot = { coordinates: east.coordinates, metrics: measure(east.coordinates, 3000, 1000, []) }
    expect(selectLoops([overshoot, candidate(square), north], 3, false)).toHaveLength(2)
  })
  it('reports how many candidates clear the bar outright', () => expect(selectLoops([candidate(outAndBack), candidate(square)], 3, false)).toHaveLength(1))
  it('offers nothing at all when asked not to relax', () => expect(selectLoops([candidate(outAndBack)], 3, false)).toHaveLength(0))
})

describe('naming', () => {
  const at = (dx: number, dy: number) => square.map(([x, y]) => [x + dx, y + dy] as Point)
  it('names a loop for the way it heads', () => expect(describeDirection(at(0, .02), [0, 0])).toBe('North loop'))
  it('names an easterly loop east', () => expect(describeDirection(at(.02, 0), [0, 0])).toBe('East loop'))
  it('names a diagonal loop between the two', () => expect(describeDirection(at(-.02, -.02), [0, 0])).toBe('South-west loop'))
  it('takes the direction from the far end of the walk, not the average', () => {
    // A loop that starts off north but reaches furthest to the east.
    const dogleg: Point[] = [[0, 0], [0, .004], [.03, .004], [.03, 0], [0, 0]]
    expect(describeDirection(dogleg, [0, 0])).toBe('East loop')
  })
  it('leaves distinct directions alone', () => expect(nameLoops([{ distanceMeters: 1000, direction: 'North loop' }, { distanceMeters: 2000, direction: 'West loop' }])).toEqual(['North loop', 'West loop']))
  it('tells two loops heading the same way apart by length', () =>
    expect(nameLoops([{ distanceMeters: 4000, direction: 'North loop' }, { distanceMeters: 2000, direction: 'North loop' }])).toEqual(['Longer north loop', 'Shorter north loop']))
  it('leaves the middle of three same-way loops unqualified', () =>
    expect(nameLoops([{ distanceMeters: 3000, direction: 'North loop' }, { distanceMeters: 2000, direction: 'North loop' }, { distanceMeters: 4000, direction: 'North loop' }]))
      .toEqual(['North loop', 'Shorter north loop', 'Longer north loop']))
})
