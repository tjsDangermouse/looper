import type { LineLayerSpecification, Map } from 'maplibre-gl'
import { customMapStyles } from './mapStyleConfig.generated'
import type { MapPalette } from './mapStyleTypes'

export type MapStyleID = string

const libertyURL = 'https://tiles.openfreemap.org/styles/liberty'

export const mapStyles = [
  { id: 'default', provider: 'OpenFreeMap', name: 'liberty', label: 'Default', url: libertyURL },
  ...customMapStyles.map(style => ({ id: style.id, provider: 'OpenFreeMap', name: style.id, label: style.name, url: libertyURL, palette: style.palette })),
]

// Kept for callers that only need the unmodified basemap URL.
export const mapStyle = mapStyles[0]

export type LooperPalette = MapPalette
export const looperPalette = customMapStyles[0].palette
export const customMapStyle = (id: MapStyleID) => customMapStyles.find(style => style.id === id)

type StyleMap = Pick<Map, 'addLayer' | 'getLayer' | 'getStyle' | 'setLayoutProperty' | 'setPaintProperty'>

const setPaint = (map: StyleMap, ids: string[], property: string, value: unknown) => {
  for (const id of ids) if (map.getLayer(id)) map.setPaintProperty(id, property as never, value as never)
}

const lineIDs = (map: StyleMap, pattern: RegExp) =>
  (map.getStyle().layers ?? []).map(layer => layer.id).filter(id => pattern.test(id))

/** Apply Looper's walk-first visual hierarchy to OpenFreeMap Liberty. */
export function applyLooperStyle(map: StyleMap, palette: LooperPalette = looperPalette) {
  setPaint(map, ['background'], 'background-color', palette.background)
  setPaint(map, ['landuse_residential'], 'fill-color', palette.residential)
  setPaint(map, ['park'], 'fill-color', palette.park)
  setPaint(map, ['park_outline'], 'line-color', palette.parkOutline)
  setPaint(map, ['landcover_wood'], 'fill-color', palette.woodland)
  setPaint(map, ['landcover_grass', 'landcover_grass_park'], 'fill-color', palette.park)
  setPaint(map, ['water'], 'fill-color', palette.water)
  setPaint(map, ['waterway'], 'line-color', palette.waterLine)
  setPaint(map, ['building'], 'fill-color', palette.building)
  setPaint(map, ['building-3d'], 'fill-extrusion-color', palette.building)

  const casing = lineIDs(map, /_casing$/)
  setPaint(map, casing, 'line-color', palette.casing)
  setPaint(map, casing, 'line-opacity', 0.72)

  const motorway = lineIDs(map, /^(road|bridge|tunnel)_motorway(_link)?$/)
  setPaint(map, motorway, 'line-color', palette.motorway)
  setPaint(map, motorway, 'line-opacity', 0.72)

  const main = lineIDs(map, /^(road|bridge|tunnel)_(trunk_primary|secondary_tertiary|link)$/)
  setPaint(map, main, 'line-color', palette.mainRoad)
  setPaint(map, main, 'line-opacity', 0.88)

  const residential = lineIDs(map, /^(road|bridge|tunnel)_(minor|street)$/)
  setPaint(map, residential, 'line-color', palette.residentialRoad)
  setPaint(map, residential, 'line-opacity', 0.96)

  const service = lineIDs(map, /^(road|bridge|tunnel)_service_track$/)
  setPaint(map, service, 'line-color', palette.serviceRoad)
  setPaint(map, service, 'line-opacity', 0.9)

  const paths = lineIDs(map, /^(road|bridge|tunnel)_path_pedestrian$/)
  setPaint(map, paths, 'line-color', palette.footway)
  setPaint(map, paths, 'line-opacity', 1)

  for (const id of ['poi_r20', 'poi_r7', 'poi_r1']) {
    if (map.getLayer(id)) map.setLayoutProperty(id, 'visibility', 'none')
  }
  setPaint(map, ['poi_transit'], 'text-opacity', 0.5)
  setPaint(map, ['poi_transit'], 'icon-opacity', 0.5)

  const labelIDs = (map.getStyle().layers ?? []).map(layer => layer.id)
    .filter(id => /(_label|place_|highway-name|water_name)/.test(id))
  setPaint(map, labelIDs, 'text-color', palette.label)
  setPaint(map, labelIDs, 'text-halo-color', palette.labelHalo)

  addWalkingLayer(map, 'looper-trails', palette.trail, [
    'any', ['==', ['get', 'class'], 'track'],
    ['match', ['get', 'subclass'], ['path', 'track'], true, false],
  ], [1.4, 2.5, 6], [2, 1.4])
  addWalkingLayer(map, 'looper-footways', palette.footway, [
    'any', ['==', ['get', 'class'], 'pedestrian'],
    ['match', ['get', 'subclass'], ['footway', 'steps'], true, false],
  ], [1.5, 3, 7])
  addWalkingLayer(map, 'looper-cycleways', palette.cycleway, [
    'any', ['==', ['get', 'class'], 'cycleway'], ['==', ['get', 'subclass'], 'cycleway'],
  ], [1.7, 3.4, 7.5])
}

function addWalkingLayer(map: StyleMap, id: string, colour: string,
  filter: LineLayerSpecification['filter'], widths: [number, number, number], dash?: number[]) {
  if (map.getLayer(id)) {
    map.setPaintProperty(id, 'line-color', colour)
    return
  }
  const layer: LineLayerSpecification = {
    id, type: 'line', source: 'openmaptiles', 'source-layer': 'transportation', minzoom: 11, filter,
    layout: { 'line-cap': 'round', 'line-join': 'round' },
    paint: {
      'line-color': colour, 'line-opacity': 1,
      'line-width': ['interpolate', ['linear'], ['zoom'], 11, widths[0], 15, widths[1], 19, widths[2]],
      ...(dash ? { 'line-dasharray': dash } : {}),
    },
  }
  map.addLayer(layer, map.getLayer('road_one_way_arrow') ? 'road_one_way_arrow' : undefined)
}
