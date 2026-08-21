import { useEffect, useRef, useState } from 'react'
import * as maplibregl from 'maplibre-gl'
import 'maplibre-gl/dist/maplibre-gl.css'
import { routeColours, type Point, type Route } from './lib'

type Props = { start: Point; routes: Route[]; selected?: string; position?: Point; onPoint: (point: Point) => void; padding?: { bottom: number; right: number } }
type Arrow = { x: number; y: number; angle: number }
type Path = { id: string; points: string; colour: string; selected: boolean; arrows: Arrow[] }
// Chevrons dropped at an even spacing along the drawn line, pointing the way
// the walk goes. Screen space, so they stay the same size at every zoom, and
// off-screen ones are dropped rather than drawn into the void.
const SPACING = 110
function arrowsAlong(pixels: { x: number; y: number }[]) {
  const arrows: Arrow[] = []
  let until = SPACING / 2
  for (let i = 1; i < pixels.length; i++) {
    const a = pixels[i - 1], b = pixels[i], dx = b.x - a.x, dy = b.y - a.y, length = Math.hypot(dx, dy)
    if (!length) continue
    let at = until
    for (; at <= length; at += SPACING) {
      const x = a.x + dx * at / length, y = a.y + dy * at / length
      if (x > -20 && y > -20 && x < window.innerWidth + 20 && y < window.innerHeight + 20) arrows.push({ x, y, angle: Math.atan2(dy, dx) * 180 / Math.PI })
    }
    until = at - length
  }
  return arrows
}

const style: maplibregl.StyleSpecification = { version: 8, sources: { osm: { type: 'raster', tiles: ['https://tile.openstreetmap.org/{z}/{x}/{y}.png'], tileSize: 256, attribution: '© OpenStreetMap contributors' } }, layers: [{ id: 'osm', type: 'raster', source: 'osm' }] }

export function MapView({ start, routes, selected, onPoint, padding }: Props) {
  const container = useRef<HTMLDivElement>(null)
  const mapRef = useRef<maplibregl.Map | undefined>(undefined)
  const marker = useRef<maplibregl.Marker | undefined>(undefined)
  const routesRef = useRef(routes)
  const paddingRef = useRef(padding)
  const startRef = useRef(start)
  const selectedRef = useRef(selected)
  const [paths, setPaths] = useState<Path[]>([])

  const pad = (): maplibregl.PaddingOptions => ({ top: 0, left: 0, bottom: paddingRef.current?.bottom ?? 0, right: paddingRef.current?.right ?? 0 })

  const redraw = () => {
    const map = mapRef.current
    if (!map) return
    setPaths(routesRef.current.map((route, index) => {
      const pixels = route.geometry.coordinates.map(point => map.project(point))
      return {
        id: route.id,
        colour: routeColours[index % routeColours.length],
        selected: route.id === selectedRef.current,
        points: pixels.map(pixel => `${pixel.x},${pixel.y}`).join(' '),
        arrows: arrowsAlong(pixels),
      }
    }))
  }

  useEffect(() => {
    if (!container.current) return
    const map = mapRef.current = new maplibregl.Map({ container: container.current, style, center: start, zoom: 13, attributionControl: false })
    map.setPadding(pad())
    map.addControl(new maplibregl.NavigationControl())
    marker.current = new maplibregl.Marker({ color: routeColours[0] }).setLngLat(start).addTo(map)
    map.on('click', event => onPoint([event.lngLat.lng, event.lngLat.lat]))
    map.on('load', redraw)
    map.on('move', redraw)
    map.on('error', event => console.error('[Looper map]', event.error))
    return () => { marker.current?.remove(); map.remove(); mapRef.current = undefined }
  }, [])

  useEffect(() => { routesRef.current = routes; selectedRef.current = selected; redraw() }, [routes, selected])
  useEffect(() => { startRef.current = start; marker.current?.setLngLat(start); mapRef.current?.flyTo({ center: start, padding: pad(), duration: 450 }) }, [start])
  // Re-centre whenever the sheet's height changes so the marker stays in the
  // middle of the map area left uncovered by it.
  useEffect(() => {
    paddingRef.current = padding
    if (!padding) return
    mapRef.current?.easeTo({ center: startRef.current, padding: pad(), duration: 300 })
  }, [padding?.bottom, padding?.right])

  return <><div ref={container} style={{ position: 'fixed', inset: 0 }} aria-label="Douglas, Isle of Man map" /><svg aria-hidden="true" style={{ position: 'fixed', inset: 0, zIndex: 1, width: '100%', height: '100%', pointerEvents: 'none', overflow: 'visible' }}>{paths.map(path => <g key={path.id} opacity={selected ? (path.selected ? 1 : .28) : .9}>
    <polyline points={path.points} fill="none" stroke={path.colour} strokeWidth={path.selected ? 9 : 6} strokeLinecap="round" strokeLinejoin="round" />
    {path.arrows.map((arrow, index) => <path key={index} d="M-4.5,-4 L0,0 L-4.5,4" fill="none" stroke="#fff" strokeWidth={path.selected ? 2.2 : 1.8} strokeLinecap="round" strokeLinejoin="round" transform={`translate(${arrow.x} ${arrow.y}) rotate(${arrow.angle})`} />)}
  </g>)}</svg></>
}
