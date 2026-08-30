/**
 * Phase 3A §2, §13, §14: the boundary with nothing queued behind it.
 *
 * The corpus is replayed serially, so nothing waits on anything and the whole
 * round trip is attributable. Each protocol is measured the same way and the
 * facade reports what it spent inside itself, so what is left after
 * subtracting it is transport: sockets, HTTP framing and the kernel.
 *
 * Serial on purpose, as in Phase 2. Production runs six of these at once,
 * which makes each call's measured latency partly a measure of the other five,
 * and a number that moves when the concurrency limit moves cannot be
 * attributed to anything.
 */
import { readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { buildRouteBody } from '../../src/graphhopper.js'
import { identify } from '../../src/boundary.js'
import { percentiles } from '../../src/loops/metrics.js'

const GH_URL = process.env.GH_URL ?? 'http://localhost:8991'
const REPEATS = Number(process.env.REPEATS ?? 3)

const dir = new URL('../phase2/corpus/', import.meta.url)
type Call = { purpose: string; class: string; points: [number, number][]; model: any }
const files = readdirSync(dir).filter(f => f.endsWith('.jsonl')).sort()

/** Handles are scoped to a generation, and each fixture is one. */
const byFixture = files.map(file => ({
  fixture: file.replace('.jsonl', ''),
  calls: readFileSync(new URL(file, dir), 'utf8').trim().split('\n').filter(Boolean)
    .map(line => JSON.parse(line) as Call).filter(call => call.points),
}))

type Sample = { class: string; stringifyMs: number; wireMs: number; parseMs: number; requestBytes: number; responseBytes: number; javaMs: number; routeMs: number }

async function run(useHandles: boolean): Promise<Sample[]> {
  const samples: Sample[] = []
  for (const { calls } of byFixture) {
    const generation = useHandles
      ? ((await (await fetch(new URL('/generation', GH_URL), { method: 'POST' })).json()) as any).generation
      : undefined
    const sentAreas = new Set<string>()
    const sentModels = new Set<string>()
    for (const call of calls) {
      const identity = useHandles ? identify(call.model ?? undefined) : null
      let handle: any
      if (identity && generation) {
        const register: Record<string, unknown> = {}
        identity.areaIds.forEach((areaId, index) => {
          if (!sentAreas.has(areaId)) { register[areaId] = identity.areas[index]; sentAreas.add(areaId) }
        })
        handle = sentModels.has(identity.id)
          ? { generation, id: identity.id }
          : {
              generation, id: identity.id,
              ...(Object.keys(register).length ? { register } : {}),
              define: {
                areas: identity.areaIds,
                ...(identity.multiplyBy === undefined ? {} : { multiply_by: identity.multiplyBy }),
                ...(identity.distanceInfluence === undefined ? {} : { distance_influence: identity.distanceInfluence }),
              },
            }
        sentModels.add(identity.id)
      }
      const body = buildRouteBody(call.points, {
        profile: 'foot',
        customModel: handle ? undefined : (call.model ?? undefined),
        modelHandle: handle,
      })
      // Every repeat re-serialises, because `JSON.stringify` is Looper's cost
      // too and the whole point of a handle is that there is less of it to do.
      const runs: Sample[] = []
      for (let repeat = 0; repeat < REPEATS; repeat++) {
        const stringifyBegan = performance.now()
        const serialised = JSON.stringify(body)
        const stringifyMs = performance.now() - stringifyBegan
        const wireBegan = performance.now()
        const response = await fetch(new URL('/route', GH_URL), {
          method: 'POST', headers: { 'content-type': 'application/json' }, body: serialised,
        })
        const text = await response.text()
        const wireMs = performance.now() - wireBegan
        const parseBegan = performance.now()
        JSON.parse(text)
        const parseMs = performance.now() - parseBegan
        const timing = Object.fromEntries((response.headers.get('x-looper-timing') ?? '').split(',')
          .map(part => part.split('=')).filter(pair => pair.length === 2).map(([k, v]) => [k, Number(v) / 1000]))
        runs.push({
          class: call.class, stringifyMs, wireMs, parseMs,
          requestBytes: serialised.length, responseBytes: text.length,
          javaMs: (timing.dispatch ?? 0) + (timing.route ?? 0) + (timing.serialize ?? 0),
          routeMs: timing.route ?? 0,
        })
      }
      runs.sort((a, b) => a.wireMs - b.wireMs)
      samples.push(runs[runs.length >> 1])
    }
    if (generation) await fetch(new URL(`/generation/${generation}`, GH_URL), { method: 'DELETE' })
  }
  return samples
}

const sum = (values: number[]) => values.reduce((total, value) => total + value, 0)
const report = (label: string, samples: Sample[]) => ({
  label,
  calls: samples.length,
  stringifyMs: sum(samples.map(s => s.stringifyMs)),
  wireMs: sum(samples.map(s => s.wireMs)),
  parseMs: sum(samples.map(s => s.parseMs)),
  javaMs: sum(samples.map(s => s.javaMs)),
  routeMs: sum(samples.map(s => s.routeMs)),
  requestMB: sum(samples.map(s => s.requestBytes)) / 1024 / 1024,
  responseMB: sum(samples.map(s => s.responseBytes)) / 1024 / 1024,
  medianWireMs: percentiles(samples.map(s => Math.round(s.wireMs * 100))).median / 100,
})

await run(false)   // warm both ends and the connection pool
const before = report('model in every body', await run(false))
const after = report('model named by handle', await run(true))

console.log('| protocol | calls | JSON.stringify ms | round trip ms | median | JSON.parse ms | in the facade ms | of which hopper.route | request MB | response MB |')
console.log('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
for (const row of [before, after]) {
  console.log(`| ${row.label} | ${row.calls} | ${row.stringifyMs.toFixed(0)} | ${row.wireMs.toFixed(0)} | ${row.medianWireMs.toFixed(2)} | ${row.parseMs.toFixed(0)} | ${row.javaMs.toFixed(0)} | ${row.routeMs.toFixed(0)} | ${row.requestMB.toFixed(2)} | ${row.responseMB.toFixed(2)} |`)
}
const pct = (a: number, b: number) => `${(((b - a) / a) * 100).toFixed(1)}%`
console.log(`| **change** | | **${pct(before.stringifyMs, after.stringifyMs)}** | **${pct(before.wireMs, after.wireMs)}** | | ${pct(before.parseMs, after.parseMs)} | **${pct(before.javaMs, after.javaMs)}** | ${pct(before.routeMs, after.routeMs)} | **${pct(before.requestMB, after.requestMB)}** | ${pct(before.responseMB, after.responseMB)} |`)
console.log(`\ntransport, once the facade's own time is taken out: ${(before.wireMs - before.javaMs).toFixed(0)} ms -> ${(after.wireMs - after.javaMs).toFixed(0)} ms`)

writeFileSync(new URL('results/transport.json', import.meta.url), JSON.stringify({ before, after }, null, 1))
