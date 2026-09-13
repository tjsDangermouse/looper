import { useEffect, useMemo, useRef, useState } from 'react'
import * as maplibregl from 'maplibre-gl'
import 'maplibre-gl/dist/maplibre-gl.css'
import maplibreWorkerUrl from 'maplibre-gl/dist/maplibre-gl-worker.mjs?worker&url'
import { applyLooperStyle, mapStyle } from './mapStyle'
import { contains, entryCoordinate, locateEntries, parseRouteDiagnostic, selectionBundle, type Bounds, type DiagnosticEntry, type RouteDiagnostic } from './routeDiagnostics'

maplibregl.setWorkerUrl(maplibreWorkerUrl)

const emptyCollection = () => ({ type: 'FeatureCollection' as const, features: [] as any[] })
const source = (map: maplibregl.Map, id: string) => map.getSource(id) as maplibregl.GeoJSONSource | undefined
const lineFeature = (coordinates: [number, number][], properties: Record<string, unknown> = {}) => ({ type: 'Feature' as const, properties, geometry: { type: 'LineString' as const, coordinates } })
const pointFeature = (coordinate: [number, number], properties: Record<string, unknown>) => ({ type: 'Feature' as const, properties, geometry: { type: 'Point' as const, coordinates: coordinate } })
const formatMetres = (value: number | undefined) => value === undefined ? '—' : value < 1000 ? `${Math.round(value)} m` : `${(value / 1000).toFixed(2)} km`
const clock = (value: string) => new Date(value).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })
const escaped = (value: string) => value.replace(/[&<>"']/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' }[character]!))

function fit(map: maplibregl.Map, coordinates: [number, number][]) {
  if (!coordinates.length) return
  const bounds = coordinates.reduce((box, point) => box.extend(point), new maplibregl.LngLatBounds(coordinates[0], coordinates[0]))
  map.fitBounds(bounds, { padding: 54, duration: 0, maxZoom: 17 })
}

function routeSources(diagnostic: RouteDiagnostic) {
  const route = diagnostic.routeSnapshot
  const planned = route.coordinates.map(point => [point.longitude, point.latitude] as [number, number])
  const located = locateEntries(diagnostic.entries)
  const walked = diagnostic.entries.filter(entry => entry.event === 'location.accepted').map(entryCoordinate).filter((coordinate): coordinate is [number, number] => Boolean(coordinate))
  const rejected = diagnostic.entries.filter(entry => entry.event === 'location.rejected').map(entryCoordinate).filter((coordinate): coordinate is [number, number] => Boolean(coordinate))
  const directions = route.steps.flatMap(step => {
    const point = route.coordinates[step.startCoordinateIndex ?? -1]
    return point ? [pointFeature([point.longitude, point.latitude], { index: step.index, instruction: step.instruction, road: step.road ?? '', roadClass: step.roadClass ?? '', kind: 'direction' })] : []
  })
  const messages = located.flatMap((entry, eventIndex) => entry.event === 'guidance.queued' && entry.coordinate
    ? [pointFeature(entry.coordinate, { eventIndex, text: entry.details.text ?? '', key: entry.details.key ?? '', time: clock(entry.timestamp), kind: 'message' })]
    : [])
  return { planned, walked, rejected, directions, messages }
}

function installLayers(map: maplibregl.Map) {
  map.addSource('diagnostic-planned', { type: 'geojson', data: emptyCollection() })
  map.addSource('diagnostic-walked', { type: 'geojson', data: emptyCollection() })
  map.addSource('diagnostic-rejected', { type: 'geojson', data: emptyCollection() })
  map.addSource('diagnostic-directions', { type: 'geojson', data: emptyCollection() })
  map.addSource('diagnostic-messages', { type: 'geojson', data: emptyCollection() })
  map.addSource('diagnostic-selection', { type: 'geojson', data: emptyCollection() })
  map.addLayer({ id: 'diagnostic-planned', type: 'line', source: 'diagnostic-planned', paint: { 'line-color': '#f0a43a', 'line-width': 7, 'line-opacity': .82 }, layout: { 'line-cap': 'round', 'line-join': 'round' } })
  map.addLayer({ id: 'diagnostic-walked-halo', type: 'line', source: 'diagnostic-walked', paint: { 'line-color': '#ffffff', 'line-width': 6, 'line-opacity': .9 }, layout: { 'line-cap': 'round', 'line-join': 'round' } })
  map.addLayer({ id: 'diagnostic-walked', type: 'line', source: 'diagnostic-walked', paint: { 'line-color': '#168fab', 'line-width': 3 }, layout: { 'line-cap': 'round', 'line-join': 'round' } })
  map.addLayer({ id: 'diagnostic-rejected', type: 'circle', source: 'diagnostic-rejected', paint: { 'circle-radius': 5, 'circle-color': '#c63c3c', 'circle-stroke-width': 2, 'circle-stroke-color': '#fff' } })
  map.addLayer({ id: 'diagnostic-directions', type: 'circle', source: 'diagnostic-directions', paint: { 'circle-radius': 11, 'circle-color': '#101816', 'circle-stroke-width': 2, 'circle-stroke-color': '#f0a43a' } })
  map.addLayer({ id: 'diagnostic-direction-labels', type: 'symbol', source: 'diagnostic-directions', layout: { 'text-field': ['to-string', ['get', 'index']], 'text-size': 10, 'text-font': ['Noto Sans Bold'] }, paint: { 'text-color': '#fff' } })
  map.addLayer({ id: 'diagnostic-messages', type: 'circle', source: 'diagnostic-messages', paint: { 'circle-radius': 6, 'circle-color': '#ed6a5a', 'circle-stroke-width': 2, 'circle-stroke-color': '#fff' } })
  map.addLayer({ id: 'diagnostic-selection-fill', type: 'fill', source: 'diagnostic-selection', paint: { 'fill-color': '#8b73e6', 'fill-opacity': .16 } })
  map.addLayer({ id: 'diagnostic-selection-line', type: 'line', source: 'diagnostic-selection', paint: { 'line-color': '#6f55d9', 'line-width': 2, 'line-dasharray': [2, 2] } })
}

export function RouteDiagnostics() {
  const mapElement = useRef<HTMLDivElement>(null)
  const mapRef = useRef<maplibregl.Map | undefined>(undefined)
  const [diagnostic, setDiagnostic] = useState<RouteDiagnostic>()
  const [error, setError] = useState('')
  const [fileName, setFileName] = useState('')
  const [drawing, setDrawing] = useState(false)
  const drawingRef = useRef(false)
  const dragStart = useRef<maplibregl.LngLat | undefined>(undefined)
  const [selection, setSelection] = useState<Bounds>()
  const [copyState, setCopyState] = useState('Copy selected area for AI')
  const [eventLimit, setEventLimit] = useState(500)

  const located = useMemo(() => diagnostic ? locateEntries(diagnostic.entries) : [], [diagnostic])
  const messagesByStep = useMemo(() => {
    const grouped = new Map<number, DiagnosticEntry[]>()
    for (const entry of diagnostic?.entries ?? []) {
      if (entry.event !== 'guidance.queued') continue
      const keyedIndex = Number(entry.details.key?.split(':')[0])
      const index = Number.isFinite(keyedIndex) ? keyedIndex : entry.details.kind === 'arrival' ? (diagnostic?.routeSnapshot.steps.length ?? 1) - 1 : NaN
      if (Number.isFinite(index)) grouped.set(index, [...(grouped.get(index) ?? []), entry])
    }
    return grouped
  }, [diagnostic])

  useEffect(() => {
    document.body.classList.add('route-diagnostics-body')
    document.title = 'Looper route diagnostics'
    if (!mapElement.current) return
    const map = mapRef.current = new maplibregl.Map({ container: mapElement.current, style: mapStyle.url, center: [-4.48, 54.15], zoom: 13, attributionControl: false })
    map.addControl(new maplibregl.NavigationControl(), 'top-right')
    map.on('load', () => { applyLooperStyle(map); installLayers(map) })
    const popup = new maplibregl.Popup({ closeButton: false, maxWidth: '340px' })
    for (const layer of ['diagnostic-directions', 'diagnostic-messages']) {
      map.on('mouseenter', layer, () => { map.getCanvas().style.cursor = 'pointer' })
      map.on('mouseleave', layer, () => { map.getCanvas().style.cursor = drawingRef.current ? 'crosshair' : '' })
      map.on('click', layer, event => {
        if (drawingRef.current) return
        const feature = event.features?.[0], coordinates = (feature?.geometry as any)?.coordinates
        if (!feature || !coordinates) return
        const properties = feature.properties ?? {}
        const html = properties.kind === 'direction'
          ? `<strong>Direction ${properties.index}</strong><span>${escaped(properties.instruction)}</span>${properties.road || properties.roadClass ? `<small>${escaped([properties.road, properties.roadClass].filter(Boolean).join(' · '))}</small>` : ''}`
          : `<strong>${escaped(properties.time)}</strong><span>${escaped(properties.text)}</span><small>${escaped(properties.key || 'arrival')}</small>`
        popup.setLngLat(coordinates).setHTML(`<div class="diagnostic-popup">${html}</div>`).addTo(map)
      })
    }
    map.on('mousedown', event => {
      if (!drawingRef.current) return
      event.preventDefault(); dragStart.current = event.lngLat; map.dragPan.disable()
    })
    map.on('mousemove', event => {
      if (!drawingRef.current || !dragStart.current) return
      const start = dragStart.current, end = event.lngLat
      updateSelectionSource(map, { west: Math.min(start.lng, end.lng), east: Math.max(start.lng, end.lng), south: Math.min(start.lat, end.lat), north: Math.max(start.lat, end.lat) })
    })
    map.on('mouseup', event => {
      if (!drawingRef.current || !dragStart.current) return
      const start = dragStart.current, end = event.lngLat
      const bounds = { west: Math.min(start.lng, end.lng), east: Math.max(start.lng, end.lng), south: Math.min(start.lat, end.lat), north: Math.max(start.lat, end.lat) }
      dragStart.current = undefined; map.dragPan.enable(); drawingRef.current = false; setDrawing(false); setSelection(bounds)
    })
    return () => { document.body.classList.remove('route-diagnostics-body'); map.remove(); mapRef.current = undefined }
  }, [])

  useEffect(() => {
    const map = mapRef.current
    if (!map || !diagnostic) return
    const update = () => {
      const data = routeSources(diagnostic)
      source(map, 'diagnostic-planned')?.setData({ type: 'FeatureCollection', features: [lineFeature(data.planned)] })
      source(map, 'diagnostic-walked')?.setData({ type: 'FeatureCollection', features: data.walked.length > 1 ? [lineFeature(data.walked)] : [] })
      source(map, 'diagnostic-rejected')?.setData({ type: 'FeatureCollection', features: data.rejected.map(point => pointFeature(point, {})) })
      source(map, 'diagnostic-directions')?.setData({ type: 'FeatureCollection', features: data.directions })
      source(map, 'diagnostic-messages')?.setData({ type: 'FeatureCollection', features: data.messages })
      fit(map, data.planned)
    }
    if (map.isStyleLoaded()) update()
    else map.once('load', update)
  }, [diagnostic])

  const openFile = async (file?: File) => {
    if (!file) return
    try { setDiagnostic(parseRouteDiagnostic(await file.text())); setFileName(file.name); setError(''); setSelection(undefined); setEventLimit(500); setCopyState('Copy selected area for AI') }
    catch (reason) { setError(reason instanceof Error ? reason.message : 'This diagnostic could not be read.'); setDiagnostic(undefined) }
  }

  const beginDrawing = () => {
    const map = mapRef.current
    if (!map || !diagnostic) return
    drawingRef.current = true; setDrawing(true); setSelection(undefined); setCopyState('Copy selected area for AI'); updateSelectionSource(map, undefined); map.getCanvas().style.cursor = 'crosshair'
  }

  const clearSelection = () => { setSelection(undefined); updateSelectionSource(mapRef.current, undefined); setCopyState('Copy selected area for AI') }
  const copySelection = async () => {
    if (!diagnostic || !selection) return
    try { await navigator.clipboard.writeText(JSON.stringify(selectionBundle(diagnostic, selection), null, 2)); setCopyState('Copied diagnostic evidence') }
    catch { setCopyState('Clipboard access was blocked') }
  }

  const route = diagnostic?.routeSnapshot
  const accepted = diagnostic?.entries.filter(entry => entry.event === 'location.accepted') ?? []
  const rejected = diagnostic?.entries.filter(entry => entry.event === 'location.rejected') ?? []
  const guidance = diagnostic?.entries.filter(entry => entry.event === 'guidance.queued') ?? []
  const selectedEventCount = selection ? located.filter(entry => entry.coordinate && contains(selection, entry.coordinate)).length : 0

  return <main className="route-diagnostics">
    <header className="diagnostic-header">
      <a href="/map-style-editor">Looper workshop</a>
      <div><h1>Route evidence</h1><p>Compare the route Looper drew with the ground actually covered and every instruction it fired.</p></div>
      <label className="diagnostic-upload"><input type="file" accept=".json,.txt,application/json,text/plain" onChange={event => openFile(event.target.files?.[0])} /><span>{diagnostic ? 'Open another diagnostic' : 'Open diagnostic'}</span></label>
    </header>

    <section className={`diagnostic-map-shell ${drawing ? 'is-drawing' : ''}`} onDragOver={event => event.preventDefault()} onDrop={event => { event.preventDefault(); openFile(event.dataTransfer.files[0]) }}>
      <div ref={mapElement} className="diagnostic-map" aria-label="Planned and walked route diagnostic map" />
      {!diagnostic && <div className="diagnostic-empty"><strong>Drop a navigation diagnostic here</strong><span>Combined JSON and the iOS text export are supported.</span>{error && <em>{error}</em>}</div>}
      {diagnostic && <>
        <div className="diagnostic-facts">
          <strong>{route?.routeName}</strong>
          <span>{formatMetres(route?.advertisedDistanceMeters)} planned</span>
          <span>{accepted.length.toLocaleString()} GPS fixes</span>
          <span>{guidance.length} messages</span>
        </div>
        <div className="diagnostic-legend"><span className="planned">Planned</span><span className="walked">Walked</span><span className="message">Message</span><span className="direction">Direction</span></div>
        <div className="selection-tools">
          <button type="button" className={drawing ? 'active' : ''} onClick={beginDrawing}>{drawing ? 'Drag across the map…' : 'Highlight an area'}</button>
          {selection && <><button type="button" className="copy" onClick={copySelection}>{copyState}</button><button type="button" onClick={clearSelection}>Clear</button><span>{selectedEventCount} events selected</span></>}
        </div>
      </>}
    </section>

    {diagnostic && <section className="diagnostic-ledger">
      <header><div><h2>Navigation ledger</h2><p>{fileName} · {route?.steps.length} planned directions · {rejected.length} rejected fixes</p></div><span>Click a map marker to inspect it</span></header>
      <div className="diagnostic-table-wrap"><table><thead><tr><th>#</th><th>Planned direction</th><th>At</th><th>Guidance messages fired</th></tr></thead>
        <tbody>{route?.steps.map(step => {
          const messages = messagesByStep.get(step.index) ?? []
          return <tr key={step.index}><td><b>{step.index}</b></td><td><strong>{step.instruction}</strong>{(step.road || step.roadClass) && <small>{[step.road, step.roadClass].filter(Boolean).join(' · ')}</small>}</td><td>{formatMetres(step.cumulativeStartMeters)}</td><td>{messages.length ? <div className="message-list">{messages.map((message, index) => <button type="button" key={`${message.timestamp}-${index}`} onClick={() => {
            const coordinate = locateEntries(diagnostic.entries).find(entry => entry.timestamp === message.timestamp)?.coordinate
            if (coordinate) mapRef.current?.flyTo({ center: coordinate, zoom: 17 })
          }}><time>{clock(message.timestamp)}</time><span>{message.details.text}</span><i>{message.details.key?.split(':')[1] ?? message.details.kind}</i></button>)}</div> : <span className="not-recorded">No retained message</span>}</td></tr>
        })}</tbody></table></div>
      <details className="diagnostic-events">
        <summary><span>Complete event log</span><b>{diagnostic.entries.length.toLocaleString()} retained events</b></summary>
        <div className="diagnostic-table-wrap"><table><thead><tr><th>Time</th><th>Event</th><th>Location</th><th>Recorded details</th></tr></thead>
          <tbody>{located.slice(0, eventLimit).map((entry, index) => <tr key={`${entry.timestamp}-${entry.event}-${index}`} className={selection && entry.coordinate && contains(selection, entry.coordinate) ? 'is-selected' : ''}>
            <td><time>{clock(entry.timestamp)}</time></td><td><code>{entry.event}</code></td>
            <td>{entry.coordinate ? <button type="button" className="event-location" onClick={() => mapRef.current?.flyTo({ center: entry.coordinate!, zoom: 17 })}>{entry.coordinate[1].toFixed(5)}, {entry.coordinate[0].toFixed(5)}</button> : '—'}</td>
            <td><dl>{Object.entries(entry.details).map(([key, value]) => <div key={key}><dt>{key}</dt><dd>{value}</dd></div>)}</dl></td>
          </tr>)}</tbody></table></div>
        {eventLimit < diagnostic.entries.length && <button type="button" className="load-events" onClick={() => setEventLimit(limit => limit + 500)}>Show 500 more events</button>}
      </details>
    </section>}
  </main>
}

function updateSelectionSource(map: maplibregl.Map | undefined, bounds: Bounds | undefined) {
  if (!map) return
  const features = bounds ? [{ type: 'Feature' as const, properties: {}, geometry: { type: 'Polygon' as const, coordinates: [[[bounds.west, bounds.south], [bounds.east, bounds.south], [bounds.east, bounds.north], [bounds.west, bounds.north], [bounds.west, bounds.south]]] } }] : []
  source(map, 'diagnostic-selection')?.setData({ type: 'FeatureCollection', features })
  map.getCanvas().style.cursor = bounds ? '' : map.getCanvas().style.cursor
}
