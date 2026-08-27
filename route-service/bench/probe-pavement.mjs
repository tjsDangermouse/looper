/**
 * How hard a pavement preference has to push, and what it costs to push.
 *
 * `looper-foot-2` demoted every non-pedestrian road by 0.1 to stop routes
 * flip-flopping between a pavement and its own carriageway. It worked, and it
 * cost two to three times the engine calls on urban ground, because priority
 * divides the weight: 0.1 does not say "prefer a pavement", it says a pavement
 * is worth walking ten times as far for, and it buys every large detour to any
 * footway nearby along with the tie-break that was wanted. See
 * `docs/routing-report.md`.
 *
 * The tie-break itself should be cheap. A pavement's handicap against its own
 * carriageway is the set-back and the crossings — order 10% of length. So there
 * should be a multiplier that stops the hopping and buys no detours, and this
 * finds it by asking for the same legs at each of several values.
 *
 * Two columns decide it:
 *
 *   hops/km   how often the route changed between a dedicated pedestrian way
 *             and a carriageway. This is the problem being solved. It should
 *             fall fast and then flatten.
 *   metres    the same leg's length against the neutral baseline. This is what
 *             the slowdown was made of: a longer, bent leg misses what the
 *             corridor aimed at, so Looper rejects it and asks again. It should
 *             sit near zero and then start climbing.
 *
 * Take the largest multiplier past the knee in hops/km but before metres moves.
 * If there is no such gap — if hopping only stops where length has already gone
 * up — then the hopping is not a near-tie, the whole tie-break theory is wrong,
 * and the answer is to stop and look at what the routes actually do rather than
 * ship another guess.
 *
 * This only reads correctly against a NEUTRAL profile (`looper-foot-3` or
 * later, with no road-class rule). A per-request custom model composes
 * multiplicatively with the profile's own, so running this against
 * `looper-foot-2` would measure each value times 0.1.
 *
 * Run it where GraphHopper is reachable — it is not published to the host in
 * production, so from inside the compose network:
 *
 *   docker compose -p looper_router -f docker-compose.prod.yml cp \
 *     bench/probe-pavement.mjs route-service:/tmp/probe-pavement.mjs
 *   docker compose -p looper_router -f docker-compose.prod.yml exec \
 *     route-service node /tmp/probe-pavement.mjs
 */
const BASE = process.argv[2] ?? process.env.GRAPHHOPPER_IOM_URL ?? 'http://graphhopper-iom:8989'
const PROFILE = process.env.GRAPHHOPPER_PROFILE ?? 'foot'
const REPEATS = Number(process.env.REPEATS ?? 3)

/**
 * Ordinary town legs, on the ground the probe scenarios walk. Douglas and
 * Onchan have pavements mapped as their own ways and are where the hopping is;
 * Peel has fewest and is the control — it barely moved under `looper-foot-2`
 * and should barely move here.
 */
const LEGS = [
  { name: 'douglas seafront',  from: [-4.4816, 54.1506], to: [-4.4693, 54.1602] },
  { name: 'douglas inland',    from: [-4.4750, 54.1550], to: [-4.4600, 54.1650] },
  { name: 'onchan',            from: [-4.4530, 54.1720], to: [-4.4400, 54.1800] },
  { name: 'peel (control)',    from: [-4.7020, 54.2250], to: [-4.6900, 54.2320] },
]

/** The multipliers to try. 1.0 is the neutral control: the profile as it ships. */
const MULTIPLIERS = [1.0, 0.95, 0.9, 0.8, 0.6, 0.3, 0.1]

/**
 * The rule under test, exactly as `looper_foot.json` would carry it — the same
 * four classes, so what is measured here is what would ship.
 */
const PEDESTRIAN = ['FOOTWAY', 'PATH', 'PEDESTRIAN', 'STEPS']
const pavementModel = multiplier => ({
  priority: [{
    if: PEDESTRIAN.map(cls => `road_class != ${cls}`).join(' && '),
    multiply_by: String(multiplier),
  }],
})

