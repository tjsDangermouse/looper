/**
 * Is the direct Java routing core answering the same question the same way?
 *
 * Distance and geometry are checked exactly rather than within a tolerance:
 * the whole point of Gate 1 is that this is the same engine, so "close" would
 * be a failure dressed as a pass. Only timing is allowed to differ.
 */
import { readFileSync } from 'node:fs'

const http = JSON.parse(readFileSync(new URL('results-http.json', import.meta.url), 'utf8'))
/** Whichever side is being held against the container: the direct Java API by default. */
const java = JSON.parse(readFileSync(new URL(process.env.AGAINST ?? 'results-java.json', import.meta.url), 'utf8'))
const byName = new Map<string, any>(java.results.map((r: any) => [r.name, r]))

const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b)
/**
 * The wire rounds: ResponsePathSerializer emits `Helper.round(distance, 3)` and
 * `round6(weight)`. So the two sides are compared at the precision the HTTP
 * side is capable of expressing, which is the only honest comparison — anything
 * stricter would be measuring Jackson, not the router.
 */
const roundTo = (v: number, places: number) => Number(v.toFixed(places))
const sameDistance = (a: number, b: number) => roundTo(a, 3) === roundTo(b, 3)
const sameWeight = (a: number, b: number) => roundTo(a, 6) === roundTo(b, 6)

let failures = 0
const rows: string[] = []
console.log('fixture                    distance   geometry  edges  snap  weight |   HTTP ms   Java ms   speedup | visited')
console.log('------------------------  ---------  ---------  -----  ----  ------ | --------  --------  -------- | -------')
for (const h of http.results) {
  const j = byName.get(h.name)
  if (!j) { console.log(`${h.name}  MISSING from Java run`); failures++; continue }
  if (h.error || j.error) {
    console.log(`${h.name.padEnd(24)}  http=${h.error ?? 'ok'}  java=${j.error ?? 'ok'}`)
    if (h.error !== j.error) failures++
    continue
  }
  const checks = {
    distance: sameDistance(h.distance, j.distance),
    geometry: h.geometryHash === j.geometryHash,
    edges: same(h.edgeIds, j.edgeIds),
    snap: same(h.snappedWaypoints, j.snappedWaypoints),
    weight: sameWeight(h.weight, j.weight),
    visited: h.visitedNodes === j.visitedNodes,
  }
  const bad = Object.entries(checks).filter(([, ok]) => !ok).map(([k]) => k)
  if (bad.length) failures++
  const tick = (ok: boolean) => (ok ? '  ok ' : ' DIFF')
  console.log(
    `${h.name.padEnd(24)}  ${tick(checks.distance).padStart(9)}  ${tick(checks.geometry).padStart(9)}` +
    `  ${tick(checks.edges).padStart(5)}  ${tick(checks.snap).padStart(4)}  ${tick(checks.weight).padStart(6)} |` +
    ` ${h.ms.toFixed(1).padStart(7)}  ${j.ms.toFixed(1).padStart(8)}  ${(h.ms / j.ms).toFixed(2).padStart(7)}x |` +
    ` ${checks.visited ? String(h.visitedNodes).padStart(7) : `${h.visitedNodes}!=${j.visitedNodes}`}`,
  )
  if (bad.length) rows.push(`  ${h.name}: ${bad.join(', ')} differ (http ${h.distance}m/${h.geometryHash} vs java ${j.distance}m/${j.geometryHash})`)
}

const httpTotal = http.results.filter((r: any) => !r.error).reduce((s: number, r: any) => s + r.ms, 0)
const javaTotal = http.results.filter((r: any) => !r.error).reduce((s: number, r: any) => s + byName.get(r.name).ms, 0)
console.log(`\nmedian-sum: HTTP ${httpTotal.toFixed(1)} ms, direct Java ${javaTotal.toFixed(1)} ms  ->  ${(httpTotal / javaTotal).toFixed(2)}x`)
if (java.nodes) console.log(`graph: ${java.nodes} nodes, ${java.edges} edges; load ${Math.round(java.loadMs)} ms; heap after load ${(java.heapAfterLoadBytes / 1e6).toFixed(0)} MB`)
if (rows.length) { console.log('\ndifferences:'); rows.forEach(r => console.log(r)) }
console.log(failures ? `\nFAIL: ${failures} of ${http.results.length} fixtures differ` : `\nPASS: all ${http.results.length} fixtures identical`)
