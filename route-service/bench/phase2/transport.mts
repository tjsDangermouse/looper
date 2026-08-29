/**
 * Phase 2 §20: where the time Looper calls "engine time" actually goes.
 *
 * The lab replays the same corpus inside the JVM and reports what GraphHopper
 * spends on it. This replays it from Node, one call at a time, over the same
 * socket the route service uses. Nothing is concurrent, so nothing is queued,
 * and the difference between the two totals is the cost of the boundary:
 * serialising a request, a loopback round trip, and parsing a response.
 *
 * Serial on purpose. Production runs six of these at once, which makes each
 * call's measured latency partly a measure of the other five, and a number
 * that moves when the concurrency limit moves cannot be attributed to
 * anything.
 */
import { readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { buildRouteBody } from '../../src/graphhopper.js'
import { percentiles } from '../../src/loops/metrics.js'

const GH_URL = process.env.GH_URL ?? 'http://localhost:8991'
const LABEL = process.env.LABEL ?? 'minimal-core'
const REPEATS = Number(process.env.REPEATS ?? 3)

const dir = new URL('corpus/', import.meta.url)
type Record_ = { purpose: string; class: string; points: [number, number][]; model: any; ms: number }
const corpus: Record_[] = readdirSync(dir).filter(f => f.endsWith('.jsonl')).sort()
  .flatMap(f => readFileSync(new URL(f, dir), 'utf8').trim().split('\n').filter(Boolean).map(l => JSON.parse(l)))
  .filter((r: any) => r.points)

console.log(`${corpus.length} calls against ${LABEL} (${GH_URL}), serial, median of ${REPEATS}\n`)

/** The exact bytes the route service sends, built by the route service's own builder. */
const bodies = corpus.map(record => JSON.stringify(buildRouteBody(record.points, { profile: 'foot', customModel: record.model ?? undefined })))

const call = async (body: string) => {
  const began = performance.now()
  const response = await fetch(new URL('/route', GH_URL), {
    method: 'POST', headers: { 'content-type': 'application/json' }, body,
  })
  const text = await response.text()
  const wire = performance.now() - began
  // Parsing is Looper's cost too, and it is not small: the response carries
  // every coordinate as a pair of JSON numbers because `points_encoded` is
  // false. Timed separately so "transport" does not quietly mean "and also
  // whatever Node does with it afterwards".
  const parseBegan = performance.now()
  const payload = JSON.parse(text)
  const parse = performance.now() - parseBegan
  return { wire, parse, bytes: text.length, visited: payload?.hints?.['visited_nodes.sum'] }
}

for (const body of bodies) await call(body)   // warm both ends

const rows: Array<{ class: string; wire: number; parse: number; bytes: number }> = []
for (let i = 0; i < corpus.length; i++) {
  const samples: Array<{ wire: number; parse: number; bytes: number }> = []
  for (let r = 0; r < REPEATS; r++) samples.push(await call(bodies[i]))
  samples.sort((a, b) => a.wire - b.wire)
  const median = samples[samples.length >> 1]
  rows.push({ class: corpus[i].class, ...median })
}

const groups = new Map<string, typeof rows>()
for (const row of rows) {
  if (!groups.has(row.class)) groups.set(row.class, [])
  groups.get(row.class)!.push(row)
}
const sum = (values: number[]) => values.reduce((s, v) => s + v, 0)

console.log('| class | calls | round trip ms | mean | median | p95 | JSON.parse ms | response KB |')
console.log('|---|---:|---:|---:|---:|---:|---:|---:|')
for (const [klass, group] of [...groups].sort((a, b) => sum(b[1].map(r => r.wire)) - sum(a[1].map(r => r.wire)))) {
  const wire = group.map(r => r.wire)
  const p = percentiles(wire.map(v => Math.round(v * 100)))
  console.log(`| ${klass} | ${group.length} | ${sum(wire).toFixed(0)} | ${(sum(wire) / group.length).toFixed(2)} | ${(p.median / 100).toFixed(2)} | ${(p.p95 / 100).toFixed(2)} | ${sum(group.map(r => r.parse)).toFixed(0)} | ${(sum(group.map(r => r.bytes)) / group.length / 1024).toFixed(1)} |`)
}
const totalWire = sum(rows.map(r => r.wire))
const totalParse = sum(rows.map(r => r.parse))
console.log(`| **total** | **${rows.length}** | **${totalWire.toFixed(0)}** | ${(totalWire / rows.length).toFixed(2)} | | | **${totalParse.toFixed(0)}** | |`)
console.log(`\nrequest bytes sent: ${(sum(bodies.map(b => b.length)) / 1024 / 1024).toFixed(2)} MB`)
console.log(`response bytes read: ${(sum(rows.map(r => r.bytes)) / 1024 / 1024).toFixed(2)} MB`)

writeFileSync(new URL(`results/transport-${LABEL}.json`, import.meta.url), JSON.stringify({ label: LABEL, url: GH_URL, calls: rows.length, totalWireMs: totalWire, totalParseMs: totalParse, rows }, null, 1))
