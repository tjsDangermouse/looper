/**
 * Warm a facade against the whole workload before anything is timed.
 *
 * Phase 2's second trap, and it cost that phase a wrong answer once: a JVM
 * that has not compiled GraphHopper's search, its custom weighting and Jackson
 * is not slower by a little. A stage measured against a cold facade reports
 * the facade's age, not the change.
 */
import { readFileSync, readdirSync } from 'node:fs'
import { buildRouteBody } from '../../src/graphhopper.js'

const dir = new URL('../phase2/corpus/', import.meta.url)
const corpus = readdirSync(dir).filter(f => f.endsWith('.jsonl')).sort()
  .flatMap(f => readFileSync(new URL(f, dir), 'utf8').trim().split('\n').filter(Boolean).map(l => JSON.parse(l)))
  .filter((r: any) => r.points)

export async function warm(url: string, passes = 2): Promise<void> {
  const bodies = corpus.map(r => JSON.stringify(buildRouteBody(r.points, { profile: 'foot', customModel: r.model ?? undefined })))
  for (let pass = 0; pass < passes; pass++) {
    for (const body of bodies) {
      const response = await fetch(new URL('/route', url), { method: 'POST', headers: { 'content-type': 'application/json' }, body })
      await response.text()
    }
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  for (const url of process.argv.slice(2)) {
    const began = Date.now()
    await warm(url)
    console.log(`${url} warmed with ${corpus.length * 2} calls in ${Date.now() - began} ms`)
  }
}
