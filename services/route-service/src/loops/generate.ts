import { randomUUID } from 'node:crypto'
import type { LineString } from 'geojson'
import { DEFAULT_CANDIDATE_COUNT, generateCandidateShapes } from './candidates.js'
import { MAX_SHARED_FRACTION, initialBearing, labelRoutes, selectDiverseRoutes } from './diversity.js'
import type { LngLat } from './geo.js'
import { analyseRouteQuality, type QualityReport, type QualityThresholds } from './quality.js'
import { LEG_BUDGET_SHARE, routeCandidateSequentially, type LegRouter, type RoutedCandidate } from './routing.js'
import { seedFor } from './random.js'
import { targetMetresFor, targetSecondsFor, type LoopMode } from './units.js'

/**
 * The loop generator, end to end.
 *
 * Shapes are proposed, routed leg by leg with the ground already walked held
 * against them, measured, and then either offered or thrown away. Nothing is
 * offered to fill a gap: three good loops, or two, or one, or an honest nothing.
 */

export const NO_CLEAN_LOOP_WARNING =
  'We couldn’t find a clean loop of that length from here. Try a different distance or move the start point.'

/**
 * Shown when the only walks of the right length double back on themselves.
 * Some places have no circuit at all at a given distance — one road up a
 * valley, a headland, a village of cul-de-sacs — and a walk that returns the
 * way it came is a better answer than no walk, as long as nobody is misled
 * about what they are getting.
 */
export const RETRACES_WARNING =
  'There’s no clean loop of that length from here, so these walks retrace part of the way back.'

export type LoopRequest = {
  start: { lng: number; lat: number }
  mode: LoopMode
  distanceKm?: number
  durationMinutes?: number
  units: 'km' | 'mi'
  variation?: number
  overrides?: LoopOverrides
}

/**
 * Every quality, diversity and routing knob this generator tunes with,
 * gathered so the tuning panel can send whichever ones a walker is
 * experimenting with. Absent fields keep today's defaults. Never sent by
 * the ordinary "Find my loops" flow.
 */
export type LoopOverrides = {
  quality?: Partial<QualityThresholds>
  /** See MAX_SHARED_FRACTION in diversity.ts. */
  maxSharedFraction?: number
  /** See JOIN_TURN_THRESHOLD_DEGREES in routing.ts. */
  joinTurnThresholdDegrees?: number
  /** See WAYPOINT_PULLBACK_SCALE in routing.ts. */
  waypointPullbackScale?: number
  candidateCount?: number
}

export type LoopStep = {
  instruction: string
  distanceMeters: number
  durationSeconds: number
  maneuver?: string
  /** Extras the walk screen uses; harmless to ignore. */
  road?: string
  startIndex?: number
  endIndex?: number
}

export type LoopRoute = {
  id: string
  label: string
  distanceMeters: number
  durationSeconds: number
  targetDifferencePercent: number
  geometry: LineString
  steps: LoopStep[]
  quality: {
    score: number
    repeatedMeters: number
    repeatedPercent: number
    uTurnCount: number
    compactness: number
  }
}

export type LoopResponse = { routes: LoopRoute[]; warning?: string; diagnostics?: Diagnostics }

export type GenerateOptions = {
  route: LegRouter
  candidateCount?: number
  concurrency?: number
  signal?: AbortSignal
  /** Reported back to the caller for logging; never sent to a browser. */
  onDiagnostics?: (diagnostics: Diagnostics) => void
}

export type Diagnostics = {
  candidates: number
  routed: number
  passed: number
  offered: number
  rejections: Record<string, number>
  /** Which of the two allowed single retries was used, if any. */
  retry: Retry
  /** True when nothing clean existed and the walks offered double back. */
  retracing: boolean
  targetMetres: number
}

export type Retry = 'none' | 'duration' | 'radius' 

type Analysed = {
  candidate: RoutedCandidate
  report: QualityReport
  coordinates: LngLat[]
  quality: QualityReport['quality']
  bearing: number
}

