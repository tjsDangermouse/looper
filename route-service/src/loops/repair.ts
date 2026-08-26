import { DEFAULT_QUALITY_THRESHOLDS, type QualityReport, type QualityThresholds } from './quality.js'

/**
 * Fixing a walk that was nearly right.
 *
 * A candidate that fails one gate by a hair has usually gone wrong in one
 * identifiable way: a ring aimed slightly too far out, one corner that landed
 * somewhere awkward, a stretch doubled back on. Throwing it away and starting
 * a fresh batch of twenty-four blind guesses is both slower and no more likely
 * to work — the next batch has the same information this one did.
 *
 * So: one attempt, aimed at the specific thing that failed, and only for a
 * candidate that failed exactly one thing and failed it narrowly. A walk that
 * is the wrong length *and* retraces *and* has no shape is not nearly right;
 * it is wrong, and repairing it would be inventing a walk rather than fixing
 * one.
 *
 * Nothing here ever moves a place the walker chose. A repair adjusts the
 * generator's own invisible corners, and nothing else.
 */

export type RepairStrategy =
  /** Aim the whole ring further out or further in. */
  | 'rescale'
  /** Rebuild avoiding the stretch that was walked twice. */
  | 'avoid-repeat'
  /** Swing an extreme corner sideways to enclose more ground. */
  | 'swing-corner'
  /** Add a corner, so a long thin walk has something to bulge around. */
  | 'lateral-corner'
  /** Move the corners so no single leg is the whole walk. */
  | 'rebalance-legs'
  /** Set off in a different direction, so the doorstep stub is not walked twice. */
  | 'restart-bearing'

export type RepairPlan = {
  strategy: RepairStrategy
  /** The single gate that failed, for metrics. */
  reason: string
  /** Multiplier on the construction target. 1 means leave it alone. */
  targetScale: number
  /** Degrees to swing the starting bearing by. */
  bearingShift: number
  /** Corners to build with, or undefined to keep the count that produced the candidate. */
  cornerCount?: number
  /** True when the stretch walked twice should be handed to the builder as ground to avoid. */
  avoidRepeatedSection: boolean
}

/**
 * How far past a gate a candidate may be and still count as "nearly".
 *
 * These are proportions of the gate itself rather than absolute figures, so a
 * 12% distance gate forgives up to 12% × 0.5 = 6 percentage points past it,
 * and the same rule reads sensibly whatever the gates are tuned to. Past the
 * margin the candidate is not a near miss, and one bounded attempt is not
 * going to turn it into one.
 */
export type RepairMargins = {
  /** Fraction of the gate a candidate may exceed it by. */
  distance: number
  duration: number
  repeated: number
  /** Compactness and leg balance are floors, so the margin runs the other way. */
  compactness: number
  elongation: number
  legShare: number
  /** Absolute, in metres: a start stub this far past its limit is still a stub. */
  startStubMetres: number
}

export const DEFAULT_REPAIR_MARGINS: RepairMargins = {
  distance: 0.5,
  duration: 0.5,
  repeated: 0.6,
  compactness: 0.25,
  elongation: 0.35,
  legShare: 0.25,
  startStubMetres: 120,
}

/** Bounded, and configurable, because an unbounded repair is a second generator. */
export type RepairBudgetLimits = {
  /** Engine calls all repairs in one request may spend between them. */
  callsPerRequest: number
  /** Repairs attempted in one request, whatever they cost. */
  attemptsPerRequest: number
  /** Attempts on any single candidate. One, unless somebody proves otherwise. */
  attemptsPerCandidate: number
}

export const DEFAULT_REPAIR_BUDGET: RepairBudgetLimits = {
  callsPerRequest: 48,
  attemptsPerRequest: 4,
  attemptsPerCandidate: 1,
}

/**
 * What, if anything, is worth trying for this candidate — and nothing at all
 * for a candidate that failed more than one thing, or failed by a mile, or
 * passed already.
 *
 * Pure: it decides eligibility and does not carry it out, so the rules can be
 * tested without a routing engine anywhere near them.
 */
