import { describe, expect, it } from 'vitest'
import {
  DEFAULT_REPAIR_BUDGET,
  RepairBudget,
  repairPlanFor,
  type RepairBudgetLimits,
} from '../src/loops/repair.js'
import { DEFAULT_QUALITY_THRESHOLDS, type QualityReport } from '../src/loops/quality.js'

/** A report of a candidate that failed exactly the reasons given, by the amounts given. */
const report = (rejections: string[], overrides: Partial<QualityReport> = {}): QualityReport => ({
  pass: rejections.length === 0,
  rejections,
  quality: { score: 60, repeatedMeters: 0, repeatedPercent: 0, uTurnCount: 0, compactness: 0.4 },
  distanceErrorFraction: 0,
  durationErrorFraction: undefined,
  distanceMeters: 5000,
  targetMetres: 5000,
  durationSeconds: 3600,
  targetSeconds: undefined,
  boundingBoxRatio: 2,
  legShares: [0.25, 0.25, 0.25, 0.25],
  startStubMetres: 0,
  longestReverseRunMetres: 0,
  durationOnly: false,
  distanceOnly: false,
  overlapSource: 'edges',
  passesEssentials: true,
  ...overrides,
})

describe('deciding whether a candidate is worth repairing', () => {
  it('leaves a candidate that already passed alone', () => {
    expect(repairPlanFor(report([]), { cornerCount: 3 })).toBeUndefined()
  })

  it('will not touch a candidate that failed more than one thing', () => {
    const failing = report(['distance', 'shapeless'], { distanceErrorFraction: 0.13 })
    expect(repairPlanFor(failing, { cornerCount: 3 })).toBeUndefined()
  })

  it('repairs a length that missed narrowly', () => {
    const failing = report(['distance'], { distanceErrorFraction: 0.15, distanceMeters: 5750 })
    const plan = repairPlanFor(failing, { cornerCount: 3 })!
    expect(plan.strategy).toBe('rescale')
    // It came back long, so the next attempt aims shorter.
    expect(plan.targetScale).toBeLessThan(1)
  })

  it('aims longer when the walk came back short', () => {
    const failing = report(['distance'], { distanceErrorFraction: 0.15, distanceMeters: 4250 })
    expect(repairPlanFor(failing, { cornerCount: 3 })!.targetScale).toBeGreaterThan(1)
  })

  it('will not repair a length that missed by a mile', () => {
    const failing = report(['distance'], { distanceErrorFraction: 0.9, distanceMeters: 9500 })
    expect(repairPlanFor(failing, { cornerCount: 3 })).toBeUndefined()
  })

  it('gives a walk with no shape another corner rather than another guess', () => {
    const failing = report(['shapeless'], {
      quality: { score: 55, repeatedMeters: 0, repeatedPercent: 0, uTurnCount: 0, compactness: 0.18 },
    })
    const plan = repairPlanFor(failing, { cornerCount: 2 })!
    expect(plan.strategy).toBe('swing-corner')
    expect(plan.cornerCount).toBe(3)
  })

  it('will not try to give shape to a scribble', () => {
    const failing = report(['shapeless'], {
      quality: { score: 20, repeatedMeters: 0, repeatedPercent: 0, uTurnCount: 0, compactness: 0.02 },
    })
    expect(repairPlanFor(failing, { cornerCount: 2 })).toBeUndefined()
  })

  it('hands the repeated stretch back as ground to avoid', () => {
    const failing = report(['repeated-corridor'], {
      quality: { score: 50, repeatedMeters: 800, repeatedPercent: 16, uTurnCount: 0, compactness: 0.4 },
    })
    const plan = repairPlanFor(failing, { cornerCount: 3 })!
    expect(plan.strategy).toBe('avoid-repeat')
    expect(plan.avoidRepeatedSection).toBe(true)
  })

  it('will not try to avoid ground that is most of the walk', () => {
    const failing = report(['repeated-corridor'], {
      quality: { score: 20, repeatedMeters: 3000, repeatedPercent: 60, uTurnCount: 0, compactness: 0.1 },
    })
    expect(repairPlanFor(failing, { cornerCount: 3 })).toBeUndefined()
  })

  it('sets off in a different direction when the walk doubled back at the door', () => {
    const failing = report(['start-spur'], { startStubMetres: 220 })
    const plan = repairPlanFor(failing, { cornerCount: 3 })!
    expect(plan.strategy).toBe('restart-bearing')
    expect(plan.bearingShift).toBeGreaterThan(0)
  })

  it('does not pretend a walk that never came home is nearly right', () => {
    expect(repairPlanFor(report(['open-ended']), { cornerCount: 3 })).toBeUndefined()
    expect(repairPlanFor(report(['u-turns']), { cornerCount: 3 })).toBeUndefined()
  })

  it('respects a threshold the walker moved rather than the shipped one', () => {
    const failing = report(['distance'], { distanceErrorFraction: 0.4, distanceMeters: 7000 })
    expect(repairPlanFor(failing, { cornerCount: 3 })).toBeUndefined()
    const plan = repairPlanFor(failing, { cornerCount: 3, thresholds: { maxDistanceError: 0.35 } })
    expect(plan?.strategy).toBe('rescale')
  })

  it('never asks for a wilder re-aim than a re-aim', () => {
    for (const distanceMeters of [500, 1000, 20000, 40000]) {
      const failing = report(['distance'], { distanceErrorFraction: 0.001, distanceMeters })
      const plan = repairPlanFor(failing, { cornerCount: 3, thresholds: { maxDistanceError: 1 } })!
      expect(plan.targetScale).toBeGreaterThanOrEqual(0.7)
      expect(plan.targetScale).toBeLessThanOrEqual(1.35)
    }
  })

  it('uses the gates the request is actually being judged against', () => {
    const failing = report(['leg-too-long'], { legShares: [0.1, 0.5, 0.2, 0.2] })
    expect(repairPlanFor(failing, { cornerCount: 3 })!.strategy).toBe('rebalance-legs')
    const wayOut = report(['leg-too-long'], { legShares: [0.05, 0.85, 0.05, 0.05] })
    expect(repairPlanFor(wayOut, { cornerCount: 3 })).toBeUndefined()
  })
})

