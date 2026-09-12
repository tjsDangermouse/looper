export type DiagnosticCoordinate = { longitude: number; latitude: number }

export type DiagnosticStep = {
  index: number
  instruction: string
  road?: string
  maneuver?: string
  distanceMeters: number
  cumulativeStartMeters: number
  cumulativeEndMeters: number
  startCoordinateIndex?: number
  endCoordinateIndex?: number
}

export type RouteSnapshot = {
  capturedAt: string
  sessionID: string
  routeID: string
  routeName: string
  routeWasReversed: boolean
  activity: string
  navigationUnit: string
  advertisedDistanceMeters: number
  geometryDistanceMeters: number
  coordinates: DiagnosticCoordinate[]
  steps: DiagnosticStep[]
}

export type DiagnosticEntry = {
  timestamp: string
  event: string
  details: Record<string, string>
}

export type RouteDiagnostic = {
  generatedAt?: string
  routeSnapshot: RouteSnapshot
  entries: DiagnosticEntry[]
}

const textRouteStart = 'ROUTE SNAPSHOT (JSON)\n'
const textRouteEnd = '\nEND ROUTE SNAPSHOT'

function readDetails(source: string) {
  const details: Record<string, string> = {}
  const pattern = /([A-Za-z][A-Za-z0-9]*)=("(?:\\.|[^"\\])*"|\S+)/g
  for (const match of source.matchAll(pattern)) {
    const raw = match[2]
    try { details[match[1]] = raw.startsWith('"') ? JSON.parse(raw) : raw }
    catch { details[match[1]] = raw.slice(1, -1) }
  }
  return details
}

export function parseEventLine(line: string): DiagnosticEntry | undefined {
  const match = line.match(/^(\S+)\s+(\S+)(?:\s+(.*))?$/)
  if (!match || Number.isNaN(Date.parse(match[1]))) return undefined
  return { timestamp: match[1], event: match[2], details: readDetails(match[3] ?? '') }
}

function parseTextExport(source: string): RouteDiagnostic {
  const start = source.indexOf(textRouteStart)
  const end = source.indexOf(textRouteEnd, start)
  if (start < 0 || end < 0) throw new Error('This text export does not contain a route snapshot.')
  const routeSnapshot = JSON.parse(source.slice(start + textRouteStart.length, end)) as RouteSnapshot
  const eventsAt = source.indexOf('\nEVENTS\n', end)
  const entries = eventsAt < 0 ? [] : source.slice(eventsAt + 8).split(/\r?\n/).map(parseEventLine).filter((entry): entry is DiagnosticEntry => Boolean(entry))
  const generatedAt = source.match(/^Generated:\s*(.+)$/m)?.[1]
  return { generatedAt, routeSnapshot, entries }
}

function normaliseJSON(value: unknown): RouteDiagnostic {
  if (!value || typeof value !== 'object') throw new Error('The diagnostic JSON must be an object.')
  const object = value as Record<string, unknown>
  const routeSnapshot = (object.routeSnapshot ?? object.route) as RouteSnapshot | undefined
  const entries = (object.entries ?? object.events) as DiagnosticEntry[] | undefined
  if (!routeSnapshot) throw new Error('The JSON has no routeSnapshot. Upload the combined navigation diagnostic export, not the event-only file.')
  return { generatedAt: object.generatedAt as string | undefined, routeSnapshot, entries: Array.isArray(entries) ? entries : [] }
}

export function parseRouteDiagnostic(source: string): RouteDiagnostic {
  const trimmed = source.trim()
  const diagnostic = trimmed.startsWith('Looper navigation diagnostics')
    ? parseTextExport(source)
    : normaliseJSON(JSON.parse(trimmed))
  if (!Array.isArray(diagnostic.routeSnapshot.coordinates) || diagnostic.routeSnapshot.coordinates.length < 2) {
    throw new Error('The route snapshot needs at least two coordinates.')
  }
  if (!Array.isArray(diagnostic.routeSnapshot.steps)) throw new Error('The route snapshot has no navigation steps.')
  return diagnostic
}

export function numeric(entry: DiagnosticEntry, key: string) {
  const value = Number(entry.details[key])
  return Number.isFinite(value) ? value : undefined
}

export function entryCoordinate(entry: DiagnosticEntry): [number, number] | undefined {
  const longitude = numeric(entry, 'longitude'), latitude = numeric(entry, 'latitude')
  return longitude === undefined || latitude === undefined ? undefined : [longitude, latitude]
}

export type LocatedEntry = DiagnosticEntry & { coordinate?: [number, number] }

export function locateEntries(entries: DiagnosticEntry[]): LocatedEntry[] {
  let lastCoordinate: [number, number] | undefined
  return entries.map(entry => {
    const own = entryCoordinate(entry)
    if (own) lastCoordinate = own
    return { ...entry, coordinate: own ?? lastCoordinate }
  })
}

export type Bounds = { west: number; south: number; east: number; north: number }
export const contains = (bounds: Bounds, coordinate: [number, number]) => coordinate[0] >= bounds.west && coordinate[0] <= bounds.east && coordinate[1] >= bounds.south && coordinate[1] <= bounds.north

export function selectionBundle(diagnostic: RouteDiagnostic, bounds: Bounds) {
  const located = locateEntries(diagnostic.entries)
  const selectedIndices = located.flatMap((entry, index) => entry.coordinate && contains(bounds, entry.coordinate) ? [index] : [])
  const contextIndices = new Set<number>()
  for (const index of selectedIndices) for (let at = Math.max(0, index - 3); at <= Math.min(located.length - 1, index + 3); at++) contextIndices.add(at)
  const route = diagnostic.routeSnapshot
  const coordinateIndices = route.coordinates.flatMap((point, index) => contains(bounds, [point.longitude, point.latitude]) ? [index] : [])
  const coordinateRuns: number[][] = []
  for (const index of coordinateIndices) {
    const run = coordinateRuns[coordinateRuns.length - 1]
    if (!run || index > run[run.length - 1] + 1) coordinateRuns.push([index])
    else run.push(index)
  }
  const routeFragments = coordinateRuns.map(run => ({
    startCoordinateIndex: Math.max(0, run[0] - 1),
    coordinates: route.coordinates.slice(Math.max(0, run[0] - 1), Math.min(route.coordinates.length, run[run.length - 1] + 2)),
  }))
  const stepIndices = new Set(route.steps.filter(step => {
    const point = route.coordinates[step.startCoordinateIndex ?? -1]
    return point && contains(bounds, [point.longitude, point.latitude])
  }).map(step => step.index))
  for (const entry of located) {
    const index = Number(entry.details.key?.split(':')[0])
    if (entry.coordinate && contains(bounds, entry.coordinate) && Number.isFinite(index)) stepIndices.add(index)
  }
  return {
    kind: 'looper-route-diagnostic-selection',
    route: { sessionID: route.sessionID, routeID: route.routeID, routeName: route.routeName, advertisedDistanceMeters: route.advertisedDistanceMeters },
    selectedBounds: bounds,
    plannedRouteFragments: routeFragments,
    navigationSteps: route.steps.filter(step => stepIndices.has(step.index)),
    selectedEvents: located.filter((_, index) => selectedIndices.includes(index)).map(({ coordinate, ...entry }) => ({ ...entry, coordinate })),
    surroundingEvents: located.filter((_, index) => contextIndices.has(index) && !selectedIndices.includes(index)).map(({ coordinate, ...entry }) => ({ ...entry, coordinate })),
  }
}
