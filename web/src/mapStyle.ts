import type { ExpressionSpecification, FillLayerSpecification, LineLayerSpecification, Map } from 'maplibre-gl'
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
  setPaint(map, ['landcover_grass', 'landcover_grass_park'], 'fill-color', palette.grass)
  setPaint(map, ['landcover_ice'], 'fill-color', palette.ice)
  setPaint(map, ['landcover_sand'], 'fill-color', palette.sand)
  setPaint(map, ['landuse_pitch', 'landuse_track'], 'fill-color', palette.sports)
  setPaint(map, ['landuse_cemetery'], 'fill-color', palette.cemetery)
  setPaint(map, ['landuse_school'], 'fill-color', palette.education)
  setPaint(map, ['landuse_hospital'], 'fill-color', palette.healthcare)
  setPaint(map, ['aeroway_fill'], 'fill-color', palette.aerodrome)
  setPaint(map, ['water'], 'fill-color', palette.water)
  setPaint(map, ['waterway'], 'line-color', palette.waterLine)
  setPaint(map, ['building'], 'fill-color', palette.building)
  setPaint(map, ['building-3d'], 'fill-extrusion-color', palette.building)

  // Liberty does not draw every OpenMapTiles land-cover/land-use class. Add
  // the missing fills so every colour offered by the editor is visible in
  // both the preview and the shipped maps.
  addFillLayer(map, 'looper-farmland', 'landcover', palette.farmland,
    ['==', ['get', 'class'], 'farmland'], 'park')
  addFillLayer(map, 'looper-rock', 'landcover', palette.rock,
    ['==', ['get', 'class'], 'rock'], 'park')
  addFillLayer(map, 'looper-wetland-underlay', 'landcover', palette.wetland,
    ['==', ['get', 'class'], 'wetland'], 'landcover_wetland')
  addFillLayer(map, 'looper-parkland', 'landcover', palette.park,
    ['match', ['get', 'subclass'], ['park', 'recreation_ground', 'village_green', 'garden', 'golf_course'], true, false], 'park')
  addFillLayer(map, 'looper-park-uses', 'landuse', palette.park,
    ['match', ['get', 'class'], ['theme_park', 'zoo'], true, false], 'landuse_pitch')
  addFillLayer(map, 'looper-commercial', 'landuse', palette.commercial,
    ['match', ['get', 'class'], ['commercial', 'retail'], true, false], 'landuse_pitch')
  addFillLayer(map, 'looper-industrial', 'landuse', palette.industrial,
    ['match', ['get', 'class'], ['industrial', 'garages', 'railway'], true, false], 'landuse_pitch')
  addFillLayer(map, 'looper-education', 'landuse', palette.education,
    ['match', ['get', 'class'], ['university', 'college', 'kindergarten', 'library'], true, false], 'landuse_pitch')
  addFillLayer(map, 'looper-healthcare', 'landuse', palette.healthcare,
    ['==', ['get', 'class'], 'healthcare'], 'landuse_pitch')
  addFillLayer(map, 'looper-recreation', 'landuse', palette.sports,
    ['match', ['get', 'class'], ['stadium', 'playground'], true, false], 'landuse_pitch')
  addFillLayer(map, 'looper-military', 'landuse', palette.military,
    ['==', ['get', 'class'], 'military'], 'landuse_pitch')
  addFillLayer(map, 'looper-quarry', 'landuse', palette.quarry,
    ['==', ['get', 'class'], 'quarry'], 'landuse_pitch')

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

  // Liberty's surface path layer would duplicate the categorized Looper
  // overlays below. Keep its bridge/tunnel treatment, but let Looper own the
  // ordinary surface geometry so it can distinguish trails and footways.
  if (map.getLayer('road_path_pedestrian')) map.setLayoutProperty('road_path_pedestrian', 'visibility', 'none')
  setPaint(map, ['bridge_path_pedestrian', 'tunnel_path_pedestrian'], 'line-color', palette.footway)

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
  ], 13, [1, 1.8, 3.5], [2, 1.4])
  addWalkingLayer(map, 'looper-footways', palette.footway, [
    'any', ['==', ['get', 'class'], 'pedestrian'],
    ['match', ['get', 'subclass'], ['footway', 'steps'], true, false],
  ], 14, [0.8, 1.5, 3.5])
  addWalkingLayer(map, 'looper-cycleways', palette.cycleway, [
    'any', ['==', ['get', 'class'], 'cycleway'], ['==', ['get', 'subclass'], 'cycleway'],
  ], 13, [1, 1.8, 3.8])
}

function addFillLayer(map: StyleMap, id: string, sourceLayer: string, colour: string,
  filter: NonNullable<FillLayerSpecification['filter']>, before?: string) {
  if (map.getLayer(id)) {
    map.setPaintProperty(id, 'fill-color', colour)
    return
  }
  const layer: FillLayerSpecification = {
    id, type: 'fill', source: 'openmaptiles', 'source-layer': sourceLayer, filter,
    paint: { 'fill-color': colour, 'fill-opacity': 1 },
  }
  map.addLayer(layer, before && map.getLayer(before) ? before : undefined)
}

function addWalkingLayer(map: StyleMap, id: string, colour: string,
  filter: NonNullable<LineLayerSpecification['filter']>, minzoom: number, widths: [number, number, number], dash?: number[]) {
  const width: ExpressionSpecification = ['interpolate', ['linear'], ['zoom'], 14, widths[0], 16, widths[1], 19, widths[2]]
  if (map.getLayer(id)) {
    map.setPaintProperty(id, 'line-color', colour)
    map.setPaintProperty(id, 'line-width', width as never)
    return
  }
  const layer: LineLayerSpecification = {
    id, type: 'line', source: 'openmaptiles', 'source-layer': 'transportation', minzoom,
    filter: ['all', ['match', ['get', 'brunnel'], ['bridge', 'tunnel'], false, true], filter] as never,
    layout: { 'line-cap': 'round', 'line-join': 'round' },
    paint: {
      'line-color': colour, 'line-opacity': 1,
      'line-width': width,
      ...(dash ? { 'line-dasharray': dash } : {}),
    },
  }
  map.addLayer(layer, map.getLayer('road_motorway_link_casing') ? 'road_motorway_link_casing' : undefined)
}
