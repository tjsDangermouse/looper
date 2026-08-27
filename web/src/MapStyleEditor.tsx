import { useEffect, useMemo, useRef, useState } from 'react'
import * as maplibregl from 'maplibre-gl'
import 'maplibre-gl/dist/maplibre-gl.css'
import maplibreWorkerUrl from 'maplibre-gl/dist/maplibre-gl-worker.mjs?worker&url'
import { customMapStyles, routeColours as generatedRouteColours } from './mapStyleConfig.generated'
import { applyLooperStyle, mapStyle } from './mapStyle'
import type { CustomMapStyle, MapPalette, MapStyleCatalogue, PaletteKey } from './mapStyleTypes'

maplibregl.setWorkerUrl(maplibreWorkerUrl)

const endpoint = '/__looper-style-editor/config'
type Group = { name: string; fields: Array<{ key: PaletteKey; label: string; note: string }> }

export const editorGroups: Group[] = [
  { name: 'Ground', fields: [
    { key: 'background', label: 'Map ground', note: 'Base land colour' },
    { key: 'residential', label: 'Residential land', note: 'Built-up areas' },
    { key: 'water', label: 'Water', note: 'Sea, lakes and rivers' },
    { key: 'waterLine', label: 'Water lines', note: 'Streams and narrow rivers' },
    { key: 'park', label: 'Parks', note: 'Public green space' },
    { key: 'parkOutline', label: 'Park edge', note: 'Green-space boundary' },
    { key: 'woodland', label: 'Woodland', note: 'Tree-covered land' },
    { key: 'building', label: 'Buildings', note: 'Building footprints' },
  ] },
  { name: 'Roads', fields: [
    { key: 'motorway', label: 'Motorway', note: 'Motorways and links' },
    { key: 'mainRoad', label: 'Main road', note: 'Primary to tertiary roads' },
    { key: 'residentialRoad', label: 'Residential street', note: 'Local streets' },
    { key: 'serviceRoad', label: 'Service road', note: 'Access roads and tracks' },
    { key: 'casing', label: 'Road edge', note: 'Outline around every road' },
  ] },
  { name: 'Active travel', fields: [
    { key: 'footway', label: 'Footway', note: 'Pavements, steps and pedestrian ways' },
    { key: 'trail', label: 'Trail / path', note: 'Dashed rural paths and tracks' },
    { key: 'cycleway', label: 'Cycleway', note: 'Dedicated cycle routes' },
  ] },
  { name: 'Labels', fields: [
    { key: 'label', label: 'Label text', note: 'Place, water and road names' },
    { key: 'labelHalo', label: 'Label halo', note: 'Contrast behind label text' },
  ] },
]

const initialCatalogue: MapStyleCatalogue = {
  version: 1,
  styles: customMapStyles.map(style => ({ ...style, palette: { ...style.palette } })),
  routeColours: [...generatedRouteColours],
}

const loops = [
  [[-4.493, 54.151], [-4.489, 54.160], [-4.471, 54.158], [-4.467, 54.147], [-4.480, 54.142], [-4.493, 54.151]],
  [[-4.489, 54.150], [-4.481, 54.162], [-4.463, 54.154], [-4.470, 54.141], [-4.489, 54.150]],
  [[-4.496, 54.146], [-4.487, 54.156], [-4.474, 54.154], [-4.466, 54.144], [-4.482, 54.138], [-4.496, 54.146]],
]
const routeData = (colours: string[]) => ({ type: 'FeatureCollection' as const, features: loops.map((coordinates, index) => ({ type: 'Feature' as const, properties: { colour: colours[index % colours.length] }, geometry: { type: 'LineString' as const, coordinates } })) })
const nextID = (styles: CustomMapStyle[], base = 'new-style') => { let candidate = base, suffix = 2; while (styles.some(style => style.id === candidate)) candidate = `${base}-${suffix++}`; return candidate }

