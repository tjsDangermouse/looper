import { describe, expect, it } from 'vitest'
import { ESTIMATED_WALKING_SPEED_KMH, KM_PER_MILE, kmToMetres, kmToMiles, metresForPace, milesToKm, minutesToMetres, targetMetresFor, targetSecondsFor } from '../src/loops/units.js'

describe('units', () => {
  it('uses the exact statute mile', () => expect(KM_PER_MILE).toBe(1.609344))
  it('converts miles to kilometres', () => expect(milesToKm(1)).toBeCloseTo(1.609344, 6))
  it('converts kilometres to miles', () => expect(kmToMiles(1.609344)).toBeCloseTo(1, 9))
  it('round-trips a five mile walk without drift', () => expect(kmToMiles(milesToKm(5))).toBeCloseTo(5, 9))
  it('turns a three mile request into metres', () => expect(kmToMetres(milesToKm(3))).toBeCloseTo(4828.032, 3))
})

describe('time to distance', () => {
  it('estimates an hour at five kilometres', () => expect(minutesToMetres(60)).toBe(5000))
  it('scales below the hour', () => expect(minutesToMetres(30)).toBe(2500))
  it('estimates from a stated speed when one is given', () => expect(minutesToMetres(60, 4)).toBe(4000))
  it('uses the walker’s own pace when one is given', () => expect(metresForPace(60, 15)).toBe(4000))
  it('starts from five kilometres an hour', () => expect(ESTIMATED_WALKING_SPEED_KMH).toBe(5))
})

describe('target selection', () => {
  it('takes the distance straight in distance mode', () =>
    expect(targetMetresFor({ mode: 'distance', distanceKm: 4 })).toBe(4000))
  it('estimates a distance in time mode', () =>
    expect(targetMetresFor({ mode: 'time', durationMinutes: 90 })).toBe(7500))
  it('uses a personal pace for time-mode loop length', () =>
    expect(targetMetresFor({ mode: 'time', durationMinutes: 90, walkingPaceMinutesPerKm: 15 })).toBe(6000))
  it('reports the requested seconds only in time mode', () => {
    expect(targetSecondsFor({ mode: 'time', durationMinutes: 45 })).toBe(2700)
    expect(targetSecondsFor({ mode: 'distance' })).toBeUndefined()
  })
})
