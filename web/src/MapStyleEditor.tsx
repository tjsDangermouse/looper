import { useEffect, useRef, useState } from 'react'
import * as maplibregl from 'maplibre-gl'
import 'maplibre-gl/dist/maplibre-gl.css'
import maplibreWorkerUrl from 'maplibre-gl/dist/maplibre-gl-worker.mjs?worker&url'
import { routeColours } from './lib'
import { applyLooperStyle, looperPalette, mapStyles, type LooperPalette } from './mapStyle'

maplibregl.setWorkerUrl(maplibreWorkerUrl)

const STORAGE_KEY = 'looper-map-style-draft'
type PaletteKey = keyof LooperPalette
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

function savedPalette(): LooperPalette {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? '{}') as Partial<LooperPalette>
    return { ...looperPalette, ...saved }
  } catch {
    return { ...looperPalette }
  }
}

export function MapStyleEditor() {
  const mapContainer = useRef<HTMLDivElement>(null)
  const mapRef = useRef<maplibregl.Map | undefined>(undefined)
  const paletteRef = useRef<LooperPalette>(looperPalette)
  const [palette, setPalette] = useState<LooperPalette>(savedPalette)
  const [copied, setCopied] = useState(false)
  paletteRef.current = palette

  useEffect(() => {
    document.body.classList.add('map-style-editor-body')
    document.title = 'Looper map style editor'
    if (!mapContainer.current) return
    const map = mapRef.current = new maplibregl.Map({
      container: mapContainer.current,
      style: mapStyles.default.url,
      center: [-4.482, 54.151],
      zoom: 14.3,
      attributionControl: false,
    })
    map.addControl(new maplibregl.NavigationControl(), 'top-right')
    map.on('load', () => {
      applyLooperStyle(map, paletteRef.current)
      addPreviewRoutes(map)
    })
    map.on('error', event => console.error('[Looper style editor]', event.error))
    return () => {
      document.body.classList.remove('map-style-editor-body')
      map.remove()
      mapRef.current = undefined
    }
  }, [])

  useEffect(() => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(palette))
    const map = mapRef.current
    if (map?.isStyleLoaded()) applyLooperStyle(map, palette)
  }, [palette])

  const update = (key: PaletteKey, value: string) => setPalette(current => ({ ...current, [key]: value }))
  const reset = () => setPalette({ ...looperPalette })
  const copy = async () => {
    await navigator.clipboard.writeText(JSON.stringify(palette, null, 2))
    setCopied(true)
    window.setTimeout(() => setCopied(false), 1400)
  }

  return <main className="style-editor">
    <div ref={mapContainer} className="style-editor-map" aria-label="Live preview of the Looper map style" />
    <aside className="style-editor-panel">
      <header>
        <p>Looper workshop</p>
        <h1>Map style editor</h1>
        <span>Changes appear on the map immediately and stay in this browser.</span>
      </header>
      <div className="style-editor-fields">
        {editorGroups.map(group => <section key={group.name}>
          <h2>{group.name}</h2>
          {group.fields.map(field => <label className="colour-field" key={field.key}>
            <input type="color" value={palette[field.key]} onChange={event => update(field.key, event.target.value)} />
            <span><b>{field.label}</b><small>{field.note}</small></span>
            <code>{palette[field.key]}</code>
          </label>)}
        </section>)}
      </div>
      <footer>
        <button type="button" className="editor-copy" onClick={copy}>{copied ? 'Copied' : 'Copy palette JSON'}</button>
        <button type="button" className="editor-reset" onClick={reset}>Reset</button>
        <details>
          <summary>View palette JSON</summary>
          <textarea readOnly value={JSON.stringify(palette, null, 2)} onFocus={event => event.currentTarget.select()} />
        </details>
      </footer>
    </aside>
    <div className="route-preview-key"><i />Sample Looper routes</div>
  </main>
}

function addPreviewRoutes(map: maplibregl.Map) {
  if (map.getSource('editor-routes')) return
  const loops = [
    [[-4.493, 54.151], [-4.489, 54.160], [-4.471, 54.158], [-4.467, 54.147], [-4.480, 54.142], [-4.493, 54.151]],
    [[-4.489, 54.150], [-4.481, 54.162], [-4.463, 54.154], [-4.470, 54.141], [-4.489, 54.150]],
    [[-4.496, 54.146], [-4.487, 54.156], [-4.474, 54.154], [-4.466, 54.144], [-4.482, 54.138], [-4.496, 54.146]],
  ]
  map.addSource('editor-routes', {
    type: 'geojson',
    data: {
      type: 'FeatureCollection',
      features: loops.map((coordinates, index) => ({
        type: 'Feature', properties: { colour: routeColours[index] },
        geometry: { type: 'LineString', coordinates },
      })),
    },
  })
  map.addLayer({
    id: 'editor-routes', type: 'line', source: 'editor-routes',
    layout: { 'line-cap': 'round', 'line-join': 'round' },
    paint: { 'line-color': ['get', 'colour'], 'line-width': 7, 'line-opacity': 0.9 },
  })
}
