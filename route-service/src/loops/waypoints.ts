import { bearingBetween, compactness, destination, haversine, normaliseBearing, type LngLat } from './geo.js'

/**
 * Waypoint loops, as a length problem rather than a shape problem.
 *
 * When a walker drops pins, the walk is no longer "a ring of about five
 * kilometres from here" — it is "through these places, in this order, in about
 * five kilometres". Those are different problems. The ring generator answers
 * the first by aiming a shape and measuring what comes back; asking it to also
 * pass through three fixed points turns almost every attempt into a
 * near-miss, which is why waypoint mode misses the requested distance by four
 * times what standard mode does.
 *
 * The structure the problem actually has:
 *
 *   anchors   a0 = start, a1 … am = the walker's pins, a(m+1) = start
 *   backbone  B = Σ shortest(ai, a(i+1))          — the walk you cannot avoid
 *   slack     Δ = K - B                            — what there is to spend
 *
 * `B` is a floor: no walk through those pins in that order is shorter. If
 * Δ is negative the request is impossible and should be refused, honestly and
 * immediately. If it is positive, the question is *where to spend it* — and
 * spending it evenly across the gaps produces a rounder walk than spending it
 * all in one place, which is what a single global shaping point does.
 *
 * So each gap gets a few alternatives of different lengths, and a small
 * dynamic programme picks one per gap to add up to the walk that was asked
 * for. Nothing in here moves a pin or reorders one: the anchors are the
 * problem statement, not part of the search.
 */

export type Anchor = LngLat

/** One way of getting from one anchor to the next. */
export type SegmentOption = {
  /** Which anchor gap this crosses. */
  gap: number
  /** Stable within a gap, so a chosen combination can be named and compared. */
  id: string
  /** Invisible shaping points between the two anchors. Never a walker's pin. */
  guides: LngLat[]
  distanceMeters: number
  durationSeconds: number
}

/**
 * Where to put a shaping point so a gap comes out a given length longer.
 *
 * Treating the detour as an isoceles triangle over the gap: to walk `extra`
 * further than the straight line `L`, step out perpendicular from the middle
 * by `sqrt(((L + extra) / 2)² - (L / 2)²)`. That is a crow-flight answer to a
 * crow-flight question, and the network will not honour it exactly — which is
 * why the routed length of every option is measured rather than assumed, and
 * why the allocation below works from those measurements.
 */
export function guideForDetour(from: Anchor, to: Anchor, extraMetres: number, side: 1 | -1): LngLat {
  const straight = haversine(from, to)
  const wanted = straight + Math.max(0, extraMetres)
  const offset = Math.sqrt(Math.max(0, (wanted / 2) ** 2 - (straight / 2) ** 2))
  const midpoint = destination(from, straight / 2, bearingBetween(from, to))
  return destination(midpoint, Math.max(25, offset), normaliseBearing(bearingBetween(from, to) + 90 * side))
}

/**
 * The detour sizes each gap is offered, as shares of the slack available to
 * it. Zero is always among them: the shortest way between two anchors has to
 * stay on the table, or a walk with no room to spare has nothing to choose.
 */
export const DETOUR_SHARES = [0, 0.35, 0.7, 1.2, 2] as const

/**
 * Plan the shaping points for one gap. Pure — it decides what to ask the
 * engine for, and asks it for nothing.
 */
export function planSegmentOptions(
  gap: number,
  from: Anchor,
  to: Anchor,
  slackForGap: number,
  /**
   * How much further the network made the direct route than the crow flies
   * across this gap. A detour asked for in crow-flight metres comes back that
   * much longer, so the shaping point is placed for the detour we want *after*
   * the network has had its way with it — otherwise every option overshoots by
   * the local stretch and the whole set lands past the plan.
   */
  networkStretch = 1,
): Array<{ id: string; guides: LngLat[] }> {
  const planned: Array<{ id: string; guides: LngLat[] }> = [{ id: `${gap}-direct`, guides: [] }]
  if (slackForGap <= 0) return planned
  const stretch = Number.isFinite(networkStretch) ? Math.min(3, Math.max(0.8, networkStretch)) : 1
  for (const share of DETOUR_SHARES) {
    if (share <= 0) continue
    for (const side of [1, -1] as const) {
      planned.push({
        id: `${gap}-${share}-${side > 0 ? 'l' : 'r'}`,
        guides: [guideForDetour(from, to, (slackForGap * share) / stretch, side)],
      })
    }
  }
  return planned
}

