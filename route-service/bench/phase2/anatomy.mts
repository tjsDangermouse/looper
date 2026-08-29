/**
 * Phase 2 §2, §3, §21: the anatomy of a generation's engine calls.
 *
 * Reads the captured corpus and answers, per request class and per purpose,
 * how many calls there were, what they cost, and how much graph they settled.
 * The point is to find out which class is worth optimising before optimising
 * anything: "avoidance is expensive" is a statement about one call, and the
 * decision needs a statement about the bill.
 */
import { readFileSync, readdirSync } from 'node:fs'
import { percentiles } from '../../src/loops/metrics.js'

type Call = { purpose: string; class: string; points: number; areas: number; areaVertices: number; ms: number; visitedNodes?: number }

const dir = new URL('corpus/', import.meta.url)
const corpus = new Map<string, Call[]>()
for (const file of readdirSync(dir).filter(f => f.endsWith('.jsonl')).sort()) {
  corpus.set(file.replace('.jsonl', ''), readFileSync(new URL(file, dir), 'utf8').trim().split('\n').filter(Boolean).map(l => JSON.parse(l)))
}

const all = [...corpus.values()].flat()
const totalMs = all.reduce((s, c) => s + c.ms, 0)

const table = (title: string, key: (c: Call) => string, calls: Call[], denominator: number) => {
  console.log(`\n### ${title}\n`)
  console.log('| class | calls | total ms | % of engine ms | mean ms | median | p95 | max | visited nodes | mean visited |')
  console.log('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
  const groups = new Map<string, Call[]>()
  for (const call of calls) {
    const k = key(call)
    if (!groups.has(k)) groups.set(k, [])
    groups.get(k)!.push(call)
  }
  const rows = [...groups.entries()].map(([k, group]) => {
    const ms = group.reduce((s, c) => s + c.ms, 0)
    const visited = group.reduce((s, c) => s + (c.visitedNodes ?? 0), 0)
    const p = percentiles(group.map(c => c.ms))
    return { k, n: group.length, ms, visited, ...p }
  }).sort((a, b) => b.ms - a.ms)
  for (const r of rows) {
    console.log(`| ${r.k} | ${r.n} | ${Math.round(r.ms)} | ${((r.ms / denominator) * 100).toFixed(1)}% | ${(r.ms / r.n).toFixed(2)} | ${r.median} | ${r.p95} | ${r.max} | ${r.visited.toLocaleString()} | ${Math.round(r.visited / r.n).toLocaleString()} |`)
  }
  const n = calls.length
  console.log(`| **total** | **${n}** | **${Math.round(calls.reduce((s, c) => s + c.ms, 0))}** | | | | | | **${calls.reduce((s, c) => s + (c.visitedNodes ?? 0), 0).toLocaleString()}** | |`)
}

console.log(`# Looper engine-call anatomy\n`)
console.log(`Six production-probe fixtures, ${all.length} engine calls, ${Math.round(totalMs)} ms of engine wall time in total.`)
console.log(`Wall time is measured at Looper's own call site, so it includes HTTP and JSON on top of the search.`)

table('By request class, all fixtures', c => c.class, all, totalMs)
table('By purpose, all fixtures', c => c.purpose, all, totalMs)
table('By class × purpose', c => `${c.class} / ${c.purpose}`, all, totalMs)

console.log(`\n### Per fixture\n`)
console.log('| fixture | calls | engine ms | plain | avoid-strong | avoid-relaxed | lower-bound |')
console.log('|---|---:|---:|---:|---:|---:|---:|')
for (const [name, calls] of corpus) {
  const ms = calls.reduce((s, c) => s + c.ms, 0)
  const share = (klass: string) => {
    const group = calls.filter(c => c.class === klass)
    return group.length ? `${group.length} / ${Math.round(group.reduce((s, c) => s + c.ms, 0))}ms` : '—'
  }
  console.log(`| ${name} | ${calls.length} | ${Math.round(ms)} | ${share('plain')} | ${share('avoid-strong')} | ${share('avoid-relaxed')} | ${share('lower-bound')} |`)
}

console.log(`\n### Corridor count vs cost (avoidance calls only)\n`)
console.log('| areas | calls | mean ms | mean visited nodes |')
console.log('|---:|---:|---:|---:|')
const avoidance = all.filter(c => c.class.startsWith('avoid'))
const byAreas = new Map<number, Call[]>()
for (const c of avoidance) {
  const bucket = c.areas
  if (!byAreas.has(bucket)) byAreas.set(bucket, [])
  byAreas.get(bucket)!.push(c)
}
for (const [areas, group] of [...byAreas.entries()].sort((a, b) => a[0] - b[0])) {
  const withNodes = group.filter(c => c.visitedNodes !== undefined)
  console.log(`| ${areas} | ${group.length} | ${(group.reduce((s, c) => s + c.ms, 0) / group.length).toFixed(2)} | ${withNodes.length ? Math.round(withNodes.reduce((s, c) => s + c.visitedNodes!, 0) / withNodes.length).toLocaleString() : '—'} |`)
}
