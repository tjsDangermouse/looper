/**
 * What one leg actually costs the engine, and why.
 *
 * The service probe measures whole requests. This measures a single leg
 * against GraphHopper directly, four ways, to answer one question the whole
 * avoidance design rests on and which nothing has ever measured: does the
 * landmark heuristic still do anything once a per-request custom model is
 * attached?
 *
 * GraphHopper's own documentation says landmarks are "no faster than flexible
 * mode" under a request custom model, while graphhopper/config.yml says they
 * "give most of the speed back". Both cannot be true. `visited_nodes` decides
 * it: milliseconds say how long we waited, this says how much of the graph was
 * searched.
 *
 * Run it where GraphHopper is reachable — it is not published to the host in
 * production, so from inside the compose network:
 *
 *   docker compose -p looper_router -f docker-compose.prod.yml cp \
 *     bench/probe-engine.mjs route-service:/tmp/probe-engine.mjs
 *   docker compose -p looper_router -f docker-compose.prod.yml exec \
 *     route-service node /tmp/probe-engine.mjs
 *
 * Read it as: if "landmarks" and "no landmarks" settle a similar number of
 * nodes, the heuristic is not helping and the config comment is wrong. If
 * "one area" is far above "landmarks", the custom model is what costs, not the
 * polygon arithmetic.
 */
const BASE = process.argv[2] ?? process.env.GRAPHHOPPER_IOM_URL ?? 'http://graphhopper-iom:8989'
const PROFILE = process.env.GRAPHHOPPER_PROFILE ?? 'foot'
const REPEATS = Number(process.env.REPEATS ?? 7)

/** Douglas seafront to roughly a kilometre and a half inland — an ordinary leg. */
const FROM = [-4.4816, 54.1506]
const TO = [-4.4693, 54.1602]

/** A disc, in the shape `avoidance.ts` builds and GraphHopper accepts. */
const disc = (centre, radiusMetres, id) => {
  const ring = Array.from({ length: 25 }, (_, i) => {
    const angle = (i / 24) * 2 * Math.PI
    const dLat = (radiusMetres * Math.cos(angle)) / 111320
    const dLng = (radiusMetres * Math.sin(angle)) / (111320 * Math.cos((centre[1] * Math.PI) / 180))
    return [centre[0] + dLng, centre[1] + dLat]
  })
  return { type: 'Feature', id, properties: {}, geometry: { type: 'Polygon', coordinates: [ring] } }
}

const midpoint = [(FROM[0] + TO[0]) / 2, (FROM[1] + TO[1]) / 2]

/** The 0.05 priority multiplier is AVOID_PRIORITY: a twentyfold weight increase. */
const avoidModel = count => {
  const areas = Array.from({ length: count }, (_, i) =>
    disc([midpoint[0] + i * 0.002, midpoint[1] + i * 0.001], 120, `looper_avoid_${i}`))
  return {
    priority: areas.map(a => ({ if: `in_${a.id}`, multiply_by: '0.05' })),
    areas: { type: 'FeatureCollection', features: areas },
  }
}

/** Everything the service asks for on every leg, kept in one place. */
const AS_SENT = {
  instructions: true,
  calc_points: true,
  points_encoded: false,
  details: ['street_name', 'road_class', 'edge_id'],
}

const CELLS = [
  // Is the *search* the cost? Production says no — 200-1000 nodes a call — so
  // these two should differ little, and that is the point of asking.
  { name: 'bare search', body: {} },
  { name: 'bare, no landmarks', body: { 'lm.disable': true } },
  { name: 'bare + 1 avoid area', body: { custom_model: avoidModel(1) } },
  { name: 'bare + 8 avoid areas', body: { custom_model: avoidModel(8) } },
  // If the cost is not the search, it is what we ask to be built and returned
  // afterwards. The service asks for all of this on every leg, including the
  // three in five that are thrown away unseen.
  { name: 'as the service sends', body: AS_SENT },
  { name: '  without instructions', body: { ...AS_SENT, instructions: false } },
  { name: '  without path details', body: { ...AS_SENT, details: [] } },
  { name: '  edge_id detail only', body: { ...AS_SENT, details: ['edge_id'] } },
  { name: '  points encoded', body: { ...AS_SENT, points_encoded: true } },
  { name: 'as sent + 1 avoid area', body: { ...AS_SENT, custom_model: avoidModel(1) } },
]

const ask = async extra => {
  const began = process.hrtime.bigint()
  const response = await fetch(`${BASE}/route`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      points: [FROM, TO],
      profile: PROFILE,
      'ch.disable': true,
      instructions: false,
      calc_points: false,
      ...extra,
    }),
  })
  const ms = Number(process.hrtime.bigint() - began) / 1e6
  if (!response.ok) throw new Error(`${response.status} ${(await response.text()).slice(0, 200)}`)
  const payload = await response.json()
  return { ms, nodes: payload?.hints?.['visited_nodes.sum'], metres: payload?.paths?.[0]?.distance }
}

const median = xs => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)]

console.log(`${BASE}  profile=${PROFILE}  ${REPEATS} repeats, median reported\n`)
console.log('cell                      ms   visited nodes   metres')
console.log('----------------------  ----   -------------   ------')
let baseline
for (const cell of CELLS) {
  try {
    await ask(cell.body)                                   // warm the caches
    const runs = []
    for (let i = 0; i < REPEATS; i++) runs.push(await ask(cell.body))
    const ms = median(runs.map(r => r.ms))
    const nodes = median(runs.map(r => r.nodes ?? 0))
    baseline ??= nodes
    const ratio = baseline && nodes ? `  (${(nodes / baseline).toFixed(1)}x)` : ''
    console.log(`${cell.name.padEnd(22)}  ${ms.toFixed(1).padStart(4)}   ${String(nodes).padStart(13)}${ratio}   ${Math.round(runs[0].metres ?? 0)}`)
  } catch (error) {
    console.log(`${cell.name.padEnd(22)}  failed: ${error.message}`)
  }
}
console.log(`
Production settles only 200-1000 nodes a call, so the search is not the cost:
at 60 ms a call that is 80 microseconds a node, and a Dijkstra does millions a
second. What the "as the service sends" rows measure is the rest of the
request — building instructions, extracting path details, serialising the
geometry — which is paid in full on every leg including the three in five that
are thrown away without ever being looked at.`)
