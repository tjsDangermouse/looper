import { useEffect, useRef, useState, type CSSProperties } from 'react'
import * as maplibregl from 'maplibre-gl'
import 'maplibre-gl/dist/maplibre-gl.css'
import maplibreWorkerUrl from 'maplibre-gl/dist/maplibre-gl-worker.mjs?worker&url'
import { headingGap, routeColours, type Point, type Route } from './lib'
import { applyLooperStyle, mapStyle, mapStyles, type MapStyleID } from './mapStyle'
import { MapLayersIcon } from './icons'

// MapLibre GL JS 6 loads vector-tile parsing in a module worker. Vite must
// bundle that worker explicitly; otherwise production builds look for it next
// to the hashed app chunk and the vector basemap remains blank.
maplibregl.setWorkerUrl(maplibreWorkerUrl)

type Props = { start: Point; routes: Route[]; selected?: string; position?: Point; follow?: boolean; walking?: boolean; heading?: number; courseUp?: boolean; onFollowChange?: (following: boolean) => void; onPoint: (point: Point) => void; padding?: { bottom: number; right: number } }
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

export function MapView({ start, routes, selected, position, follow, walking, heading, courseUp, onFollowChange, onPoint, padding }: Props) {
  const container = useRef<HTMLDivElement>(null)
  const styleControl = useRef<HTMLDivElement>(null)
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
  const [styleID, setStyleID] = useState<MapStyleID>('default')
  const [styleMenuOpen, setStyleMenuOpen] = useState(false)
  const styleIDRef = useRef<MapStyleID>('default')

  const pad = (): maplibregl.PaddingOptions => ({ top: 0, left: 0, bottom: paddingRef.current?.bottom ?? 0, right: paddingRef.current?.right ?? 0 })

  // When a fresh batch of routes comes in, pull back (or push in) so every
  // loop is on screen at once, rather than leaving the camera wherever it was.
  // fitBounds' own padding option goes badly wrong once one side's padding
  // approaches the container size (as the sheet's does on a phone screen) —
  // it collapses to a much lower zoom than the space actually requires — so
  // the fit is done by hand: fit to the margin alone, then shrink and shift
  // by exactly what the sheet's corner of the screen costs.
  const fitToRoutes = (list: Route[]) => {
    const map = mapRef.current
    if (!map || followRef.current || !list.length) return
    const bounds = list.reduce((bounds, route) => route.geometry.coordinates.reduce((b, point) => b.extend(point), bounds), new maplibregl.LngLatBounds())
    const cam = map.cameraForBounds(bounds, { padding: 60, maxZoom: WALK_ZOOM })
    if (!cam?.center || cam.zoom === undefined) return
    const el = map.getContainer()
    const w = el.clientWidth, h = el.clientHeight
    const bottomPad = paddingRef.current?.bottom ?? 0
    const rightPad = paddingRef.current?.right ?? 0
    const shrink = Math.min(1, (w - 120 - rightPad) / (w - 120), (h - 120 - bottomPad) / (h - 120))
    const zoom = Math.min(WALK_ZOOM, cam.zoom + Math.log2(shrink))
    const worldSize = 512 * Math.pow(2, zoom)
    const centre = maplibregl.MercatorCoordinate.fromLngLat(cam.center as maplibregl.LngLatLike)
    const shifted = new maplibregl.MercatorCoordinate(centre.x + rightPad / 2 / worldSize, centre.y + bottomPad / 2 / worldSize, centre.z).toLngLat()
    // The shift above already accounts for the sheet directly, so any padding
    // still set on the map from an earlier call must be cleared here — left
    // in place, it would be applied a second time on top of this shift.
    map.easeTo({ center: shifted, zoom, padding: { top: 0, left: 0, bottom: 0, right: 0 }, duration: 500 })
  }

  // The sheet that owns the current screen tends to mount (and set its
  // padding) right after a fit is requested, and its own re-centre would
  // otherwise cancel the fit's zoom mid-flight. Remembering the pending fit
  // lets the padding effect redo it with the settled padding instead.
  const pendingFit = useRef<Route[] | null>(null)
  const pendingFitTimer = useRef<number | undefined>(undefined)
  const triggerFit = (list: Route[]) => {
    if (!list.length) return
    pendingFit.current = list
    fitToRoutes(list)
    window.clearTimeout(pendingFitTimer.current)
    pendingFitTimer.current = window.setTimeout(() => { pendingFit.current = null }, 600)
  }

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
    const map = mapRef.current = new maplibregl.Map({ container: container.current, style: mapStyle.url, center: start, zoom: 13, attributionControl: false })
    map.setPadding(pad())
    map.addControl(new maplibregl.NavigationControl())
    marker.current = new maplibregl.Marker({ color: routeColours[0] }).setLngLat(start).addTo(map)
    map.on('click', event => onPointRef.current([event.lngLat.lng, event.lngLat.lat]))
    map.on('load', redraw)
    map.on('style.load', () => {
      if (styleIDRef.current === 'looper') applyLooperStyle(map)
      redraw()
    })
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
    if (followRef.current) map.easeTo({ center: position, zoom: Math.max(map.getZoom(), WALK_ZOOM), padding: pad(), duration: 700 })
  }, [position?.[0], position?.[1]])

  // Turning following on — starting a walk, or asking to be re-centred —
  // closes in on the walker without pulling back a zoom they chose themselves.
  useEffect(() => {
    followRef.current = follow
    const map = mapRef.current
    if (!map || !follow) return
    map.easeTo({ center: positionRef.current || startRef.current, zoom: Math.max(map.getZoom(), WALK_ZOOM), padding: pad(), duration: 800 })
  }, [follow])

  // Leaving the walk screen: pull back out to the whole loop, since the
  // walker was left zoomed in on wherever they'd got to.
  const walkingRef = useRef(walking)
  useEffect(() => {
    if (walkingRef.current && !walking) {
      const route = routesRef.current.find(r => r.id === selectedRef.current)
      if (route) triggerFit([route])
    }
    walkingRef.current = walking
  }, [walking])

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

  const routeIds = routes.map(r => r.id).join(',')
  useEffect(() => { routesRef.current = routes; redraw() }, [routes])
  useEffect(() => { triggerFit(routesRef.current) }, [routeIds])
  useEffect(() => { selectedRef.current = selected; redraw() }, [selected])
  useEffect(() => { startRef.current = start; marker.current?.setLngLat(start); if (!followRef.current) mapRef.current?.flyTo({ center: start, padding: pad(), duration: 450 }) }, [start])
  // Re-centre whenever the sheet's height changes so the marker stays in the
  // middle of the map area left uncovered by it.
  useEffect(() => {
    paddingRef.current = padding
    if (!padding) return
    const map = mapRef.current
    if (!map) return
    if (pendingFit.current) { fitToRoutes(pendingFit.current); return }
    const following = followRef.current
    map.easeTo({ center: following ? positionRef.current || startRef.current : startRef.current, zoom: following ? Math.max(map.getZoom(), WALK_ZOOM) : map.getZoom(), padding: pad(), duration: 300 })
  }, [padding?.bottom, padding?.right])

  useEffect(() => {
    if (!styleMenuOpen) return
    const closeOutside = (event: PointerEvent) => {
      if (!styleControl.current?.contains(event.target as Node)) setStyleMenuOpen(false)
    }
    const closeWithKeyboard = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setStyleMenuOpen(false)
    }
    document.addEventListener('pointerdown', closeOutside)
    document.addEventListener('keydown', closeWithKeyboard)
    return () => {
      document.removeEventListener('pointerdown', closeOutside)
      document.removeEventListener('keydown', closeWithKeyboard)
    }
  }, [styleMenuOpen])

  const chooseStyle = (next: MapStyleID) => {
    setStyleMenuOpen(false)
    if (next === styleIDRef.current) return
    styleIDRef.current = next
    setStyleID(next)
    const map = mapRef.current
    if (!map) return
    if (next === 'looper') {
      applyLooperStyle(map)
      redraw()
    } else {
      // A non-diffed reload restores an exact, unmodified Liberty style;
      // otherwise MapLibre can retain runtime paint mutations.
      map.setStyle(mapStyles.default.url, { diff: false })
    }
  }

  return <><div ref={container} style={{ position: 'fixed', inset: 0 }} aria-label="Douglas, Isle of Man map" /><svg aria-hidden="true" style={{ position: 'fixed', inset: 0, zIndex: 1, width: '100%', height: '100%', pointerEvents: 'none', overflow: 'visible' }}>{paths.map(path => <g key={path.id} opacity={selected ? (path.selected ? 1 : .28) : .9}>
    <polyline points={path.points} fill="none" stroke={path.colour} strokeWidth={path.selected ? 9 : 6} strokeLinecap="round" strokeLinejoin="round" />
    {path.arrows.map((arrow, index) => <path key={index} d="M-4.5,-4 L0,0 L-4.5,4" fill="none" stroke="#fff" strokeWidth={path.selected ? 2.2 : 1.8} strokeLinecap="round" strokeLinejoin="round" transform={`translate(${arrow.x} ${arrow.y}) rotate(${arrow.angle})`} />)}
  </g>)}</svg>{!walking && <div ref={styleControl} className={'map-style-control'+(styleMenuOpen ? ' open' : '')} style={{ bottom: `calc(${padding?.bottom ?? 0}px + max(12px, env(safe-area-inset-bottom)))` }}>
    <div className="map-style-options" role="menu" aria-hidden={!styleMenuOpen}>
      {(Object.keys(mapStyles) as MapStyleID[]).map((id, index) => <button key={id} type="button" role="menuitemradio" aria-checked={styleID === id} tabIndex={styleMenuOpen ? 0 : -1} style={{ '--style-index': index } as CSSProperties} onClick={() => chooseStyle(id)}><i aria-hidden="true" className={id} />{mapStyles[id].label}</button>)}
    </div>
    <button className="map-style-trigger" type="button" aria-label="Choose map style" title="Choose map style" aria-expanded={styleMenuOpen} onClick={() => setStyleMenuOpen(open => !open)}><MapLayersIcon /></button>
  </div>}</>
}
