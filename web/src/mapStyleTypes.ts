export const paletteKeys = [
  'background', 'residential', 'commercial', 'industrial', 'education', 'healthcare',
  'water', 'waterLine', 'park', 'parkOutline', 'grass', 'farmland', 'woodland',
  'wetland', 'sand', 'rock', 'ice', 'sports', 'cemetery', 'military', 'quarry',
  'aerodrome', 'building', 'casing', 'motorway', 'mainRoad', 'residentialRoad',
  'serviceRoad', 'footway', 'trail', 'cycleway', 'label', 'labelHalo',
] as const

export type PaletteKey = typeof paletteKeys[number]
export type MapPalette = Record<PaletteKey, string>
export type CustomMapStyle = { id: string; name: string; palette: MapPalette }
export type MapStyleCatalogue = { version: 1; styles: CustomMapStyle[]; routeColours: string[] }
