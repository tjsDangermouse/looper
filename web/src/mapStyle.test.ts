import { describe, expect, it } from 'vitest'
import { mapStyle } from './mapStyle'

describe('basemap style', () => {
  it('uses the hosted OpenFreeMap vector style', () => {
    expect(mapStyle).toEqual({
      provider: 'OpenFreeMap',
      name: 'liberty',
      url: 'https://tiles.openfreemap.org/styles/liberty',
    })
  })

  it('does not fall back to the public OpenStreetMap raster service', () => {
    expect(mapStyle.url).not.toContain('tile.openstreetmap.org')
  })
})
