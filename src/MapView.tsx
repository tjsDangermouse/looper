import { useEffect, useRef, useState } from 'react'
import * as maplibregl from 'maplibre-gl'
import 'maplibre-gl/dist/maplibre-gl.css'
import type { Point, Route } from './lib'

type Props = { start: Point; routes: Route[]; selected?: string; position?: Point; onPoint: (point: Point) => void }
type Path = { id: string; points: string; colour: string; selected: boolean }
const colours = ['#ef6b55', '#206a77', '#80679d']
const style: maplibregl.StyleSpecification = { version: 8, sources: { osm: { type: 'raster', tiles: ['https://tile.openstreetmap.org/{z}/{x}/{y}.png'], tileSize: 256, attribution: '© OpenStreetMap contributors' } }, layers: [{ id: 'osm', type: 'raster', source: 'osm' }] }

export function MapView({ start, routes, selected, onPoint }: Props) {
  const container = useRef<HTMLDivElement>(null)
  const mapRef = useRef<maplibregl.Map | undefined>(undefined)
  const marker = useRef<maplibregl.Marker | undefined>(undefined)
  const routesRef = useRef(routes)
  const selectedRef = useRef(selected)
  const [paths, setPaths] = useState<Path[]>([])

  const redraw = () => {
    const map = mapRef.current
    if (!map) return
    setPaths(routesRef.current.map((route, index) => ({
      id: route.id,
      colour: colours[index % colours.length],
      selected: route.id === selectedRef.current,
      points: route.geometry.coordinates.map(point => { const pixel = map.project(point); return `${pixel.x},${pixel.y}` }).join(' '),
    })))
  }

  useEffect(() => {
    if (!container.current) return
    const map = mapRef.current = new maplibregl.Map({ container: container.current, style, center: start, zoom: 13 })
    map.addControl(new maplibregl.NavigationControl())
    marker.current = new maplibregl.Marker({ color: '#ef6b55' }).setLngLat(start).addTo(map)
    map.on('click', event => onPoint([event.lngLat.lng, event.lngLat.lat]))
    map.on('load', redraw)
    map.on('move', redraw)
    map.on('error', event => console.error('[LoopWalk map]', event.error))
    return () => { marker.current?.remove(); map.remove(); mapRef.current = undefined }
  }, [])

  useEffect(() => { routesRef.current = routes; selectedRef.current = selected; redraw() }, [routes, selected])
  useEffect(() => { marker.current?.setLngLat(start); mapRef.current?.flyTo({ center: start, duration: 450 }) }, [start])

  return <><div ref={container} style={{ position: 'fixed', inset: 0 }} aria-label="Douglas, Isle of Man map" /><svg aria-hidden="true" style={{ position: 'fixed', inset: 0, zIndex: 1, width: '100%', height: '100%', pointerEvents: 'none', overflow: 'visible' }}>{paths.map(path => <polyline key={path.id} points={path.points} fill="none" stroke={path.colour} strokeWidth={path.selected ? 9 : 6} strokeLinecap="round" strokeLinejoin="round" opacity={selected ? (path.selected ? 1 : .28) : .9} />)}</svg></>
}
