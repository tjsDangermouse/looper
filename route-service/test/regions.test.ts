import { describe, expect, it } from 'vitest'
import { graphForLocation, REGION_BOUNDS, type RegionalGraph } from '../src/regions.js'

const graphs = [
  { id: 'isle-of-man' as const, bounds: REGION_BOUNDS['isle-of-man'], graphhopper: {} },
  { id: 'england' as const, bounds: REGION_BOUNDS.england, graphhopper: {} },
] as unknown as RegionalGraph[]

describe('regional graph selection', () => {
  it('selects the Isle of Man graph', () => expect(graphForLocation(graphs, { lng: -4.55, lat: 54.2 })?.id).toBe('isle-of-man'))
  it('selects the England graph', () => expect(graphForLocation(graphs, { lng: -0.13, lat: 51.51 })?.id).toBe('england'))
  it('does not claim unsupported locations', () => expect(graphForLocation(graphs, { lng: 2.35, lat: 48.86 })).toBeUndefined())
})