describe('what a request may spend on repairs', () => {
  const budget = (limits: Partial<RepairBudgetLimits> = {}) =>
    new RepairBudget({ ...DEFAULT_REPAIR_BUDGET, ...limits })

  it('allows one attempt per candidate and no more', () => {
    const purse = budget()
    expect(purse.mayAttempt('a')).toBe(true)
    purse.beginAttempt('a')
    expect(purse.mayAttempt('a')).toBe(false)
    expect(purse.mayAttempt('b')).toBe(true)
  })

  it('stops the whole request once enough repairs have been tried', () => {
    const purse = budget({ attemptsPerRequest: 2 })
    for (const candidate of ['a', 'b']) {
      expect(purse.mayAttempt(candidate)).toBe(true)
      purse.beginAttempt(candidate)
    }
    expect(purse.mayAttempt('c')).toBe(false)
    expect(purse.attemptCount).toBe(2)
  })

  it('runs out of calls before it runs out of good intentions', () => {
    const purse = budget({ callsPerRequest: 3 })
    expect([purse.spendCall(), purse.spendCall(), purse.spendCall()]).toEqual([true, true, true])
    expect(purse.spendCall()).toBe(false)
    expect(purse.spent).toBe(3)
  })

  it('refuses a new attempt once the calls are gone, whatever the attempt count says', () => {
    const purse = budget({ callsPerRequest: 2, attemptsPerRequest: 100 })
    purse.spendCall()
    purse.spendCall()
    expect(purse.mayAttempt('fresh')).toBe(false)
  })

  it('ships with a bounded budget', () => {
    expect(DEFAULT_REPAIR_BUDGET.attemptsPerCandidate).toBe(1)
    expect(DEFAULT_REPAIR_BUDGET.callsPerRequest).toBeGreaterThan(0)
    expect(DEFAULT_REPAIR_BUDGET.attemptsPerRequest).toBeGreaterThan(0)
    expect(DEFAULT_QUALITY_THRESHOLDS.maxDistanceError).toBeGreaterThan(0)
  })
})
