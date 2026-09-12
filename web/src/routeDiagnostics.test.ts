import { describe, expect, it } from 'vitest'
import { parseEventLine, parseRouteDiagnostic, selectionBundle, type RouteDiagnostic } from './routeDiagnostics'

const snapshot = { capturedAt: '2026-01-01T10:00:00Z', sessionID: 'session', routeID: 'route', routeName: 'Test loop', routeWasReversed: false, activity: 'walking', navigationUnit: 'km', advertisedDistanceMeters: 100, geometryDistanceMeters: 100, coordinates: [{ longitude: -4.5, latitude: 54.1 }, { longitude: -4.49, latitude: 54.11 }], steps: [{ index: 0, instruction: 'Set off', distanceMeters: 100, cumulativeStartMeters: 0, cumulativeEndMeters: 100, startCoordinateIndex: 0, endCoordinateIndex: 1 }] }

describe('route diagnostics', () => {
  it('parses quoted event details', () => {
    expect(parseEventLine('2026-01-01T10:01:00.000Z guidance.queued key="2:near" text="In 50 metres, turn left"')?.details).toEqual({ key: '2:near', text: 'In 50 metres, turn left' })
  })

  it('opens the iOS text export', () => {
    const value = parseRouteDiagnostic(`Looper navigation diagnostics\nGenerated: 2026-01-01T11:00:00Z\n\nROUTE SNAPSHOT (JSON)\n${JSON.stringify(snapshot)}\nEND ROUTE SNAPSHOT\n\nEVENTS\n2026-01-01T10:01:00.000Z location.accepted latitude="54.105" longitude="-4.495"\n`)
    expect(value.routeSnapshot.routeName).toBe('Test loop')
    expect(value.entries).toHaveLength(1)
  })

  it('exports selected evidence with nearby context', () => {
    const diagnostic: RouteDiagnostic = { routeSnapshot: snapshot, entries: [
      { timestamp: '2026-01-01T10:00:00Z', event: 'location.accepted', details: { latitude: '54.105', longitude: '-4.495' } },
      { timestamp: '2026-01-01T10:00:01Z', event: 'guidance.queued', details: { key: '0:near', text: 'Turn left' } },
    ] }
    const bundle = selectionBundle(diagnostic, { west: -4.496, east: -4.494, south: 54.104, north: 54.106 })
    expect(bundle.selectedEvents).toHaveLength(2)
    expect(bundle.route.routeName).toBe('Test loop')
  })
})
