// Hand-built GeoJSON walks covering the shapes the scorer exists to tell apart.
// Real ORS output is too noisy to reason about in a test; these are the same
// failures, drawn deliberately.
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import type { RouteInput } from './loopQuality.js'

export type Fixture = RouteInput & { note: string }

export function loadFixture(name: string): Fixture {
  const path = fileURLToPath(new URL(`./fixtures/${name}.geojson`, import.meta.url))
  const feature = JSON.parse(readFileSync(path, 'utf8'))
  const { note, summary, segments, maneuvers } = feature.properties
  return {
    note,
    coordinates: feature.geometry.coordinates,
    distanceMeters: summary.distance,
    durationSeconds: summary.duration,
    legDistances: segments.map((segment: { distance: number }) => segment.distance),
    maneuvers,
  }
}
