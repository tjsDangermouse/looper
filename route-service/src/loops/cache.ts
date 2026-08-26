import type { LoopRequest, LoopResponse } from './generate.js'
import { flagFingerprint, type AlgorithmFlags } from './flags.js'

/**
 * Answering the same question twice.
 *
 * Two walkers standing in the same doorstep asking for the same five
 * kilometres get the same three walks — the generator is deterministic, and
 * that is the whole reason a walker who reloads sees the walks they were
 * looking at. Which means the second one's twenty-odd routing calls buy
 * nothing at all.
 *
 * The care here is entirely in the key. A cache that returns the right walks
 * quickly is worth having; a cache that returns *somebody else's* walks is a
 * walker setting off from a street they have never been to, and there is no
 * amount of speed that pays for it. So the key carries everything that can
 * change a route — the map, the profile, the algorithm, and every field of the
 * request — and coordinates go in at full precision rather than rounded to a
 * neighbourhood.
 *
 * Only finished answers are stored. A request that timed out, was abandoned by
 * its walker, or fell over is not an answer, and two callers never share one
 * in-flight computation: a cache entry nobody can abort halfway is a cache
 * entry that cannot be corrupted halfway.
 */

/** Everything outside the request that can change what a route looks like. */
export type CacheContext = {
  /**
   * Identifies the graph the answer came from. Changing the map data must
   * change this, or a rebuilt graph serves routes over streets that moved.
   */
  graphVersion: string
  /** Which regional engine answered. */
  region: string
  profile: string
  /** Version of the custom walking model. Retune it, and old answers are wrong. */
  profileVersion: string
  flags: AlgorithmFlags
  /** Anything else that shapes generation: candidate count, concurrency, budgets. */
  generation: Record<string, unknown>
}

/**
 * The key.
 *
 * Ordered and explicit rather than a hash of the request object: field order
 * in an object literal is not a contract, and a key that silently changes when
 * somebody reorders a type is a key that silently stops matching. Waypoints
 * keep their order because their order is part of the question.
 */
export function cacheKeyFor(request: LoopRequest, context: CacheContext): string {
  const parts: string[] = [
    'v1',
    context.graphVersion,
    context.region,
    context.profile,
    context.profileVersion,
    flagFingerprint(context.flags),
    stable(context.generation),
    // Full precision. Rounding a start point is how a cache serves a walk from
    // the next street over, and eleven metres is a different front door.
    `start:${request.start.lng},${request.start.lat}`,
    `mode:${request.mode}`,
    `km:${request.distanceKm ?? ''}`,
    `min:${request.durationMinutes ?? ''}`,
    `units:${request.units}`,
    `activity:${request.activity ?? ''}`,
    `pace:${request.walkingPaceMinutesPerKm ?? ''}`,
    `var:${request.variation ?? 0}`,
    `wp:${(request.waypoints ?? []).map(point => `${point.lng},${point.lat}`).join(';')}`,
    `ex:${(request.exclude ?? []).map(route => route.map(point => point.join(',')).join(' ')).join(';')}`,
    `ov:${stable(request.overrides ?? {})}`,
  ]
  return parts.join('|')
}

/** Keys are compared as strings, so the same object must always print the same. */
function stable(value: unknown): string {
  if (value === null || typeof value !== 'object') return JSON.stringify(value) ?? 'null'
  if (Array.isArray(value)) return `[${value.map(stable).join(',')}]`
  const entries = Object.entries(value as Record<string, unknown>)
    .filter(([, item]) => item !== undefined)
    .sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0))
  return `{${entries.map(([name, item]) => `${JSON.stringify(name)}:${stable(item)}`).join(',')}}`
}

export type CacheLimits = {
  maxEntries: number
  /** How long a set of walks stays fresh. */
  ttlMs: number
  /**
   * How long a *refusal* stays fresh, which is deliberately shorter.
   *
   * "We could not find a clean loop here" is a statement about a moment as
   * much as about a place: the generator samples bearings, the engine is
   * sometimes busy, and pinning a walker's neighbourhood as hopeless for an
   * hour on one bad afternoon is a worse mistake than doing the work again.
   */
  emptyTtlMs: number
}

export const DEFAULT_CACHE_LIMITS: CacheLimits = {
  maxEntries: 500,
  ttlMs: 10 * 60 * 1000,
  emptyTtlMs: 60 * 1000,
}

type Entry = { value: LoopResponse; expiresAt: number; storedAt: number }

/**
 * A bounded, expiring store of finished answers. Least-recently-used out
 * first, so a busy town does not get evicted by a quiet one.
 */
export class RouteCache {
  private readonly entries = new Map<string, Entry>()

  constructor(
    private readonly limits: CacheLimits = DEFAULT_CACHE_LIMITS,
    private readonly now: () => number = () => Date.now(),
  ) {}

  get(key: string): { value: LoopResponse; ageMs: number } | undefined {
    const entry = this.entries.get(key)
    if (!entry) return undefined
    if (entry.expiresAt <= this.now()) {
      this.entries.delete(key)
      return undefined
    }
    // Re-inserting moves it to the end, which is what makes the Map an LRU.
    this.entries.delete(key)
    this.entries.set(key, entry)
    return { value: entry.value, ageMs: this.now() - entry.storedAt }
  }

  /**
   * Store a finished answer. Anything that is not one — a timeout, an
   * abandoned request, an engine failure — never reaches here: the caller
   * stores only what it is about to send to a walker.
   */
  set(key: string, value: LoopResponse) {
    const empty = value.routes.length === 0
    const storedAt = this.now()
    this.entries.delete(key)
    this.entries.set(key, {
      value,
      storedAt,
      expiresAt: storedAt + (empty ? this.limits.emptyTtlMs : this.limits.ttlMs),
    })
    while (this.entries.size > this.limits.maxEntries) {
      const oldest = this.entries.keys().next()
      if (oldest.done) break
      this.entries.delete(oldest.value)
    }
  }

  get size() { return this.entries.size }

  /** Drops what has already expired. Bounded work; the size cap does the rest. */
  prune() {
    const now = this.now()
    for (const [key, entry] of this.entries) if (entry.expiresAt <= now) this.entries.delete(key)
  }
}
