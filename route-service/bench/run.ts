import { mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { generateLoops, type LoopResponse } from '../src/loops/generate.js'
import { RequestMetrics, percentiles, type MetricsSnapshot } from '../src/loops/metrics.js'
import { SCENARIOS, networkFor, type Scenario } from './scenarios.js'
import { withFlags, flagFingerprint, DEFAULT_FLAGS, type AlgorithmFlags } from '../src/loops/flags.js'
import { syntheticEngine } from './network.js'

/**
 * The offline benchmark.
 *
 *   npm run bench                      run every scenario, print the table
 *   npm run bench -- --save baseline   write the run to bench/results/<name>.json
 *   npm run bench -- --compare baseline  diff this run against a saved one
 *   npm run bench -- --only urban,rural  run a subset by id substring
 *   npm run bench -- --repeats 3       repeat each scenario, for wall-clock stability
 *   npm run bench -- --flags edgeOverlap,localRepair   switch algorithm phases on
 *   npm run bench -- --flags none          every phase off, whatever ships
 *   npm run bench -- --flags !edgeOverlap  everything that ships, minus one
 *
 * A run records which flags it was taken under, so a saved baseline can never
 * be quietly compared against a run of a different algorithm.
 *
 * Route quality and engine-call counts here are exact and reproducible: the
 * network is synthetic and the search is deterministic, so a difference in
 * calls or in metres is a real difference in the algorithm. Wall-clock timings
 * are *not* comparable across machines and only mean something within one run.
 */

const here = dirname(fileURLToPath(import.meta.url))
const RESULTS_DIR = join(here, 'results')

type ScenarioResult = {
  id: string
  about: string
  network: string
  routesOffered: number
  /** True when the scenario produced what it was supposed to produce. */
  valid: boolean
  warning: string | undefined
  expectationExceeded: boolean
  engineCalls: number
  callsByPurpose: Record<string, number>
  nodesVisited: number
  wallMs: number
  metrics: MetricsSnapshot
}

type BenchRun = {
  label: string
  at: string
  flags: string
  scenarios: ScenarioResult[]
  totals: {
    scenarios: number
    validScenarios: number
    validRoutePercent: number
    engineCalls: number
    routesOffered: number
    medianWallMs: number
    p95WallMs: number
  }
}

async function runScenario(scenario: Scenario, repeats: number, flags: AlgorithmFlags): Promise<ScenarioResult> {
  let last: { response: LoopResponse; metrics: RequestMetrics; calls: number; nodes: number; ms: number } | undefined
  const wallTimes: number[] = []
  for (let repeat = 0; repeat < repeats; repeat++) {
    const engine = syntheticEngine(networkFor(scenario))
    const metrics = new RequestMetrics()
    const began = performance.now()
    const response = await generateLoops(scenario.request, {
      route: engine.route,
      reachFrom: engine.reachFrom,
      candidateCount: 24,
      concurrency: Number(argument('concurrency') ?? 6),
      metrics,
      flags,
    })
    const ms = performance.now() - began
    wallTimes.push(ms)
    last = { response, metrics, calls: engine.stats.calls, nodes: engine.stats.nodesVisited, ms }
  }
  const { response, metrics, calls, nodes } = last!
  const snapshot = metrics.snapshot()
  const offered = response.routes.length
  return {
    id: scenario.id,
    about: scenario.about,
    network: scenario.network,
    routesOffered: offered,
    valid: scenario.expectsNoRoutes ? offered === 0 : offered > 0,
    warning: response.warning,
    expectationExceeded: response.expectationExceeded === true,
    engineCalls: calls,
    callsByPurpose: Object.fromEntries(Object.entries(snapshot.callsByPurpose).filter(([, count]) => count > 0)),
    nodesVisited: nodes,
    wallMs: Math.round(percentiles(wallTimes).median),
    metrics: snapshot,
  }
}

function summarise(label: string, scenarios: ScenarioResult[], flags: AlgorithmFlags): BenchRun {
  const wall = scenarios.map(result => result.wallMs)
  const stats = percentiles(wall)
  const valid = scenarios.filter(result => result.valid).length
  return {
    label,
    at: new Date().toISOString(),
    flags: flagFingerprint(flags),
    scenarios,
    totals: {
      scenarios: scenarios.length,
      validScenarios: valid,
      validRoutePercent: Number(((valid / Math.max(1, scenarios.length)) * 100).toFixed(1)),
      engineCalls: scenarios.reduce((sum, result) => sum + result.engineCalls, 0),
      routesOffered: scenarios.reduce((sum, result) => sum + result.routesOffered, 0),
      medianWallMs: stats.median,
      p95WallMs: stats.p95,
    },
  }
}

function table(run: BenchRun): string {
  const rows = run.scenarios.map(result => {
    const offered = result.metrics.offered
    return [
      result.id,
      `${result.routesOffered}/3`,
      result.valid ? 'ok' : 'MISS',
      String(result.engineCalls),
      `${result.wallMs}ms`,
      offered && offered.count ? `${offered.medianDistanceErrorPercent}%` : '-',
      offered && offered.count ? `${offered.maxRepeatedPercent}%` : '-',
      offered && offered.count
        ? `${offered.maxPairSharedPercent}%${offered.maxPairSharedEdgePercent === undefined ? '' : ` / ${offered.maxPairSharedEdgePercent}%`}`
        : '-',
      result.metrics.fallbackRetracing ? 'yes' : 'no',
    ]
  })
  const header = ['scenario', 'routes', 'valid', 'gh calls', 'wall', 'dist err', 'retrace', 'pair shared geom/edge', 'fallback']
  const widths = header.map((cell, column) => Math.max(cell.length, ...rows.map(row => row[column].length)))
  const line = (cells: string[]) => cells.map((cell, column) => cell.padEnd(widths[column])).join('  ')
  return [line(header), line(widths.map(width => '-'.repeat(width))), ...rows.map(line)].join('\n')
}

function compare(current: BenchRun, previous: BenchRun): string {
  const before = new Map(previous.scenarios.map(result => [result.id, result]))
  const rows: string[][] = []
  for (const result of current.scenarios) {
    const was = before.get(result.id)
    if (!was) { rows.push([result.id, 'new', '-', '-', '-']); continue }
    rows.push([
      result.id,
      `${was.routesOffered} -> ${result.routesOffered}`,
      `${was.engineCalls} -> ${result.engineCalls}`,
      signed(result.engineCalls - was.engineCalls),
      `${was.wallMs} -> ${result.wallMs}ms`,
    ])
  }
  const header = ['scenario', 'routes', 'gh calls', 'delta', 'wall']
  const widths = header.map((cell, column) => Math.max(cell.length, ...rows.map(row => row[column].length)))
  const line = (cells: string[]) => cells.map((cell, column) => cell.padEnd(widths[column])).join('  ')
  return [
    `Comparing against "${previous.label}" (${previous.at}, flags: ${previous.flags ?? 'none'})`,
    line(header),
    line(widths.map(width => '-'.repeat(width))),
    ...rows.map(line),
    '',
    `engine calls: ${previous.totals.engineCalls} -> ${current.totals.engineCalls} (${signed(current.totals.engineCalls - previous.totals.engineCalls)})`,
    `valid scenarios: ${previous.totals.validScenarios} -> ${current.totals.validScenarios}`,
    `routes offered: ${previous.totals.routesOffered} -> ${current.totals.routesOffered}`,
  ].join('\n')
}

const signed = (value: number) => (value > 0 ? `+${value}` : String(value))

function argument(name: string): string | undefined {
  const index = process.argv.indexOf(`--${name}`)
  return index >= 0 ? process.argv[index + 1] : undefined
}

/**
 * Flags start from what actually ships, so a bare run measures production.
 * `none` clears them, and `!name` turns one off — comparing today's default
 * against today's default minus one change is the question that comes up most.
 */
function parseFlags(): AlgorithmFlags {
  const named = argument('flags')?.split(',').map(part => part.trim()).filter(Boolean) ?? []
  const known = Object.keys(DEFAULT_FLAGS) as Array<keyof AlgorithmFlags>
  let chosen: Partial<AlgorithmFlags> = { ...DEFAULT_FLAGS }
  for (const name of named) {
    if (name.toLowerCase() === 'none') {
      chosen = Object.fromEntries(known.map(flag => [flag, false])) as AlgorithmFlags
      continue
    }
    const off = name.startsWith('!') || name.startsWith('-')
    const bare = off ? name.slice(1) : name
    const match = known.find(candidate => candidate.toLowerCase() === bare.toLowerCase())
    if (!match) throw new Error(`Unknown flag "${bare}". Known flags: ${known.join(', ')}`)
    chosen[match] = !off
  }
  return withFlags(chosen)
}

async function main() {
  const flags = parseFlags()
  const only = argument('only')?.split(',').map(part => part.trim()).filter(Boolean)
  const repeats = Math.max(1, Number(argument('repeats') ?? 1))
  const label = argument('save') ?? argument('label') ?? 'run'
  const selected = only?.length
    ? SCENARIOS.filter(scenario => only.some(part => scenario.id.includes(part)))
    : SCENARIOS

  const results: ScenarioResult[] = []
  for (const scenario of selected) {
    process.stderr.write(`  ${scenario.id} ... `)
    const result = await runScenario(scenario, repeats, flags)
    process.stderr.write(`${result.routesOffered} routes, ${result.engineCalls} calls, ${result.wallMs}ms\n`)
    results.push(result)
  }

  const run = summarise(label, results, flags)
  console.log('')
  console.log(`flags: ${run.flags}`)
  console.log(table(run))
  console.log('')
  console.log(`${run.totals.validScenarios}/${run.totals.scenarios} scenarios valid  ·  ${run.totals.engineCalls} engine calls  ·  median ${run.totals.medianWallMs}ms  ·  p95 ${run.totals.p95WallMs}ms`)

  const compareTo = argument('compare')
  if (compareTo) {
    const path = join(RESULTS_DIR, `${compareTo}.json`)
    if (!existsSync(path)) {
      console.error(`\nNo saved run called "${compareTo}" in bench/results.`)
      process.exitCode = 1
    } else {
      console.log('')
      console.log(compare(run, JSON.parse(readFileSync(path, 'utf8')) as BenchRun))
    }
  }

  if (argument('save')) {
    mkdirSync(RESULTS_DIR, { recursive: true })
    const path = join(RESULTS_DIR, `${label}.json`)
    writeFileSync(path, `${JSON.stringify(run, null, 2)}\n`)
    console.log(`\nSaved to ${path}`)
  }
}

main().catch(error => {
  console.error(error)
  process.exit(1)
})
