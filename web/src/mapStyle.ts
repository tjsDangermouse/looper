/**
 * Looper's basemap is deliberately configured separately from the map view.
 * A future Looper-specific style can replace this URL without touching route,
 * marker, gesture, or camera behaviour.
 */
export const mapStyle = {
  provider: 'OpenFreeMap',
  name: 'liberty',
  url: 'https://tiles.openfreemap.org/styles/liberty',
} as const
