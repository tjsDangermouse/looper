// Scoring for candidate loops. ORS `round_trip` is a seeded generator: some
// seeds give a clean circuit, others send you down a cul-de-sac and back out
// again. We ask for more candidates than we need and keep the good ones.
export type Point = [number, number]
export type Metrics = { retraceFraction: number; roundness: number; distanceErrorFraction: number; sharpTurnsPerKm: number }

const EARTH = 6371000, RAD = Math.PI / 180
// Equirectangular metres about the loop's own origin. Loops are at most 20 km
// across, so the distortion is far below the 8 m grid we quantise onto.
export function project(coordinates: Point[]): Point[] {
  if (!coordinates.length) return []
  const scale = Math.cos(coordinates[0][1] * RAD)
  return coordinates.map(([lng, lat]) => [EARTH * lng * RAD * scale, EARTH * lat * RAD])
}

const GRID = 8 // metres; ORS reuses OSM nodes when doubling back, so this is generous
const cell = (p: Point) => `${Math.round(p[0] / GRID)},${Math.round(p[1] / GRID)}`
const edgeKey = (a: Point, b: Point) => { const [x, y] = [cell(a), cell(b)]; return x < y ? `${x}|${y}` : `${y}|${x}` }

/** Every stretch of ground the loop covers, keyed so that walking a street in
 *  either direction lands on the same key. */
function edges(coordinates: Point[]) {
  const flat = project(coordinates), lengths = new Map<string, number>(), counts = new Map<string, number>()
  let total = 0
  for (let i = 1; i < flat.length; i++) {
    const length = Math.hypot(flat[i][0] - flat[i - 1][0], flat[i][1] - flat[i - 1][1])
    total += length
    const key = edgeKey(flat[i - 1], flat[i])
    if (key.split('|')[0] === key.split('|')[1]) continue // both ends in one cell: too short to judge
    lengths.set(key, (lengths.get(key) || 0) + length)
    counts.set(key, (counts.get(key) || 0) + 1)
  }
  return { lengths, counts, total }
}

/** Share of the walk spent on ground the loop already covers — the "down a
 *  short path and back again" failure, measured directly. */
export function retraceFraction(coordinates: Point[]) {
  const { lengths, counts, total } = edges(coordinates)
  if (!total) return 0
  let repeated = 0
  for (const [key, count] of counts) if (count > 1) repeated += lengths.get(key)!
  return Math.min(1, repeated / total)
}

/** Isoperimetric quotient: 1 for a circle, 0 for an out-and-back with no
 *  enclosed area. Penalises both spurs and self-crossing figure-eights. */
export function roundness(coordinates: Point[]) {
  const flat = project(coordinates)
  if (flat.length < 4) return 0
  let twiceArea = 0, perimeter = 0
  for (let i = 0; i < flat.length; i++) {
    const a = flat[i], b = flat[(i + 1) % flat.length]
    twiceArea += a[0] * b[1] - b[0] * a[1]
    perimeter += Math.hypot(b[0] - a[0], b[1] - a[1])
  }
  if (!perimeter) return 0
  return Math.min(1, 4 * Math.PI * Math.abs(twiceArea / 2) / perimeter ** 2)
}

// ORS instruction types: 2/3 are sharp turns, 9 is a U-turn. A loop peppered
// with these is threading back through itself rather than going somewhere.
const SHARP = new Set([2, 3, 9])
export const sharpTurnsPerKm = (maneuvers: (number | undefined)[], distanceMeters: number) =>
  distanceMeters > 0 ? maneuvers.filter(m => m !== undefined && SHARP.has(m)).length / (distanceMeters / 1000) : 0

export function measure(coordinates: Point[], distanceMeters: number, targetMeters: number, maneuvers: (number | undefined)[]): Metrics {
  return {
    retraceFraction: retraceFraction(coordinates),
    roundness: roundness(coordinates),
    distanceErrorFraction: targetMeters > 0 ? Math.abs(distanceMeters - targetMeters) / targetMeters : 0,
    sharpTurnsPerKm: sharpTurnsPerKm(maneuvers, distanceMeters),
  }
}