export function MapStyleEditor() {
  const mapContainer = useRef<HTMLDivElement>(null)
  const mapRef = useRef<maplibregl.Map | undefined>(undefined)
  const activePaletteRef = useRef<MapPalette>(initialCatalogue.styles[0].palette)
  const routeColoursRef = useRef(initialCatalogue.routeColours)
  const [catalogue, setCatalogue] = useState(initialCatalogue)
  const [saved, setSaved] = useState(JSON.stringify(initialCatalogue))
  const [activeID, setActiveID] = useState(initialCatalogue.styles[0].id)
  const [status, setStatus] = useState('Loading styles…')
  const [saving, setSaving] = useState(false)
  const active = catalogue.styles.find(style => style.id === activeID) ?? catalogue.styles[0]
  activePaletteRef.current = active.palette
  routeColoursRef.current = catalogue.routeColours
  const dirty = useMemo(() => JSON.stringify(catalogue) !== saved, [catalogue, saved])

  useEffect(() => {
    fetch(endpoint).then(async response => {
      const body = await response.json()
      if (!response.ok) throw new Error(body.error ?? 'Could not load styles.')
      const loaded = body as MapStyleCatalogue
      setCatalogue(loaded)
      setSaved(JSON.stringify(loaded))
      setActiveID(current => loaded.styles.some(style => style.id === current) ? current : loaded.styles[0].id)
      setStatus('All files are in sync')
    }).catch(error => setStatus(error instanceof Error ? error.message : 'Could not load styles.'))
  }, [])

  useEffect(() => {
    document.body.classList.add('map-style-editor-body')
    document.title = 'Looper map style editor'
    if (!mapContainer.current) return
    const map = mapRef.current = new maplibregl.Map({ container: mapContainer.current, style: mapStyle.url, center: [-4.482, 54.151], zoom: 14.3, attributionControl: false })
    map.addControl(new maplibregl.NavigationControl(), 'top-right')
    map.on('load', () => {
      applyLooperStyle(map, activePaletteRef.current)
      map.addSource('editor-routes', { type: 'geojson', data: routeData(routeColoursRef.current) })
      map.addLayer({ id: 'editor-routes', type: 'line', source: 'editor-routes', layout: { 'line-cap': 'round', 'line-join': 'round' }, paint: { 'line-color': ['get', 'colour'], 'line-width': 7, 'line-opacity': 0.9 } })
    })
    map.on('error', event => console.error('[Looper style editor]', event.error))
    return () => { document.body.classList.remove('map-style-editor-body'); map.remove(); mapRef.current = undefined }
  }, [])

  useEffect(() => { const map = mapRef.current; if (map?.isStyleLoaded()) applyLooperStyle(map, active.palette) }, [active])
  useEffect(() => { (mapRef.current?.getSource('editor-routes') as maplibregl.GeoJSONSource | undefined)?.setData(routeData(catalogue.routeColours)) }, [catalogue.routeColours])

  const updateActive = (change: (style: CustomMapStyle) => CustomMapStyle) => setCatalogue(current => ({ ...current, styles: current.styles.map(style => style.id === activeID ? change(style) : style) }))
  const updateColour = (key: PaletteKey, value: string) => updateActive(style => ({ ...style, palette: { ...style.palette, [key]: value } }))
  const updateRoute = (index: number, value: string) => setCatalogue(current => ({ ...current, routeColours: current.routeColours.map((colour, position) => position === index ? value : colour) }))
  const createStyle = () => { const id = nextID(catalogue.styles); setCatalogue(current => ({ ...current, styles: [...current.styles, { id, name: 'New style', palette: { ...active.palette } }] })); setActiveID(id) }
  const duplicateStyle = () => { const id = nextID(catalogue.styles, `${active.id}-copy`); setCatalogue(current => ({ ...current, styles: [...current.styles, { id, name: `${active.name} copy`, palette: { ...active.palette } }] })); setActiveID(id) }
  const deleteStyle = () => {
    if (catalogue.styles.length === 1 || !window.confirm(`Delete “${active.name}”? This takes effect when you save.`)) return
    const index = catalogue.styles.findIndex(style => style.id === active.id), remaining = catalogue.styles.filter(style => style.id !== active.id)
    setCatalogue(current => ({ ...current, styles: remaining })); setActiveID(remaining[Math.min(index, remaining.length - 1)].id)
  }
  const save = async () => {
    setSaving(true); setStatus('Writing web and iOS files…')
    try {
      const response = await fetch(endpoint, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(catalogue) })
      const body = await response.json()
      if (!response.ok) throw new Error(body.error ?? 'Could not save styles.')
      const persisted = body as MapStyleCatalogue
      setCatalogue(persisted); setSaved(JSON.stringify(persisted)); setStatus(`Saved to web and iOS at ${new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`)
    } catch (error) { setStatus(`Save failed: ${error instanceof Error ? error.message : 'Could not save styles.'}`) } finally { setSaving(false) }
  }

  return <main className="style-editor">
    <div ref={mapContainer} className="style-editor-map" aria-label={`Live preview of ${active.name}`} />
    <aside className="style-editor-panel">
      <header className="editor-header"><div><p>Looper workshop</p><h1>Style manager</h1></div><button type="button" className="editor-save" disabled={!dirty || saving} onClick={save}>{saving ? 'Saving…' : dirty ? 'Save to apps' : 'Saved'}</button><span className={dirty ? 'dirty' : ''}>{status.startsWith('Save failed:') ? status : dirty ? 'Unsaved changes' : status}</span></header>
      <section className="style-catalogue">
        <label><span>Map style</span><select value={active.id} onChange={event => setActiveID(event.target.value)}>{catalogue.styles.map(style => <option key={style.id} value={style.id}>{style.name}</option>)}</select></label>
        <div className="catalogue-actions"><button type="button" onClick={createStyle}>New</button><button type="button" onClick={duplicateStyle}>Duplicate</button><button type="button" disabled={catalogue.styles.length === 1} onClick={deleteStyle}>Delete</button></div>
        <div className="style-identity"><label><span>Display name</span><input value={active.name} maxLength={40} onChange={event => updateActive(style => ({ ...style, name: event.target.value }))} /></label><label><span>Style ID</span><input value={active.id} maxLength={32} spellCheck={false} onChange={event => { const id = event.target.value.toLowerCase().replace(/[^a-z0-9-]/g, ''); updateActive(style => ({ ...style, id })); setActiveID(id) }} /></label></div>
      </section>
      <div className="style-editor-fields">
        {editorGroups.map(group => <section key={group.name}><h2>{group.name}</h2>{group.fields.map(field => <label className="colour-field" key={field.key}><input type="color" value={active.palette[field.key]} onChange={event => updateColour(field.key, event.target.value)} /><span><b>{field.label}</b><small>{field.note}</small></span><code>{active.palette[field.key]}</code></label>)}</section>)}
        <section className="route-colours"><div className="section-heading"><h2>Route options</h2><button type="button" disabled={catalogue.routeColours.length >= 8} onClick={() => setCatalogue(current => ({ ...current, routeColours: [...current.routeColours, '#8d70c9'] }))}>Add colour</button></div><p>Used for route lines and the matching choice cards in both apps.</p>{catalogue.routeColours.map((colour, index) => <label className="colour-field" key={index}><input type="color" value={colour} onChange={event => updateRoute(index, event.target.value)} /><span><b>Route {index + 1}</b><small>Option colour</small></span><code>{colour}</code><button type="button" aria-label={`Remove route ${index + 1} colour`} disabled={catalogue.routeColours.length === 1} onClick={() => setCatalogue(current => ({ ...current, routeColours: current.routeColours.filter((_, position) => position !== index) }))}>×</button></label>)}</section>
      </div>
    </aside>
    <div className="route-preview-key"><span>{catalogue.routeColours.map((colour, index) => <i key={index} style={{ background: colour }} />)}</span>Sample route options</div>
  </main>
}
