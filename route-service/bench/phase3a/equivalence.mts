/**
 * Phase 3A §24: the gate every retained change has to pass.
 *
 * All 1,863 real calls are replayed twice — once carrying the model in the
 * body as they always have, once naming it with a handle — and the two answers
 * are fingerprinted. The fingerprint is over the full `edge_id` sequence, not
 * over a distance or a geometry hash, because that is what says the two
 * searches agreed on the same physical pieces of network rather than merely on
 * a length. Distance, weight, time, the snapped waypoints and the settled-node
 * count are compared alongside, since a fingerprint that matched on edges but
 * not on weight would mean the weighting had changed under us.
 *
 * Any difference is a bug until it is explained. There is no tolerance here.
 */
import { createHash } from 'node:crypto'
import { readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { buildRouteBody } from '../../src/graphhopper.js'
import { identify } from '../../src/boundary.js'

const GH_URL = process.env.GH_URL ?? 'http://localhost:8991'
const dir = new URL('../phase2/corpus/', import.meta.url)

type Call = { purpose: string; class: string; points: [number, number][]; model: any }
const byFixture = readdirSync(dir).filter(f => f.endsWith('.jsonl')).sort().map(file => ({
  fixture: file.replace('.jsonl', ''),
  calls: readFileSync(new URL(file, dir), 'utf8').trim().split('\n').filter(Boolean)
    .map(line => JSON.parse(line) as Call).filter(call => call.points),
}))

const post = async (body: unknown) => {
  const response = await fetch(new URL('/route', GH_URL), {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
  })
  return { status: response.status, payload: (await response.json()) as any }
}

/** Everything about an answer that could differ if the routing had differed. */
const identityOf = ({ status, payload }: { status: number; payload: any }) => {
  const path = payload?.paths?.[0]
  if (!path) return `status=${status}|${payload?.message ?? ''}`
  return JSON.stringify({
    distance: path.distance,
    weight: path.weight,
    time: path.time,
    points: path.points,
    snapped: payload.snapped_waypoints ?? path.snapped_waypoints ?? null,
    edges: path.details?.edge_id ?? null,
    streets: path.details?.street_name ?? null,
    roadClasses: path.details?.road_class ?? null,
    instructions: (path.instructions ?? []).map((i: any) => [i.sign, i.distance, i.interval?.[0], i.interval?.[1], i.street_name]),
    visited: payload.hints?.['visited_nodes.sum'] ?? null,
  })
}

const fingerprints = { body: createHash('sha256'), handle: createHash('sha256') }
let compared = 0
const differing: Array<{ fixture: string; index: number; purpose: string }> = []

for (const { fixture, calls } of byFixture) {
  const generation = ((await (await fetch(new URL('/generation', GH_URL), { method: 'POST' })).json()) as any).generation
  const sentAreas = new Set<string>()
  const sentModels = new Set<string>()
  for (let index = 0; index < calls.length; index++) {
    const call = calls[index]
    const viaBody = await post(buildRouteBody(call.points, { profile: 'foot', customModel: call.model ?? undefined }))

    const identity = identify(call.model ?? undefined)
    let handle: any
    if (identity) {
      const register: Record<string, unknown> = {}
      identity.areaIds.forEach((areaId, position) => {
        if (!sentAreas.has(areaId)) { register[areaId] = identity.areas[position]; sentAreas.add(areaId) }
      })
      handle = sentModels.has(identity.id) ? { generation, id: identity.id } : {
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
    const viaHandle = await post(buildRouteBody(call.points, {
      profile: 'foot',
      customModel: handle ? undefined : (call.model ?? undefined),
      modelHandle: handle,
    }))

    const a = identityOf(viaBody)
    const b = identityOf(viaHandle)
    fingerprints.body.update(a)
    fingerprints.handle.update(b)
    compared++
    if (a !== b) differing.push({ fixture, index, purpose: call.purpose })
  }
  await fetch(new URL(`/generation/${generation}`, GH_URL), { method: 'DELETE' })
}

const body = fingerprints.body.digest('hex').slice(0, 16)
const handle = fingerprints.handle.digest('hex').slice(0, 16)
console.log(`compared          ${compared} calls`)
console.log(`model in the body ${body}`)
console.log(`model by handle   ${handle}`)
console.log(differing.length
  ? `DIFFER on ${differing.length}: ${differing.slice(0, 10).map(d => `${d.fixture}#${d.index} (${d.purpose})`).join(', ')}`
  : 'path-identical: every call agreed on distance, weight, time, geometry, edge ids, details, instructions and settled nodes')
writeFileSync(new URL('results/equivalence.json', import.meta.url), JSON.stringify({ compared, body, handle, differing }, null, 1))