/** Higher is better. Retracing and shapelessness are what walkers actually
 *  notice; missing the asked-for distance is penalised without a ceiling
 *  because ORS occasionally returns a loop three times the length requested. */
export const scoreLoop = (m: Metrics) =>
  100 - 130 * m.retraceFraction + 90 * m.roundness - 120 * Math.min(m.distanceErrorFraction, 1) - 7 * m.sharpTurnsPerKm

// A loop that repeats a quarter of its own ground, or badly misses the distance
// asked for, reads as a mistake however well it scores elsewhere.
export const UNACCEPTABLE_RETRACE = .25
export const UNACCEPTABLE_DISTANCE_ERROR = .25
// Where the streets simply will not make the loop asked for, offering two
// honest walks beats padding the list with one nobody wanted.
export const NEVER_OFFER_DISTANCE_ERROR = .75

/** Share of one loop's ground that another loop also covers. Used to keep the
 *  three offered choices genuinely different walks. */
export function overlapFraction(a: Point[], b: Point[]) {
  const left = edges(a), right = edges(b)
  if (!left.total) return 0
  let shared = 0
  for (const [key, length] of left.lengths) if (right.counts.has(key)) shared += length
  return Math.min(1, shared / left.total)
}

export const MAX_OVERLAP = .55

/** Pick the best loops that are each distinct from the ones already picked,
 *  relaxing the quality bar only if that would leave the walker with nothing.
 *  Pass `relax: false` to ask how many candidates clear the bar outright. */
export function selectLoops<T extends { coordinates: Point[]; metrics: Metrics }>(candidates: T[], wanted = 3, relax = true) {
  const ranked = candidates.filter(c => c.metrics.distanceErrorFraction <= NEVER_OFFER_DISTANCE_ERROR)
    .sort((a, b) => scoreLoop(b.metrics) - scoreLoop(a.metrics))
  const chosen: T[] = []
  for (const pass of relax ? [true, false] : [true]) {
    for (const candidate of ranked) {
      if (chosen.length >= wanted) break
      if (chosen.includes(candidate)) continue
      if (pass && (candidate.metrics.retraceFraction > UNACCEPTABLE_RETRACE || candidate.metrics.distanceErrorFraction > UNACCEPTABLE_DISTANCE_ERROR)) continue
      if (chosen.some(other => overlapFraction(candidate.coordinates, other.coordinates) > MAX_OVERLAP)) continue
      chosen.push(candidate)
    }
  }
  // Nothing survived the distinctness filter: better one loop than none.
  if (relax && !chosen.length && ranked.length) chosen.push(ranked[0])
  return chosen
}

const COMPASS = ['North', 'North-east', 'East', 'South-east', 'South', 'South-west', 'West', 'North-west']
/** Name a loop for the way it actually heads, taken from its furthest point
 *  rather than its centroid: the far end of the walk is the part a walker
 *  pictures, and it separates loops that merely start off the same way. */
export function describeDirection(coordinates: Point[], start: Point) {
  if (!coordinates.length) return 'Loop'
  const [origin, ...flat] = project([start, ...coordinates])
  let far = origin, best = -1
  for (const p of flat) {
    const distance = Math.hypot(p[0] - origin[0], p[1] - origin[1])
    if (distance > best) { best = distance; far = p }
  }
  if (best <= 0) return 'Loop'
  const bearing = (Math.atan2(far[0] - origin[0], far[1] - origin[1]) / RAD + 360) % 360
  return `${COMPASS[Math.round(bearing / 45) % 8]} loop`
}

/** Two loops heading the same way would otherwise share a name, so tell them
 *  apart by length — which is the thing the walker is choosing between. */
export function nameLoops(loops: { distanceMeters: number; direction: string }[]) {
  return loops.map(({ direction: name }, index) => {
    const sameWay = loops.map((loop, i) => ({ i, distance: loop.distanceMeters })).filter(({ i }) => loops[i].direction === name)
    if (sameWay.length < 2) return name
    sameWay.sort((a, b) => a.distance - b.distance)
    const rank = sameWay.findIndex(({ i }) => i === index)
    if (rank === 0) return `Shorter ${name.toLowerCase()}`
    if (rank === sameWay.length - 1) return `Longer ${name.toLowerCase()}`
    return name
  })
}