export type AllocationOptions = {
  /** Distance or duration the whole walk is aiming at. */
  target: number
  /** Resolution of the dynamic programme, in the same unit as `target`. */
  bucketMetres: number
  /** Most buckets the table may have. Bounds the work, whatever is asked for. */
  maxBuckets: number
  /** Distinct combinations kept per state, which is what makes several answers possible. */
  keepPerState: number
  /** How many finished combinations to return. */
  limit: number
  /**
   * How far off the target a combination may be and still be picked for
   * variety's sake, as a share of the target.
   *
   * Variety is worth something and it is not worth the walker's distance:
   * spreading across every combination the table produced offers a walk that
   * spends its slack somewhere interesting and comes back a mile long. So the
   * spread happens among the combinations that are the right length, and only
   * falls outside that band when there are not enough of them.
   */
  spreadWithinError: number
  /**
   * How much ground a combination's plan must enclose before it is worth
   * routing. Measured on the anchors and shaping points, so it is free.
   *
   * Below the finished walk's own compactness gate, because routing adds
   * wiggle and therefore only ever lowers it: this is meant to catch the plans
   * that enclose nothing at all, not to pre-judge the ones that are merely
   * unremarkable.
   */
  minShape: 0.25,
}

export const DEFAULT_ALLOCATION: AllocationOptions = {
  target: 0,
  bucketMetres: 100,
  maxBuckets: 96,
  keepPerState: 3,
  limit: 6,
  spreadWithinError: 0.1,
  minShape: 0.25,
}

export type Allocation = {
  /** One option per gap, in gap order. */
  chosen: SegmentOption[]
  total: number
  /** How far off the target, in the target's own unit. */
  error: number
  /**
   * How lopsided the spending was: the largest share of the total detour that
   * landed in any one gap. All the slack in one gap is a walk with a balloon
   * on the side of it, however exactly it hits the distance.
   */
  concentration: number
  /**
   * How much ground the combination encloses, against a circle of the same
   * perimeter — measured on the anchors and shaping points alone, before
   * anything is routed.
   *
   * This is what stops the allocation assembling a walk that is exactly the
   * right length and shaped like a closed pair of scissors. With one pin the
   * gaps out and back can bulge to the same side, and the result reads as a
   * there-and-back to every shape gate the finished walk is judged by:
   * measured on real ground, `shapeless` killed 18 of 24 assembled walks and
   * `u-turns` another 14. Length was never the problem.
   */
  shape: number
}

/**
 * The crow-flight ring a combination describes: the anchors in order, with
 * each gap's shaping points threaded between them.
 *
 * Deliberately geometric and unrouted. It is not what the walk will look like
 * — the network decides that — but a combination whose *plan* encloses nothing
 * will not produce a walk that encloses something, and finding that out here
 * costs nothing rather than costing a routed leg.
 */
export function ringOf(anchors: Anchor[], chosen: SegmentOption[]): LngLat[] {
  const ring: LngLat[] = [anchors[0]]
  for (let gap = 0; gap < chosen.length; gap++) {
    ring.push(...chosen[gap].guides, anchors[gap + 1] ?? anchors[0])
  }
  return ring
}

export const ringShapeOf = (anchors: Anchor[], chosen: SegmentOption[]): number => compactness(ringOf(anchors, chosen))

