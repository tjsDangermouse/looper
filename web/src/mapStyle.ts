import type { LineLayerSpecification, Map } from 'maplibre-gl'

export type MapStyleID = 'default' | 'looper'

const libertyURL = 'https://tiles.openfreemap.org/styles/liberty'

export const mapStyles = {
  default: { provider: 'OpenFreeMap', name: 'liberty', label: 'Default', url: libertyURL },
  looper: { provider: 'OpenFreeMap', name: 'looper', label: 'Looper', url: libertyURL },
} as const

// Kept for callers that only need the unmodified basemap URL.
export const mapStyle = mapStyles.default

export type LooperPalette = {
  background: string; residential: string; water: string
  park: string; parkOutline: string; woodland: string; waterLine: string
  building: string; casing: string; motorway: string; mainRoad: string
  residentialRoad: string; serviceRoad: string; footway: string; trail: string
  cycleway: string; label: string; labelHalo: string
}

export const looperPalette: LooperPalette = {
  "background": "#e4e4d7",
  "residential": "#5c793e",
  "water": "#cae8f1",
  "park": "#70a300",
  "parkOutline": "#172e00",
  "woodland": "#c4e198",
  "waterLine": "#00c3ff",
  "building": "#c6c3c3",
  "casing": "#878787",
  "motorway": "#f05656",
  "mainRoad": "#fde753",
  "residentialRoad": "#ffffff",
  "serviceRoad": "#ffffff",
  "footway": "#c9c9c9",
  "trail": "#359c46",
  "cycleway": "#ffffff",
  "label": "#000000",
  "labelHalo": "#e3e3e3"
} as const

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
