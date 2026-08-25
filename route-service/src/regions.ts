import type { GraphHopperClient } from './graphhopper.js'

export type Bounds = { west: number; south: number; east: number; north: number }
export type RegionalGraph = { id: 'isle-of-man' | 'england'; bounds: Bounds; graphhopper: GraphHopperClient }

// These bounds deliberately overlap neither service. England's box is kept
// inside the England extract rather than pretending Wales or Scotland work.
export const REGION_BOUNDS: Record<RegionalGraph['id'], Bounds> = {
  'isle-of-man': { west: -4.9, south: 54.0, east: -4.25, north: 54.5 },
  england: { west: -5.7, south: 49.8, east: 1.9, north: 55.9 },
}

export function graphForLocation(graphs: RegionalGraph[], start: { lng: number; lat: number }): RegionalGraph | undefined {
  return graphs.find(({ bounds }) => start.lng >= bounds.west && start.lng <= bounds.east && start.lat >= bounds.south && start.lat <= bounds.north)
}
