import { describe, expect, it } from 'vitest'
import * as maplibregl from 'maplibre-gl'
import './MapView'
import { editorGroups } from './MapStyleEditor'
import { applyLooperStyle, looperPalette, mapStyle, mapStyles } from './mapStyle'

describe('basemap style', () => {
  it('uses the hosted OpenFreeMap vector style', () => {
    expect(mapStyle).toEqual({
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
    expect(mapStyles.default.label).toBe('Default')
    expect(mapStyles.looper.label).toBe('Looper')
    expect(mapStyles.looper.url).toBe(mapStyles.default.url)
  })

  it('keeps the Looper map a daylight style', () => {
    expect(looperPalette.background).toBe('#f4f3ed')
    expect(looperPalette.label).toBe('#334249')
  })

  it('exposes every Looper colour in the local editor', () => {
    const editable = editorGroups.flatMap(group => group.fields.map(field => field.key)).sort()
    expect(editable).toEqual(Object.keys(looperPalette).sort())
  })

  it('makes walking infrastructure prominent and removes noisy POIs', () => {
    const layers = ['background', 'park', 'landcover_wood', 'road_motorway', 'road_minor',
      'road_path_pedestrian', 'poi_r1', 'road_one_way_arrow'].map(id => ({ id }))
    const added: Array<{ id: string; paint?: Record<string, unknown> }> = []
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
    expect(paint).toContainEqual(['road_path_pedestrian', 'line-color', looperPalette.footway])
    expect(layout).toContainEqual(['poi_r1', 'visibility', 'none'])
    expect(added.map(layer => layer.id)).toEqual(['looper-trails', 'looper-footways', 'looper-cycleways'])

    applyLooperStyle(map as never, { ...looperPalette, trail: '#123456' })
    expect(paint).toContainEqual(['looper-trails', 'line-color', '#123456'])
  })
})