export async function generateLoops(request: LoopRequest, options: GenerateOptions): Promise<LoopResponse> {
  const start: LngLat = [request.start.lng, request.start.lat]
  const variation = request.variation ?? 0
  const targetSeconds = targetSecondsFor(request)
  const firstTarget = targetMetresFor(request)
  const overrides = request.overrides
  const candidateCount = overrides?.candidateCount ?? options.candidateCount ?? DEFAULT_CANDIDATE_COUNT

  const rejections: Record<string, number> = {}
  const first = await attempt(firstTarget, 1)

  let passing = first.passing
  let extra: Analysed[] = []
  let retry: Retry = 'none'
  let targetMetres = firstTarget

  // One adjusted retry, and one only: a walker waiting for loops is not waiting
  // for a search. Which adjustment depends on what the first pass got wrong.
  if (passing.length < 3) {
    const durationMisses = targetSeconds ? first.analysed.filter(entry => entry.report.durationOnly) : []

    if (request.mode === 'time' && targetSeconds && durationMisses.length) {
      // Clean loops that took the wrong amount of time: the 5 km/h estimate was
      // wrong for this terrain, so re-aim the distance from what was measured.
      const observed = median(durationMisses.map(entry => entry.candidate.durationSeconds))
      targetMetres = firstTarget * clampScale(targetSeconds / observed)
      const second = await attempt(targetMetres, 1)
      retry = 'duration'
      extra = second.analysed
      passing = merge(passing, second.passing)
    } else if (first.analysed.length) {
      // The ring was the wrong size for these streets. How much a network
      // stretches a crow-flies ring varies enormously — a suburb of 80 m blocks
      // costs far more per metre of radius than an open seafront — so measure
      // it from what came back and resize once. A ring that is badly sized
      // fails in several ways at once, not only on length, so the estimate
      // comes from every candidate that routed rather than the near misses.
      const observed = median(first.analysed.map(entry => entry.candidate.distanceMeters))
      const scale = clampScale(firstTarget / observed)
      if (Math.abs(scale - 1) > 0.05) {
        const second = await attempt(firstTarget, scale)
        retry = 'radius'
        extra = second.analysed
        passing = merge(passing, second.passing)
      }
    }
  }

  // Clean loops first. Only if there are none at all does Looper fall back to
  // walks of the right length that double back — never as a top-up alongside a
  // clean loop, which would quietly mix two different kinds of answer.
  const analysed = merge(first.analysed, extra)
  const retracing = passing.length === 0
  const offerable = retracing ? analysed.filter(entry => entry.report.passesEssentials) : passing

  const chosen = selectDiverseRoutes(offerable.map(toSelectable), 3, overrides?.maxSharedFraction ?? MAX_SHARED_FRACTION)
  const labels = labelRoutes(chosen.map(entry => ({ bearing: entry.bearing, distanceMeters: entry.source.candidate.distanceMeters })))

  const diagnostics: Diagnostics = {
    candidates: candidateCount,
    routed: first.analysed.length,
    passed: passing.length,
    offered: chosen.length,
    rejections,
    retry,
    targetMetres,
    retracing: retracing && chosen.length > 0,
  }
  options.onDiagnostics?.(diagnostics)

  if (!chosen.length) return { routes: [], warning: NO_CLEAN_LOOP_WARNING, diagnostics }

  return {
    warning: retracing ? RETRACES_WARNING : undefined,
    diagnostics,
    routes: chosen.map((entry, position) => {
      const { candidate, quality } = entry.source
      return {
        id: randomUUID(),
        label: labels[position],
        distanceMeters: Math.round(candidate.distanceMeters),
        durationSeconds: Math.round(candidate.durationSeconds),
        targetDifferencePercent: Math.round((candidate.distanceMeters / targetMetres - 1) * 100),
        geometry: { type: 'LineString', coordinates: candidate.coordinates } as LineString,
        steps: candidate.steps.map(step => ({
          instruction: step.instruction,
          distanceMeters: Math.round(step.distanceMeters),
          durationSeconds: Math.round(step.durationSeconds),
          maneuver: step.maneuver,
          road: step.road,
          startIndex: step.startIndex,
          endIndex: step.endIndex,
        })),
        quality,
      }
    }),
  }

  async function attempt(target: number, radiusScale: number): Promise<{ analysed: Analysed[]; passing: Analysed[] }> {
    const seed = seedFor([start[0], start[1]], target, variation)
    const shapes = generateCandidateShapes(start, target, seed, candidateCount, radiusScale)
    const routed = await mapWithConcurrency(shapes, options.concurrency ?? 6, async shape => {
      const candidate = await routeCandidateSequentially(start, shape, options.route, {
        // Generous: a candidate that overshoots is still evidence about how much
        // this network stretches a ring, and that evidence steers the retry.
        abandonAboveMetres: target * 2.2,
        legBudgetMetres: target * LEG_BUDGET_SHARE,
        joinTurnThresholdDegrees: overrides?.joinTurnThresholdDegrees,
        waypointPullbackScale: overrides?.waypointPullbackScale,
        signal: options.signal,
      })
      if (!candidate) return undefined
      const report = analyseRouteQuality({
        coordinates: candidate.coordinates,
        start,
        distanceMeters: candidate.distanceMeters,
        durationSeconds: candidate.durationSeconds,
        targetMetres: target,
        targetSeconds,
        legDistances: candidate.legDistances,
        maneuverSigns: candidate.steps.map(step => step.sign),
        thresholds: overrides?.quality,
      })
      for (const reason of report.rejections) rejections[reason] = (rejections[reason] ?? 0) + 1
      return {
        candidate,
        report,
        coordinates: candidate.coordinates,
        quality: report.quality,
        bearing: initialBearing(candidate.coordinates, start),
      } satisfies Analysed
    })
    const analysed = routed.filter((entry): entry is Analysed => entry !== undefined)
    return { analysed, passing: analysed.filter(entry => entry.report.pass) }
  }
}

const toSelectable = (source: Analysed) => ({
  coordinates: source.coordinates,
  quality: { score: source.quality.score },
  bearing: source.bearing,
  source,
})

const merge = (...groups: Analysed[][]) => Array.from(new Set(groups.flat()))

/** A retry re-aims; it does not go hunting. */
const clampScale = (scale: number) => Math.min(1.5, Math.max(0.55, Number.isFinite(scale) ? scale : 1))

function median(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b)
  const middle = Math.floor(sorted.length / 2)
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
}

/**
 * Candidates are independent, but twenty-four at once is more load than a small
 * routing container should take from one walker.
 */
export async function mapWithConcurrency<T, R>(items: T[], limit: number, worker: (item: T) => Promise<R>): Promise<R[]> {
  const results = new Array<R>(items.length)
  let next = 0
  const runners = Array.from({ length: Math.max(1, Math.min(limit, items.length)) }, async () => {
    for (;;) {
      const index = next++
      if (index >= items.length) return
      results[index] = await worker(items[index])
    }
  })
  await Promise.all(runners)
  return results
}
