/**
 * P28, P29, P30 — does the search scale, and what does it do when the door is
 * nowhere near a circuit.
 *
 * Three questions, none of them research:
 *
 *  - **Target distances** beyond the 3 km and 5 km the fixtures have always
 *    used. 2, 3, 5, 8 and 10 km from the same starts, so an obvious scaling
 *    failure shows up before the app goes on the road rather than after.
 *  - **Starts outside the 2-core.** A rooted circuit cannot use a dead end, so
 *    a start that sits on one has to reach the core through a doorstep stem —
 *    and past the gate's own 75 m doorstep window those metres are charged as
 *    retracing. What happens then is measured rather than assumed.
 *  - **The densest graph available.** The Isle of Man is what is imported, so
 *    Douglas at 10 km is the largest search this data can pose. Reported as
 *    that rather than as a city test.
 *
 * Every row is the answer the service actually sent, judged by the production
 * gate, with the fallback to Phase 3B left switched on — so a row showing
 * `remote` is the fallback working, not the benchmark failing.
 */
import { writeFileSync } from 'node:fs'
import { startService } from '../phase2/service.mjs'
import { warm } from '../phase3a/warm.mjs'

const ghUrl = process.env.GH_URL ?? 'http://localhost:8991'
const port = Number(process.env.PORT ?? 8825)

const DOUGLAS = { lng: -4.4816, lat: 54.1506 }
const PEEL = { lng: -4.6947, lat: 54.2247 }
const ONCHAN = { lng: -4.4530, lat: 54.1745 }

/** P28: a spread of targets from three starts with different network around them. */
const distances = [2, 3, 5, 8, 10]
const starts = [
  { name: 'douglas', start: DOUGLAS },
  { name: 'peel', start: PEEL },
  { name: 'onchan', start: ONCHAN },
]

/**
 * P29: starts at increasing remove from the 2-core.
 *
 * The stem the search reports is the measurement — `inside` should be zero,
 * `doorstep` inside the gate's 75 m window, and `outside` well past it.
 */
const cores = [
  { name: 'core-inside', start: DOUGLAS, about: 'town centre, already in the 2-core' },
  { name: 'core-doorstep', start: PEEL, about: 'snaps ~60 m outside the 2-core' },
  { name: 'core-outside-a', start: { lng: -4.7570, lat: 54.1206 }, about: 'Niarbyl, coast road end' },
  { name: 'core-outside-b', start: { lng: -4.3690, lat: 54.4137 }, about: 'Point of Ayre, the northern tip' },
  { name: 'core-outside-c', start: { lng: -4.5100, lat: 54.2760 }, about: 'Sulby glen, single lane up a valley' },
]

type Row = {
  group: string
  label: string
  km: number
  engine: string
  requested: string
  fallbackReason?: string
  wallMs: number
  routes: number
  errorPercent: number
  quality: number
  uTurns: number
  stemMetres?: number
  closedWalks?: number
  states?: number
  searchMs?: number
  peakStoreKB?: number
}

await warm(ghUrl)
const service = await startService(port, { GRAPHHOPPER_IOM_URL: ghUrl, GRAPHHOPPER_ENGLAND_URL: ghUrl })
const rows: Row[] = []

async function run(group: string, label: string, start: { lng: number; lat: number }, km: number): Promise<Row> {
  const body = { start, mode: 'distance', distanceKm: km, units: 'km', variation: 0, routingEngine: 'direct' }
  await service.generate(body)
  const { wallMs, payload } = await service.generate(body)
  const routes = payload.routes ?? []
  const target = km * 1000
  return {
    group,
    label,
    km,
    engine: payload.engine?.routingEngine ?? 'remote',
    requested: payload.engine?.requestedEngine ?? 'direct',
    fallbackReason: payload.engine?.fallbackReason,
    wallMs,
    routes: routes.length,
    errorPercent: routes.length
      ? Number((routes.reduce((sum: number, route: any) => sum + Math.abs(route.distanceMeters - target) / target * 100, 0) / routes.length).toFixed(1))
      : 0,
    quality: routes.length ? Number((routes.reduce((sum: number, route: any) => sum + route.quality.score, 0) / routes.length).toFixed(1)) : 0,
    uTurns: routes.reduce((sum: number, route: any) => sum + route.quality.uTurnCount, 0),
    closedWalks: payload.engine?.searchClosedWalks,
    stemMetres: payload.engine?.searchStemMetres,
    states: payload.engine?.searchStates,
    searchMs: payload.engine?.searchMs,
    peakStoreKB: payload.engine?.searchPeakBytes ? Math.round(payload.engine.searchPeakBytes / 1024) : undefined,
  }
}

try {
  for (const { name, start } of starts) {
    for (const km of distances) rows.push(await run('distance', name, start, km))
  }
  for (const { name, start } of cores) rows.push(await run('core', name, start, 5))
} finally {
  await service.stop()
}

const table = (group: string, title: string) => {
  console.log(`\n### ${title}\n`)
  console.log('| start | km | engine | fallback | routes | mean err % | quality | u-turns | stem m | closed walks | states | search ms | peak store KB | wall ms |')
  console.log('|---|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
  for (const row of rows.filter(entry => entry.group === group)) {
    console.log(`| ${row.label} | ${row.km} | ${row.engine} | ${row.fallbackReason ?? '—'} | ${row.routes} | ${row.errorPercent} | ${row.quality} | ${row.uTurns} | ${row.stemMetres?.toFixed(1) ?? '—'} | `
      + `${row.closedWalks ?? '—'} | ${row.states ?? '—'} | ${row.searchMs?.toFixed(1) ?? '—'} | ${row.peakStoreKB ?? '—'} | ${row.wallMs} |`)
  }
}

table('distance', 'P28 — target distances, Direct Search requested')
table('core', 'P29 — starts at increasing remove from the 2-core, 5 km')

const cored = rows.filter(row => row.group === 'core')
console.log('\n' + cores.map(entry => {
  const row = cored.find(candidate => candidate.label === entry.name)!
  return `${entry.name.padEnd(16)} ${entry.about.padEnd(40)} -> ${row.engine}${row.fallbackReason ? ` (${row.fallbackReason})` : ''}, ${row.routes} routes`
}).join('\n'))

writeFileSync(new URL('results/smoke.json', import.meta.url), JSON.stringify(rows, null, 2))
console.log('\nwrote bench/phase10/results/smoke.json')