/**
 * Choose one option per gap so the whole walk comes out near the target.
 *
 * A bucketed dynamic programme rather than an exhaustive search, so the cost
 * is bounded by the table rather than by the number of gaps: five gaps with
 * nine options each is fifty-nine thousand combinations, and the table is a
 * few hundred entries whatever the gap count.
 *
 * Several answers, not one: three walks that all spend their slack the same
 * way are one walk. Keeping a few distinct combinations per state is what lets
 * the diversity selector afterwards have something to select between.
 *
 * Deterministic throughout — states are visited in order, ties are broken by
 * a stated rule, and the returned list is sorted.
 */
export function allocateSlack(
  byGap: SegmentOption[][],
  options: Partial<AllocationOptions> & { target: number; anchors?: Anchor[] },
): Allocation[] {
  const settings: AllocationOptions = { ...DEFAULT_ALLOCATION, ...options }
  const anchors = options.anchors
  if (!byGap.length || byGap.some(gap => !gap.length)) return []

  const bucketOf = (value: number) => Math.min(settings.maxBuckets - 1, Math.max(0, Math.round(value / settings.bucketMetres)))
  type Partial_ = { chosen: SegmentOption[]; total: number }
  let states = new Map<number, Partial_[]>([[0, [{ chosen: [], total: 0 }]]])

  for (const gap of byGap) {
    const next = new Map<number, Partial_[]>()
    // Options in a stable order, so the table is filled the same way every run.
    const ordered = [...gap].sort((a, b) => a.distanceMeters - b.distanceMeters || (a.id < b.id ? -1 : 1))
    for (const bucket of [...states.keys()].sort((a, b) => a - b)) {
      for (const partial of states.get(bucket)!) {
        for (const option of ordered) {
          const total = partial.total + option.distanceMeters
          // Anything already this far over cannot come back under it, and a
          // walk twice as long as the plan is not a walk the plan describes.
          if (total > settings.target * 2) continue
          const key = bucketOf(total)
          const bag = next.get(key) ?? []
          if (bag.length >= settings.keepPerState) {
            // Keep the ones closest to the target within this bucket; the
            // bucket is a coarse grouping, not a claim they are equal.
            const worst = bag.reduce((far, entry, index) =>
              Math.abs(entry.total - settings.target) > Math.abs(bag[far].total - settings.target) ? index : far, 0)
            if (Math.abs(total - settings.target) >= Math.abs(bag[worst].total - settings.target)) continue
            bag[worst] = { chosen: [...partial.chosen, option], total }
          } else {
            bag.push({ chosen: [...partial.chosen, option], total })
          }
          next.set(key, bag)
        }
      }
    }
    states = next
    if (!states.size) return []
  }

  const finished: Allocation[] = []
  for (const bucket of [...states.keys()].sort((a, b) => a - b)) {
    for (const partial of states.get(bucket)!) {
      finished.push({
        chosen: partial.chosen,
        total: partial.total,
        error: Math.abs(partial.total - settings.target),
        concentration: concentrationOf(partial.chosen, byGap),
        shape: anchors ? ringShapeOf(anchors, partial.chosen) : 0,
      })
    }
  }

  const ranked = finished
    .sort((a, b) =>
      a.error - b.error
      || a.concentration - b.concentration
      // Last resort, so the order never depends on how the table was walked.
      || combinationKey(a).localeCompare(combinationKey(b)))
    .filter(deduplicated())

  const band = settings.target * settings.spreadWithinError
  const rightLength = ranked.filter(allocation => allocation.error <= band)
  // Shape is a bar to clear, not a ranking. Ordering by it hands the diversity
  // selector twenty-four variations on one well-shaped walk; using it as a
  // floor keeps the variety and throws out only the combinations whose plan
  // encloses nothing — the ones that were going to fail `shapeless` anyway.
  // Any combination that encloses ground is preferred over every one that
  // does not — asking for some minimum number of them first is how the filter
  // ends up never applying, because there are rarely two dozen of them. The
  // ones that enclose nothing are not discarded: they are appended below, so
  // a pin down a single lane still gets the honest there-and-back rather than
  // nothing at all.
  const wellShaped = rightLength.filter(allocation => allocation.shape >= settings.minShape)
  const spread = spreadAllocations(wellShaped.length ? wellShaped : rightLength, settings.limit)
  if (spread.length >= settings.limit) return spread
  // Not enough walks of the right length to choose between. The rest are
  // offered in plain order of how close they came, and the quality gates
  // downstream will refuse the ones that are simply wrong.
  const already = new Set(spread.map(combinationKey))
  return [...spread, ...ranked.filter(allocation => !already.has(combinationKey(allocation)))].slice(0, settings.limit)
}

