/**
 * Keeping the candidates worth keeping.
 *
 * The weighted score is one opinion about how a walk's virtues trade against
 * each other: a third overlap, a quarter length, a fifth shape. It is a
 * reasonable opinion and it is also a single number, which means a walk that
 * is the best-shaped loop in the batch can be beaten by one that is slightly
 * closer to the requested distance, and never be offered — even though no
 * walker asked for those two things to be traded at that rate.
 *
 * A Pareto front does not trade them at all. A candidate stays if nothing else
 * in the batch is at least as good as it on *every* count and better on one.
 * That keeps the extremes — the tidiest shape, the closest length, the walk
 * with no repeated ground — and throws away only what is beaten outright.
 *
 * The weighted score still decides the ranking afterwards. This decides what
 * the ranking gets to rank.
 */

/** Every dimension is a cost: lower is better, and zero is perfect. */
export type Objectives = {
  /** How far off the requested distance or duration, as a fraction. */
  targetError: number
  /** Share of the walk spent on ground it already covered. */
  repeatedFraction: number
  /** How far from enclosing a proper loop, as `1 - compactness`. */
  shapePenalty: number
  /** Spread between the longest and shortest leg, as a share of the walk. */
  legImbalance: number
  /** How fiddly the walk is to follow. */
  manoeuvrePenalty: number
}

export const OBJECTIVE_NAMES = [
  'targetError',
  'repeatedFraction',
  'shapePenalty',
  'legImbalance',
  'manoeuvrePenalty',
] as const

/**
 * Differences below this are not differences.
 *
 * Two candidates whose distance error differs in the fourth decimal place have
 * not made a trade-off; they have made the same walk twice. Without a
 * tolerance, floating-point noise on five dimensions keeps almost every
 * candidate on the front, and a front that keeps everything is not a filter.
 */
export const OBJECTIVE_EPSILON = 0.005

/**
 * True when `a` is at least as good as `b` everywhere and genuinely better
 * somewhere. Ties in every dimension are not domination in either direction —
 * which is what keeps two equally good candidates both alive, and what the
 * tie-break below then has to settle.
 */
export function dominates(a: Objectives, b: Objectives, epsilon = OBJECTIVE_EPSILON): boolean {
  let strictlyBetter = false
  for (const name of OBJECTIVE_NAMES) {
    if (a[name] > b[name] + epsilon) return false
    if (a[name] < b[name] - epsilon) strictlyBetter = true
  }
  return strictlyBetter
}

export type ArchiveOptions<T> = {
  /** Most this may hold. The lowest-ranked survivors are dropped first. */
  limit: number
  objectives: (item: T) => Objectives
  /**
   * Higher is better. Used only to decide which of two candidates neither of
   * which dominates the other gets dropped when the archive is full.
   */
  rank: (item: T) => number
}

/**
 * The non-dominated candidates, bounded and deterministic.
 *
 * Input order decides nothing: the front is computed from the whole set, and
 * where the archive has to be trimmed the survivors are chosen by rank with
 * the input position as the final tie-break, so the same batch always produces
 * the same archive whatever order the candidates finished in.
 */
export function paretoArchive<T>(items: T[], options: ArchiveOptions<T>): T[] {
  if (items.length <= 1) return [...items]
  const scored = items.map((item, position) => ({ item, position, objectives: options.objectives(item) }))

  const front = scored.filter(candidate =>
    !scored.some(other => other !== candidate && dominates(other.objectives, candidate.objectives)))

  if (front.length <= options.limit) {
    // Back into the order they arrived in: the archive is a filter, not a
    // ranking, and re-sorting here would quietly override the caller's own.
    return front.sort((a, b) => a.position - b.position).map(entry => entry.item)
  }

  return front
    .sort((a, b) => options.rank(b.item) - options.rank(a.item) || a.position - b.position)
    .slice(0, options.limit)
    .sort((a, b) => a.position - b.position)
    .map(entry => entry.item)
}
