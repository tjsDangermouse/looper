import { useEffect, useRef, useState } from 'react'
import * as maplibregl from 'maplibre-gl'
import 'maplibre-gl/dist/maplibre-gl.css'
import { headingGap, routeColours, type Point, type Route } from './lib'

type Props = { start: Point; routes: Route[]; selected?: string; position?: Point; follow?: boolean; heading?: number; courseUp?: boolean; onFollowChange?: (following: boolean) => void; onPoint: (point: Point) => void; padding?: { bottom: number; right: number } }
type Arrow = { x: number; y: number; angle: number }
type Path = { id: string; points: string; colour: string; selected: boolean; arrows: Arrow[] }
// Chevrons dropped at an even spacing along the drawn line, pointing the way
// the walk goes. Screen space, so they stay the same size at every zoom, and
// off-screen ones are dropped rather than drawn into the void.
const SPACING = 110
// Close enough to read the next corner and its street, wide enough to hold a
// couple of hundred metres of the loop around the walker.
const WALK_ZOOM = 17
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

export function MapView({ start, routes, selected, position, follow, heading, courseUp, onFollowChange, onPoint, padding }: Props) {
  const container = useRef<HTMLDivElement>(null)
  const mapRef = useRef<maplibregl.Map | undefined>(undefined)
  const marker = useRef<maplibregl.Marker | undefined>(undefined)
  const routesRef = useRef(routes)
  const paddingRef = useRef(padding)
  const startRef = useRef(start)
  const selectedRef = useRef(selected)
  const gps = useRef<maplibregl.Marker | undefined>(undefined)
  const positionRef = useRef(position)
  const followRef = useRef(follow)
  const onFollow = useRef(onFollowChange)
  const onPointRef = useRef(onPoint)
  onFollow.current = onFollowChange
  onPointRef.current = onPoint
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
    map.on('click', event => onPointRef.current([event.lngLat.lng, event.lngLat.lat]))
    map.on('load', redraw)
    map.on('move', redraw)
    map.on('error', event => console.error('[Looper map]', event.error))
    // A drag or pinch is the walker asking to look elsewhere, so following
    // stops until they ask for it back. Our own eases carry no originalEvent.
    map.on('movestart', event => { if ((event as { originalEvent?: unknown }).originalEvent) onFollow.current?.(false) })
    return () => { marker.current?.remove(); gps.current?.remove(); map.remove(); mapRef.current = undefined }
  }, [])

  // The blue dot, and the map travelling with it while following is on.
  useEffect(() => {
    positionRef.current = position
    const map = mapRef.current
    if (!map) return
    if (!position) { gps.current?.remove(); gps.current = undefined; return }
    if (gps.current) gps.current.setLngLat(position)
    else { const element = document.createElement('div'); element.className = 'gps-dot'; gps.current = new maplibregl.Marker({ element }).setLngLat(position).addTo(map) }
    if (followRef.current) map.easeTo({ center: position, padding: pad(), duration: 700 })
  }, [position?.[0], position?.[1]])

  // Turning following on — starting a walk, or asking to be re-centred —
  // closes in on the walker without pulling back a zoom they chose themselves.
  useEffect(() => {
    followRef.current = follow
    const map = mapRef.current
    if (!map || !follow) return
    map.easeTo({ center: positionRef.current || startRef.current, zoom: Math.max(map.getZoom(), WALK_ZOOM), padding: pad(), duration: 800 })
  }, [follow])

  // Course-up: the map turns so the way the walker faces is up the screen.
  // Rotation is a camera move like any other, so the drawn line and its arrows
  // re-project with it; north-up winds the bearing back to zero.
  useEffect(() => {
    const map = mapRef.current
    if (!map) return
    if (!courseUp) { if (map.getBearing()) map.easeTo({ bearing: 0, padding: pad(), duration: 400 }); return }
    if (heading === undefined || headingGap(heading, map.getBearing()) < 2) return
    map.easeTo({ bearing: heading, padding: pad(), duration: 300 })
  }, [courseUp, heading])

  useEffect(() => { routesRef.current = routes; selectedRef.current = selected; redraw() }, [routes, selected])
  useEffect(() => { startRef.current = start; marker.current?.setLngLat(start); if (!followRef.current) mapRef.current?.flyTo({ center: start, padding: pad(), duration: 450 }) }, [start])
  // Re-centre whenever the sheet's height changes so the marker stays in the
  // middle of the map area left uncovered by it.
  useEffect(() => {
    paddingRef.current = padding
    if (!padding) return
    mapRef.current?.easeTo({ center: followRef.current ? positionRef.current || startRef.current : startRef.current, padding: pad(), duration: 300 })
  }, [padding?.bottom, padding?.right])

  return <><div ref={container} style={{ position: 'fixed', inset: 0 }} aria-label="Douglas, Isle of Man map" /><svg aria-hidden="true" style={{ position: 'fixed', inset: 0, zIndex: 1, width: '100%', height: '100%', pointerEvents: 'none', overflow: 'visible' }}>{paths.map(path => <g key={path.id} opacity={selected ? (path.selected ? 1 : .28) : .9}>
    <polyline points={path.points} fill="none" stroke={path.colour} strokeWidth={path.selected ? 9 : 6} strokeLinecap="round" strokeLinejoin="round" />
    {path.arrows.map((arrow, index) => <path key={index} d="M-4.5,-4 L0,0 L-4.5,4" fill="none" stroke="#fff" strokeWidth={path.selected ? 2.2 : 1.8} strokeLinecap="round" strokeLinejoin="round" transform={`translate(${arrow.x} ${arrow.y}) rotate(${arrow.angle})`} />)}
  </g>)}</svg></>
}
