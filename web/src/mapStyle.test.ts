import { describe, expect, it } from 'vitest'
import * as maplibregl from 'maplibre-gl'
import './MapView'
import { editorGroups } from './MapStyleEditor'
import { applyLooperStyle, looperPalette, mapStyle, mapStyles } from './mapStyle'

describe('basemap style', () => {
  it('uses the hosted OpenFreeMap vector style', () => {
    expect(mapStyle).toEqual({
      id: 'default',
      provider: 'OpenFreeMap',
      name: 'liberty',
      label: 'Default',
      url: 'https://tiles.openfreemap.org/styles/liberty',
    })
  })

  it('does not fall back to the public OpenStreetMap raster service', () => {
    expect(mapStyle.url).not.toContain('tile.openstreetmap.org')
  })

  it('configures the vector-tile worker for the Vite bundle', () => {
    expect(maplibregl.getWorkerUrl()).toContain('maplibre-gl-worker')
  })

  it('offers Default and Looper without changing tile providers', () => {
    expect(mapStyles.map(style => style.label)).toEqual(['Default', 'Looper'])
    expect(mapStyles[1].url).toBe(mapStyles[0].url)
  })

  it('uses valid editable colours for every Looper feature', () => {
    expect(Object.values(looperPalette).every(colour => /^#[0-9a-f]{6}$/i.test(colour))).toBe(true)
  })

  it('exposes every Looper colour in the local editor', () => {
    const editable = editorGroups.flatMap(group => group.fields.map(field => field.key)).sort()
    expect(editable).toEqual(Object.keys(looperPalette).sort())
  })

  it('makes walking infrastructure prominent and removes noisy POIs', () => {
    const layers = ['background', 'park', 'landcover_wood', 'road_motorway', 'road_minor',
      'road_path_pedestrian', 'road_motorway_link_casing', 'poi_r1', 'road_one_way_arrow'].map(id => ({ id }))
    const added: Array<{ id: string; minzoom?: number; paint?: Record<string, unknown> }> = []
    const paint: Array<[string, string, unknown]> = []
    const layout: Array<[string, string, unknown]> = []
    const map = {
      getStyle: () => ({ layers }),
      getLayer: (id: string) => layers.some(layer => layer.id === id) || added.some(layer => layer.id === id),
      setPaintProperty: (id: string, property: string, value: unknown) => paint.push([id, property, value]),
      setLayoutProperty: (id: string, property: string, value: unknown) => layout.push([id, property, value]),
      addLayer: (layer: { id: string; paint?: Record<string, unknown> }) => { added.push(layer) },
    }
    applyLooperStyle(map as never)
    expect(paint).toContainEqual(['road_motorway', 'line-color', looperPalette.motorway])
    expect(paint).toContainEqual(['road_minor', 'line-color', looperPalette.residentialRoad])
    expect(layout).toContainEqual(['road_path_pedestrian', 'visibility', 'none'])
    expect(layout).toContainEqual(['poi_r1', 'visibility', 'none'])
    expect(added.map(layer => layer.id)).toEqual(['looper-trails', 'looper-footways', 'looper-cycleways'])
    const footways = added.find(layer => layer.id === 'looper-footways')!
    expect(footways.minzoom).toBe(14)
    expect(footways.paint?.['line-width']).toEqual(['interpolate', ['linear'], ['zoom'], 14, 0.8, 16, 1.5, 19, 3.5])

    applyLooperStyle(map as never, { ...looperPalette, trail: '#123456' })
    expect(paint).toContainEqual(['looper-trails', 'line-color', '#123456'])
  })
})