export function repairPlanFor(
  report: QualityReport,
  options: {
    thresholds?: Partial<QualityThresholds>
    margins?: Partial<RepairMargins>
    /** The corner count that produced this candidate, so a plan can change it. */
    cornerCount: number
    /** How much of the walk was the longest stretch walked twice. */
    longestRepeatedFraction?: number
  },
): RepairPlan | undefined {
  if (report.pass) return undefined
  if (report.rejections.length !== 1) return undefined

  const thresholds: QualityThresholds = { ...DEFAULT_QUALITY_THRESHOLDS, ...options.thresholds }
  const margins: RepairMargins = { ...DEFAULT_REPAIR_MARGINS, ...options.margins }
  const [reason] = report.rejections
  const base = { reason, targetScale: 1, bearingShift: 0, avoidRepeatedSection: false }

  switch (reason) {
    case 'distance': {
      const error = report.distanceErrorFraction
      if (error > thresholds.maxDistanceError * (1 + margins.distance)) return undefined
      // The ring came back the wrong size by a known factor; aim it by that
      // factor the other way. Overshoot and undershoot are not symmetric —
      // a network that stretches a target rarely un-stretches it — so the
      // correction is deliberately partial.
      const measured = 1 + (report.distanceMeters > report.targetMetres ? error : -error)
      return { ...base, strategy: 'rescale', targetScale: clampScale(1 / measured) }
    }
    case 'duration': {
      const error = report.durationErrorFraction ?? 0
      if (error > thresholds.maxDurationError * (1 + margins.duration)) return undefined
      const measured = 1 + (report.durationSeconds > (report.targetSeconds ?? 0) ? error : -error)
      return { ...base, strategy: 'rescale', targetScale: clampScale(1 / measured) }
    }
    case 'repeated-corridor': {
      const repeated = report.quality.repeatedPercent / 100
      if (repeated > thresholds.maxRepeatedFraction * (1 + margins.repeated)) return undefined
      return { ...base, strategy: 'avoid-repeat', avoidRepeatedSection: true }
    }
    case 'out-and-back-spur': {
      // A short backtrack is a corner that turned out to be a dead end. Give
      // the builder that ground to avoid and let it find another way round.
      if ((options.longestRepeatedFraction ?? 0) > 0.25) return undefined
      return { ...base, strategy: 'avoid-repeat', avoidRepeatedSection: true }
    }
    case 'shapeless': {
      if (report.quality.compactness < thresholds.minCompactness * (1 - margins.compactness)) return undefined
      // Not shapeless enough to be a scribble: one more corner is usually the
      // difference between threading the same blocks and going round them.
      return { ...base, strategy: 'swing-corner', cornerCount: options.cornerCount + 1, bearingShift: 25 }
    }
    case 'elongated': {
      if (report.boundingBoxRatio > thresholds.maxBoundingBoxRatio * (1 + margins.elongation)) return undefined
      return { ...base, strategy: 'lateral-corner', cornerCount: options.cornerCount + 1 }
    }
    case 'leg-too-long':
    case 'leg-too-short': {
      const worst = report.legShares.length ? Math.max(...report.legShares) : 1
      if (worst > thresholds.maxLegShare * (1 + margins.legShare)) return undefined
      return { ...base, strategy: 'rebalance-legs', cornerCount: options.cornerCount + 1 }
    }
    case 'start-spur': {
      const limit = Math.max(thresholds.maxStartStubMetres, report.distanceMeters * thresholds.startStubShare)
      if (report.startStubMetres > limit + margins.startStubMetres) return undefined
      // The stub is walked out and back because the walk left and returned the
      // same way. Setting off further round the compass is the fix.
      return { ...base, strategy: 'restart-bearing', bearingShift: 40 }
    }
    // A walk that does not return to the start, or turns round in the street,
    // has not nearly worked. There is nothing here to adjust.
    default:
      return undefined
  }
}

/** A repair re-aims; it does not go hunting. */
const clampScale = (scale: number) => Math.min(1.35, Math.max(0.7, Number.isFinite(scale) ? scale : 1))

/**
 * The engine calls one request's repairs may spend between them.
 *
 * Deliberately a plain counter rather than anything cleverer: a repair that
 * cannot tell whether it has money left will spend it, and the failure mode of
 * unbounded repair is a request that never finishes.
 */
export class RepairBudget {
  private callsSpent = 0
  private attempts = 0
  private readonly perCandidate = new Map<string, number>()

  constructor(private readonly limits: RepairBudgetLimits = DEFAULT_REPAIR_BUDGET) {}

  /** Whether another repair may start at all. Checked before any work is done. */
  mayAttempt(candidateId: string): boolean {
    if (this.attempts >= this.limits.attemptsPerRequest) return false
    if (this.callsSpent >= this.limits.callsPerRequest) return false
    return (this.perCandidate.get(candidateId) ?? 0) < this.limits.attemptsPerCandidate
  }

  beginAttempt(candidateId: string) {
    this.attempts++
    this.perCandidate.set(candidateId, (this.perCandidate.get(candidateId) ?? 0) + 1)
  }

  /** False once the money has run out, which is the repair's cue to stop. */
  spendCall(): boolean {
    if (this.callsSpent >= this.limits.callsPerRequest) return false
    this.callsSpent++
    return true
  }

  get spent() { return this.callsSpent }
  get attemptCount() { return this.attempts }
}

/** Thrown inside a repair when its budget runs out, and caught by the repair itself. */
export class RepairBudgetExhausted extends Error {
  constructor() {
    super('Repair budget exhausted.')
    this.name = 'RepairBudgetExhausted'
  }
}
