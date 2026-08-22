/**
 * Deterministic randomness.
 *
 * The same start point, the same distance and the same `variation` must give
 * the same candidate ring every time: a walker who reloads the page should be
 * offered the walks they were looking at, not a fresh shuffle. Bumping
 * `variation` is the one thing that moves the seed, which is how "show me
 * different loops" works.
 */

/** FNV-1a, 32 bit. Small, stable, and dependency-free. */
export function hashString(value: string): number {
  let hash = 0x811c9dc5
  for (let i = 0; i < value.length; i++) {
    hash ^= value.charCodeAt(i)
    hash = Math.imul(hash, 0x01000193)
  }
  return hash >>> 0
}

/** Mulberry32: one 32-bit word of state, uniform enough for placing waypoints. */
export function mulberry32(seed: number): () => number {
  let state = seed >>> 0
  return () => {
    state = (state + 0x6d2b79f5) >>> 0
    let t = state
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

/**
 * The start point is rounded to about 11 m before it reaches the seed, so
 * standing still and re-asking does not reshuffle the results just because GPS
 * drifted a few metres.
 */
export function seedFor(start: [number, number], targetMetres: number, variation: number): number {
  return hashString(`${start[0].toFixed(4)}|${start[1].toFixed(4)}|${Math.round(targetMetres)}|${Math.trunc(variation)}`)
}
