/**
 * Phase 3A §19, §20, §28, §33: where a call's time goes, and what the next
 * phase has to work with.
 *
 * Two rules this reads by. Latency summed across concurrent callers is not
 * time a walker waited — six legs waiting on each other for six milliseconds
 * is six milliseconds of walker's time and thirty-six of this table's — so
 * every total here is stated as a sum of call-site latency and never as a
 * duration. And "the model was reused" and "the answer was reused" are
 * different claims at different scales, so they are counted apart.
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { percentiles } from '../../src/loops/metrics.js'

const FIXTURES = ['douglas-3km', 'douglas-5km', 'onchan-5km', 'peel-5km', 'wp-one', 'wp-two']
const dir = new URL('corpus/', import.meta.url)

type Record_ = {
  purpose: string; class: string; areas: number; ms: number; visitedNodes?: number
  modelId?: string; memo?: 'hit' | 'join' | 'miss'; rediscovered?: boolean
  queueMs?: number; transportMs?: number; engineRouteMs?: number
  requestBytes?: number; responseBytes?: number
}

const calls: Array<Record_ & { fixture: string }> = FIXTURES.flatMap(fixture =>
  readFileSync(new URL(`${fixture}.jsonl`, dir), 'utf8').trim().split('\n').filter(Boolean)
    .map(line => ({ ...(JSON.parse(line) as Record_), fixture })))

const sum = (values: number[]) => values.reduce((total, value) => total + value, 0)
const of = (rows: Record_[], pick: (r: Record_) => number | undefined) => sum(rows.map(r => pick(r) ?? 0))

const routed = calls.filter(call => call.memo !== 'hit' && call.memo !== 'join')
console.log(`${calls.length} calls, of which ${routed.length} reached the engine\n`)

console.log('| where the call-site latency went | ms | per call | share |')
console.log('|---|---:|---:|---:|')
const total = of(calls, c => c.ms)
const parts: Array<[string, number]> = [
  ['waiting for a concurrency slot', of(calls, c => c.queueMs)],
  ['the round trip, engine included', of(calls, c => c.transportMs)],
  ['— of which hopper.route itself', of(calls, c => c.engineRouteMs)],
]
for (const [label, ms] of parts) {
  console.log(`| ${label} | ${ms.toFixed(0)} | ${(ms / calls.length).toFixed(2)} | ${((ms / total) * 100).toFixed(1)}% |`)
}
const unattributed = total - parts[0][1] - parts[1][1]
console.log(`| Looper's own work either side | ${unattributed.toFixed(0)} | ${(unattributed / calls.length).toFixed(2)} | ${((unattributed / total) * 100).toFixed(1)}% |`)
console.log(`| **summed call-site latency** | **${total.toFixed(0)}** | ${(total / calls.length).toFixed(2)} | |`)

console.log('\n| purpose | calls | memo hits | model references | distinct models | ms | mean | mean visited | request KB |')
console.log('|---|---:|---:|---:|---:|---:|---:|---:|---:|')
const purposes = [...new Set(calls.map(c => c.purpose))]
  .sort((a, b) => calls.filter(c => c.purpose === b).length - calls.filter(c => c.purpose === a).length)
const rows: any[] = []
for (const purpose of purposes) {
  const group = calls.filter(c => c.purpose === purpose)
  const withModel = group.filter(c => c.modelId)
  const distinct = new Set(withModel.map(c => `${c.fixture}:${c.modelId}`)).size
  const hits = group.filter(c => c.memo === 'hit' || c.memo === 'join').length
  const row = {
    purpose, calls: group.length, memoHits: hits, modelRefs: withModel.length, distinctModels: distinct,
    ms: of(group, c => c.ms), mean: of(group, c => c.ms) / group.length,
    meanVisited: of(group, c => c.visitedNodes) / Math.max(1, group.filter(c => c.visitedNodes !== undefined).length),
    requestKB: of(group, c => c.requestBytes) / 1024,
  }
  rows.push(row)
  console.log(`| \`${purpose}\` | ${row.calls} | ${row.memoHits} | ${row.modelRefs} | ${row.distinctModels} | ${row.ms.toFixed(0)} | ${row.mean.toFixed(2)} | ${Math.round(row.meanVisited)} | ${row.requestKB.toFixed(0)} |`)
}
console.log(`| **total** | **${calls.length}** | **${calls.filter(c => c.memo === 'hit' || c.memo === 'join').length}** | **${calls.filter(c => c.modelId).length}** | **${new Set(calls.filter(c => c.modelId).map(c => `${c.fixture}:${c.modelId}`)).size}** | **${total.toFixed(0)}** | | | **${(of(calls, c => c.requestBytes) / 1024).toFixed(0)}** |`)

console.log('\n| request class | calls | ms | mean | median | p95 | mean visited |')
console.log('|---|---:|---:|---:|---:|---:|---:|')
for (const klass of [...new Set(calls.map(c => c.class))].sort()) {
  const group = calls.filter(c => c.class === klass)
  const p = percentiles(group.map(c => c.ms))
  console.log(`| ${klass} | ${group.length} | ${of(group, c => c.ms).toFixed(0)} | ${(of(group, c => c.ms) / group.length).toFixed(2)} | ${p.median} | ${p.p95} | ${Math.round(of(group, c => c.visitedNodes) / Math.max(1, group.filter(c => c.visitedNodes !== undefined).length))} |`)
}

const rediscovered = calls.filter(c => c.rediscovered).length
console.log(`\nhandles the facade had lost, and the model was described again: ${rediscovered}`)
writeFileSync(new URL('results/calls.json', import.meta.url), JSON.stringify({ calls: calls.length, routed: routed.length, rows }, null, 1))