/**
 * Pick allocations that spend their slack in genuinely different places.
 *
 * The table's best twelve answers are usually the same walk twelve times: the
 * same choice in every gap but one, differing by a hundred metres nobody would
 * notice. Sorting by target error alone therefore hands the diversity selector
 * a set it has to throw most of away, and the walker ends up with one choice.
 *
 * So after the closest answer, each further one is whichever remaining answer
 * differs in the most gaps from everything picked so far — a walk that spends
 * its slack in the second gap instead of the third really is a different walk.
 * Error breaks ties, so a spread-out answer never beats a close one that is
 * equally different.
 */
export function spreadAllocations(ranked: Allocation[], limit: number): Allocation[] {
  if (ranked.length <= 1) return ranked.slice(0, limit)
  const chosen: Allocation[] = [ranked[0]]
  const remaining = ranked.slice(1)

  while (chosen.length < limit && remaining.length) {
    let bestIndex = 0
    let bestDistance = -1
    for (let index = 0; index < remaining.length; index++) {
      const distance = Math.min(...chosen.map(picked => gapsDifferingBetween(picked, remaining[index])))
      if (distance > bestDistance) {
        bestDistance = distance
        bestIndex = index
      }
    }
    chosen.push(remaining[bestIndex])
    remaining.splice(bestIndex, 1)
  }
  return chosen
}

/** How many gaps two allocations made a different choice in. */
export function gapsDifferingBetween(a: Allocation, b: Allocation): number {
  let differing = 0
  for (let gap = 0; gap < Math.max(a.chosen.length, b.chosen.length); gap++) {
    if (a.chosen[gap]?.id !== b.chosen[gap]?.id) differing++
  }
  return differing
}

const combinationKey = (allocation: Allocation) => allocation.chosen.map(option => option.id).join('|')

function deduplicated() {
  const seen = new Set<string>()
  return (allocation: Allocation) => {
    const key = combinationKey(allocation)
    if (seen.has(key)) return false
    seen.add(key)
    return true
  }
}

/**
 * The largest share of the walk's total detour spent in any one gap. Zero
 * gaps of detour, or none at all, is perfectly even rather than undefined.
 */
function concentrationOf(chosen: SegmentOption[], byGap: SegmentOption[][]): number {
  const detours = chosen.map((option, gap) => {
    const shortest = Math.min(...byGap[gap].map(candidate => candidate.distanceMeters))
    return Math.max(0, option.distanceMeters - shortest)
  })
  const total = detours.reduce((sum, detour) => sum + detour, 0)
  if (total <= 0) return 0
  return Math.max(...detours) / total
}

/**
 * Whether a walk through these anchors can fit in the plan at all.
 *
 * `backbone` must be a genuine lower bound on the ordinary walking distance —
 * see docs/routing-baseline.md §7 on why the profile's own preferred route is
 * not one. The tolerance is for snapping and measurement, not for optimism:
 * refusing a walk that is actually possible is the failure that costs a
 * walker their walk, so the doubt goes their way.
 */
export const FEASIBILITY_TOLERANCE = 0.05

export function fitsInPlan(backbone: number, target: number, maxErrorFraction: number, tolerance = FEASIBILITY_TOLERANCE): boolean {
  if (!(target > 0)) return false
  return backbone <= target * (1 + maxErrorFraction) * (1 + tolerance)
}
