/**
 * Phase 3A §17: what an HTTP exchange costs when it is not paid per leg.
 *
 * A GET of `/info` — no routing, a two-line response — costs about 0.7 ms
 * round trip on a warm keep-alive connection. That is the floor of the
 * boundary: a cost per *call*, not per byte, which is why naming corridors
 * instead of restating them cut 64% of the request bytes and did not move it.
 *
 * This measures what disappears if several legs share one exchange. It is not
 * multi-target routing and it is not a change to how Looper schedules work:
 * each request in a batch is routed by GraphHopper independently, on its own
 * thread, exactly as it would have been alone. The only thing amortised is the
 * envelope — HTTP framing, the JDK server's dispatch, and Node's own
 * fetch/parse per exchange.
 *
 * Batches are formed from consecutive calls in the captured corpus purely to
 * measure the amortisation. Whether Looper naturally *has* six independent
 * requests ready at the same instant is a different question, and this
 * benchmark deliberately does not answer it.
 */
import { readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { buildRouteBody } from '../../src/graphhopper.js'

const GH_URL = process.env.GH_URL ?? 'http://localhost:8991'
const SIZES = (process.env.SIZES ?? '1,2,4,6,8,12').split(',').map(Number)

const dir = new URL('../phase2/corpus/', import.meta.url)
const corpus = readdirSync(dir).filter(f => f.endsWith('.jsonl')).sort()
  .flatMap(f => readFileSync(new URL(f, dir), 'utf8').trim().split('\n').filter(Boolean).map(l => JSON.parse(l)))
  .filter((r: any) => r.points)
const bodies = corpus.map((r: any) => buildRouteBody(r.points, { profile: 'foot', customModel: r.model ?? undefined }))

/**
 * The same work either way: `size` legs in flight at once. At size 1 that is
 * `size` concurrent single-leg exchanges, which is what Looper does today; at
 * size n it is one exchange carrying n legs, routed n ways inside the facade.
 */
async function individually(size: number): Promise<number> {
  const began = performance.now()
  for (let i = 0; i < bodies.length; i += size) {
    await Promise.all(bodies.slice(i, i + size).map(async body => {
      const response = await fetch(new URL('/route', GH_URL), {
        method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
      })
      JSON.parse(await response.text())
    }))
  }
  return performance.now() - began
}

async function batched(size: number): Promise<number> {
  const began = performance.now()
  for (let i = 0; i < bodies.length; i += size) {
    const response = await fetch(new URL('/routeBatch', GH_URL), {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ requests: bodies.slice(i, i + size) }),
    })
    JSON.parse(await response.text())
  }
  return performance.now() - began
}

/** One answer at a time, so a batch cannot quietly return a different walk. */
async function agrees(size: number): Promise<boolean> {
  const slice = bodies.slice(0, size)
  const alone = await Promise.all(slice.map(async body => {
    const r = await fetch(new URL('/route', GH_URL), { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) })
    return JSON.stringify(((await r.json()) as any)?.paths?.[0]?.details?.edge_id ?? null)
  }))
  const together = ((await (await fetch(new URL('/routeBatch', GH_URL), {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ requests: slice }),
  })).json()) as any).responses.map((r: any) => JSON.stringify(r.body?.paths?.[0]?.details?.edge_id ?? null))
  return alone.every((edges, index) => edges === together[index])
}

await individually(6)   // warm both ends and the connection pool
await batched(6)

console.log(`identical routes from a batch of 8: ${await agrees(8) ? 'yes' : 'NO'}\n`)
const rows: any[] = []
console.log('| legs per exchange | separate exchanges ms | one batched exchange ms | saved | per call |')
console.log('|---:|---:|---:|---:|---:|')
for (const size of SIZES) {
  const separate = Math.min(await individually(size), await individually(size))
  const together = Math.min(await batched(size), await batched(size))
  rows.push({ size, separate, together })
  console.log(`| ${size} | ${separate.toFixed(0)} | ${together.toFixed(0)} | ${(((separate - together) / separate) * 100).toFixed(1)}% | ${((separate - together) / bodies.length).toFixed(2)} ms |`)
}
writeFileSync(new URL('results/batch.json', import.meta.url), JSON.stringify({ calls: bodies.length, rows }, null, 1))