/** Everything the service asks for on a leg that this measurement depends on. */
const ask = async (leg, multiplier) => {
  const body = {
    points: [leg.from, leg.to],
    profile: PROFILE,
    'ch.disable': true,
    instructions: false,
    calc_points: true,
    points_encoded: false,
    details: ['road_class'],
    ...(multiplier === 1 ? {} : { custom_model: pavementModel(multiplier) }),
  }
  const began = process.hrtime.bigint()
  const response = await fetch(`${BASE}/route`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })
  const ms = Number(process.hrtime.bigint() - began) / 1e6
  if (!response.ok) throw new Error(`${response.status} ${(await response.text()).slice(0, 200)}`)
  const payload = await response.json()
  const path = payload?.paths?.[0]
  return {
    ms,
    nodes: payload?.hints?.['visited_nodes.sum'] ?? 0,
    metres: path?.distance ?? 0,
    ...hops(path),
  }
}

/**
 * The same measure as `pavementReport` in src/loops/edges.ts, kept standalone
 * so this script has no build step and no imports: transitions between
 * pedestrian ways and carriageways, length-weighted, per kilometre.
 *
 * Transitions rather than classes — a leg entirely on pavement and a leg
 * entirely on road both score zero. Only alternation confuses a walker.
 */
function hops(path) {
  const spans = path?.details?.road_class
  const points = path?.points?.coordinates
  if (!Array.isArray(spans) || !Array.isArray(points) || points.length < 2) {
    return { hops: 0, hopsPerKm: 0, pavementPercent: 0, measured: 0 }
  }
  const cumulative = [0]
  for (let i = 1; i < points.length; i++) cumulative.push(cumulative[i - 1] + metresBetween(points[i - 1], points[i]))

  let changes = 0
  let measured = 0
  let pavement = 0
  let previous
  for (const [from, to, value] of [...spans].sort((a, b) => a[0] - b[0])) {
    if (!Number.isInteger(from) || !Number.isInteger(to)) continue
    if (from < 0 || to >= points.length || to <= from) continue
    const length = cumulative[to] - cumulative[from]
    if (!(length > 0)) continue
    const pedestrian = PEDESTRIAN.includes(String(value).toUpperCase())
    measured += length
    if (pedestrian) pavement += length
    if (previous !== undefined && previous !== pedestrian) changes++
    previous = pedestrian
  }
  return {
    hops: changes,
    hopsPerKm: measured > 0 ? (changes * 1000) / measured : 0,
    pavementPercent: measured > 0 ? (pavement * 100) / measured : 0,
    measured,
  }
}

function metresBetween([lng1, lat1], [lng2, lat2]) {
  const R = 6371008.8
  const rad = Math.PI / 180
  const dLat = (lat2 - lat1) * rad
  const dLng = (lng2 - lng1) * rad
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dLng / 2) ** 2
  return 2 * R * Math.asin(Math.sqrt(a))
}

const median = xs => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)]

console.log(`${BASE}  profile=${PROFILE}  ${REPEATS} repeats, median reported`)
console.log('Against a NEUTRAL profile only — see the header of this file.\n')

const baselines = new Map()
for (const leg of LEGS) {
  console.log(`${leg.name}`)
  console.log('  multiplier   hops/km   hops   on pavement    metres   vs neutral    ms   nodes')
  console.log('  ----------   -------   ----   -----------   -------   ----------   ---   -----')
  for (const multiplier of MULTIPLIERS) {
    try {
      await ask(leg, multiplier)                             // warm the caches
      const runs = []
      for (let i = 0; i < REPEATS; i++) runs.push(await ask(leg, multiplier))
      const metres = median(runs.map(r => r.metres))
      const hopsPerKm = median(runs.map(r => r.hopsPerKm))
      if (multiplier === 1) baselines.set(leg.name, metres)
      const base = baselines.get(leg.name)
      const delta = base ? `${(((metres - base) / base) * 100).toFixed(1).padStart(6)}%` : '     -'
      console.log(
        `  ${String(multiplier).padEnd(10)}   ${hopsPerKm.toFixed(2).padStart(7)}   ` +
        `${String(median(runs.map(r => r.hops))).padStart(4)}   ` +
        `${median(runs.map(r => r.pavementPercent)).toFixed(0).padStart(9)}%   ` +
        `${String(Math.round(metres)).padStart(7)}   ${delta.padStart(10)}   ` +
        `${median(runs.map(r => r.ms)).toFixed(0).padStart(3)}   ${String(median(runs.map(r => r.nodes))).padStart(5)}`,
      )
    } catch (error) {
      console.log(`  ${String(multiplier).padEnd(10)}   failed: ${error.message}`)
    }
  }
  console.log('')
}

console.log('Read hops/km down the column: it should fall fast, then flatten.')
console.log('Read "vs neutral" beside it: the largest multiplier past the knee')
console.log('while this is still near zero is the one to ship.')
