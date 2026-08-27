import type { LineLayerSpecification, Map } from 'maplibre-gl'

export type MapStyleID = 'default' | 'looper'

const libertyURL = 'https://tiles.openfreemap.org/styles/liberty'

export const mapStyles = {
  default: { provider: 'OpenFreeMap', name: 'liberty', label: 'Default', url: libertyURL },
  looper: { provider: 'OpenFreeMap', name: 'looper', label: 'Looper', url: libertyURL },
} as const

// Kept for callers that only need the unmodified basemap URL.
export const mapStyle = mapStyles.default

export const looperPalette = {
  background: '#f4f3ed', land: '#f4f3ed', residential: '#ecefe9', water: '#c6e4ed',
  park: '#dcebd6', parkOutline: '#8aac78', woodland: '#c8dec4', waterLine: '#82bdcf',
  building: '#deded7', casing: '#d5dad5',
  motorway: '#b7bdc0', mainRoad: '#969fa1', residentialRoad: '#ffffff',
  serviceRoad: '#c9cec9', footway: '#78934e', trail: '#4f7b31', cycleway: '#168b95',
  label: '#334249', labelHalo: '#faf9f4',
} as const

type StyleMap = Pick<Map, 'addLayer' | 'getLayer' | 'getStyle' | 'setLayoutProperty' | 'setPaintProperty'>

const setPaint = (map: StyleMap, ids: string[], property: string, value: unknown) => {
  for (const id of ids) if (map.getLayer(id)) map.setPaintProperty(id, property as never, value as never)
}

const lineIDs = (map: StyleMap, pattern: RegExp) =>
  (map.getStyle().layers ?? []).map(layer => layer.id).filter(id => pattern.test(id))

/** Apply Looper's walk-first visual hierarchy to OpenFreeMap Liberty. */
export function applyLooperStyle(map: StyleMap) {
  setPaint(map, ['background'], 'background-color', looperPalette.background)
  setPaint(map, ['landuse_residential'], 'fill-color', looperPalette.residential)
  setPaint(map, ['park'], 'fill-color', looperPalette.park)
  setPaint(map, ['park_outline'], 'line-color', looperPalette.parkOutline)
  setPaint(map, ['landcover_wood'], 'fill-color', looperPalette.woodland)
  setPaint(map, ['landcover_grass', 'landcover_grass_park'], 'fill-color', looperPalette.park)
  setPaint(map, ['water'], 'fill-color', looperPalette.water)
  setPaint(map, ['waterway'], 'line-color', looperPalette.waterLine)
  setPaint(map, ['building'], 'fill-color', looperPalette.building)
  setPaint(map, ['building-3d'], 'fill-extrusion-color', looperPalette.building)

  const casing = lineIDs(map, /_casing$/)
  setPaint(map, casing, 'line-color', looperPalette.casing)
  setPaint(map, casing, 'line-opacity', 0.72)

  const motorway = lineIDs(map, /^(road|bridge|tunnel)_motorway(_link)?$/)
  setPaint(map, motorway, 'line-color', looperPalette.motorway)
  setPaint(map, motorway, 'line-opacity', 0.72)

  const main = lineIDs(map, /^(road|bridge|tunnel)_(trunk_primary|secondary_tertiary|link)$/)
  setPaint(map, main, 'line-color', looperPalette.mainRoad)
  setPaint(map, main, 'line-opacity', 0.88)

  const residential = lineIDs(map, /^(road|bridge|tunnel)_(minor|street)$/)
  setPaint(map, residential, 'line-color', looperPalette.residentialRoad)
  setPaint(map, residential, 'line-opacity', 0.96)

  const service = lineIDs(map, /^(road|bridge|tunnel)_service_track$/)
  setPaint(map, service, 'line-color', looperPalette.serviceRoad)
  setPaint(map, service, 'line-opacity', 0.9)

  const paths = lineIDs(map, /^(road|bridge|tunnel)_path_pedestrian$/)
  setPaint(map, paths, 'line-color', looperPalette.footway)
  setPaint(map, paths, 'line-opacity', 1)

  for (const id of ['poi_r20', 'poi_r7', 'poi_r1']) {
    if (map.getLayer(id)) map.setLayoutProperty(id, 'visibility', 'none')
  }
  setPaint(map, ['poi_transit'], 'text-opacity', 0.5)
  setPaint(map, ['poi_transit'], 'icon-opacity', 0.5)

  const labelIDs = (map.getStyle().layers ?? []).map(layer => layer.id)
    .filter(id => /(_label|place_|highway-name|water_name)/.test(id))
  setPaint(map, labelIDs, 'text-color', looperPalette.label)
  setPaint(map, labelIDs, 'text-halo-color', looperPalette.labelHalo)

  addWalkingLayer(map, 'looper-trails', looperPalette.trail, [
    'any', ['==', ['get', 'class'], 'track'],
    ['match', ['get', 'subclass'], ['path', 'track'], true, false],
  ], [1.4, 2.5, 6], [2, 1.4])
  addWalkingLayer(map, 'looper-footways', looperPalette.footway, [
    'any', ['==', ['get', 'class'], 'pedestrian'],
    ['match', ['get', 'subclass'], ['footway', 'steps'], true, false],
  ], [1.5, 3, 7])
  addWalkingLayer(map, 'looper-cycleways', looperPalette.cycleway, [
    'any', ['==', ['get', 'class'], 'cycleway'], ['==', ['get', 'subclass'], 'cycleway'],
  ], [1.7, 3.4, 7.5])
}

function addWalkingLayer(map: StyleMap, id: string, colour: string,
  filter: LineLayerSpecification['filter'], widths: [number, number, number], dash?: number[]) {
  if (map.getLayer(id)) return
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
