/**
 * Phase 3B §16–§18, §31: what the fan-out is really buying.
 *
 * Phase 3A found that concurrency buys wall time by doing more work — 1,400
 * engine calls at one-way against 1,895 at eight-way, for the same three
 * walks. That is speculation: the early stop is decided on a settled prefix,
 * and every candidate dispatched past the prefix that eventually decides it is
 * work nobody needed.
 *
 * This sweeps the fan-out at the retained configuration and reports wall time
 * and calls together, because §31 refuses one without the other. Route
 * identity is asserted across every level: a scheduling change that returns a
 * different walk is not a scheduling change.
 */
import { writeFileSync } from 'node:fs'
import { FIXTURES, hashRoute } from '../phase2/fixtures.mjs'
import { startService } from '../phase2/service.mjs'
import { warm } from '../phase3a/warm.mjs'

const PORT = 8812
const GH_URL = process.env.GH_URL ?? 'http://localhost:8991'
const RUNS = Number(process.env.RUNS ?? 5)
const LEVELS = (process.env.LEVELS ?? '1,2,4,6,8').split(',').map(Number)
const env = Object.fromEntries(process.argv.slice(3).map(p => p.split('=') as [string, string]))
const label = process.argv[2] ?? 'B0'

const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)]
await warm(GH_URL)

const rows: any[] = []
for (const level of LEVELS) {
  const service = await startService(PORT, {
    GRAPHHOPPER_IOM_URL: GH_URL, GRAPHHOPPER_ENGLAND_URL: GH_URL,
    LOOPER_MODEL_REGISTRY: 'true', LOOPER_ROUTE_MEMO: 'true', ROUTING_CONCURRENCY: String(level), ...env,
  })
  try {
    for (const fixture of FIXTURES) {
      const walls: number[] = []
      const calls: number[] = []
      const built: number[] = []
      let hashes: string[] = []
      for (let run = 0; run < RUNS + 1; run++) {
        const { wallMs, payload } = await service.generate(fixture.body)
        if (run === 0) continue
        walls.push(wallMs)
        calls.push(payload.diagnostics?.metrics?.graphhopperCalls ?? 0)
        built.push(payload.diagnostics?.metrics?.candidatesBuilt ?? 0)
        hashes = (payload.routes ?? []).map((r: any) => hashRoute(r.geometry?.coordinates ?? []))
      }
      rows.push({ label, level, fixture: fixture.name, wallMs: median(walls), calls: median(calls), built: median(built), hashes })
      console.log(`${label} c=${level} ${fixture.name.padEnd(13)} ${String(median(walls)).padStart(5)}ms  calls=${String(median(calls)).padStart(4)}  built=${median(built)}`)
    }
  } finally {
    await service.stop()
  }
}
writeFileSync(new URL(`results/scheduling-${label}.json`, import.meta.url), JSON.stringify(rows, null, 1))
