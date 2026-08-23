export type Point = [number, number]
export type LoopMode = 'distance'|'time'
export type Unit = 'km'|'mi'

export type Step = { instruction: string; distanceMeters: number; durationSeconds: number; startIndex?: number; endIndex?: number; maneuver?: string|number; road?: string; roadClass?: string }
export type Route = { id: string; name: string; distanceMeters: number; durationSeconds: number; targetDifferencePercent: number; geometry: {type:'LineString'; coordinates: Point[]}; steps: Step[]; reversed?: boolean }
// One palette for both the drawn lines and the swatch on each route card, so
// a colour on the map names the same loop in the list.
export const routeColours = ['#9cc36b', '#5fa8d3', '#e0a35c']
export const kmToMiles = (km:number) => km * 0.621371
export const milesToKm = (mi:number) => mi / 0.621371
export const estimateKmFromMinutes = (minutes:number) => minutes / 12
export const formatDistance = (meters:number, unit:'km'|'mi'='km') => unit === 'km' ? `${(meters/1000).toFixed(1)} km` : `${kmToMiles(meters/1000).toFixed(1)} mi`
export const formatTime = (seconds:number) => `${Math.round(seconds / 60)} min`
export const haversine = (a:Point,b:Point) => { const r=6371000, rad=Math.PI/180, dLat=(b[1]-a[1])*rad,dLng=(b[0]-a[0])*rad; const x=Math.sin(dLat/2)**2+Math.cos(a[1]*rad)*Math.cos(b[1]*rad)*Math.sin(dLng/2)**2; return 2*r*Math.atan2(Math.sqrt(x),Math.sqrt(1-x)) }
// How far round the loop the walker has come. Vertices sit tens of metres
// apart, so the nearest one is refined by projecting onto the segment it lies
// on. A loop ends where it begins, so the search is anchored to the progress
// already made: without that, a wobble at the start reads as the final vertex
// and the walk jumps straight to "almost home".
const cumulative = (coords:Point[]) => { const out=[0]; for(let i=1;i<coords.length;i++) out.push(out[i-1]+haversine(coords[i-1],coords[i])); return out }
// Distance to a segment and how far along it the foot of the perpendicular
// falls, in metres on a local flat frame — ample over one segment's span.
function projectOnSegment(p:Point,a:Point,b:Point){ const m=6371000*Math.PI/180, scale=Math.cos(a[1]*Math.PI/180)
  const bx=(b[0]-a[0])*scale*m, by=(b[1]-a[1])*m, px=(p[0]-a[0])*scale*m, py=(p[1]-a[1])*m
  const length=Math.hypot(bx,by), t=length?Math.min(1,Math.max(0,(px*bx+py*by)/(length*length))):0
  return { along:t*length, portion:t, distance:Math.hypot(px-bx*t,py-by*t) } }
export type Progress = { distanceToRoute:number; index:number; distanceAlong:number }
export function nearestProgress(point:Point, coords:Point[], from=0):Progress {
  if(coords.length<2) return { distanceToRoute:haversine(point,coords[0]), index:0, distanceAlong:0 }
  const along=cumulative(coords)
  let best:Progress|undefined, ahead:Progress|undefined
  for(let i=0;i<coords.length-1;i++){
    const seg=projectOnSegment(point,coords[i],coords[i+1])
    const here:Progress={ distanceToRoute:seg.distance, index:seg.portion>.5?i+1:i, distanceAlong:along[i]+seg.along }
    if(!best||here.distanceToRoute<best.distanceToRoute) best=here
    // A little slack behind, so standing still or drifting back a pace does not
    // strand the walker on the far side of the anchor.
    if(here.distanceAlong>=from-25&&(!ahead||here.distanceToRoute<ahead.distanceToRoute)) ahead=here
  }
  // Keep to the anchored match while it is plausibly the route underfoot; when
  // it is not, the walk has left the loop and the whole line is fair game again.
  return ahead&&ahead.distanceToRoute<55?ahead:best!
}
// A step's instruction is the manoeuvre at its *start* — the turn onto the road
// that step then walks, which is why the step carries that road's name. So the
// turn being called out is the first step that starts further along the loop
// than the walker has come, and step 0 (setting off) is never it.
export function nextTurn(route:Route, progressMeters:number) {
  let start=0
  for(let i=0;i<route.steps.length;i++){
    if(start>progressMeters) return {...route.steps[i], index:i, distanceAway:start-progressMeters}
    start+=route.steps[i].distanceMeters
  }
  return undefined
}
// ---- Which way to turn ---------------------------------------------------
// The turn a step ends on, as a shape the walk screen can draw. The two
// routers disagree on how to say it — ORS numbers its instruction types, the
// loop service names them — and a walk saved by an older build carries no
// maneuver at all, so the wording is read as a last resort.
export type Turn='left'|'slight-left'|'sharp-left'|'right'|'slight-right'|'sharp-right'|'straight'|'u-turn'|'arrive'
const ORS_TURNS:Record<number,Turn> = {0:'left',1:'right',2:'sharp-left',3:'sharp-right',4:'slight-left',5:'slight-right',6:'straight',7:'straight',8:'straight',9:'u-turn',10:'arrive',11:'straight',12:'slight-left',13:'slight-right'}
const NAMED_TURNS:Record<string,Turn> = {'turn-left':'left','turn-right':'right','keep-left':'slight-left','keep-right':'slight-right','u-turn-left':'u-turn','u-turn-right':'u-turn','continue':'straight','roundabout':'straight','finish':'arrive','waypoint':'arrive'}
const KNOWN = new Set<Turn>(['left','slight-left','sharp-left','right','slight-right','sharp-right','straight','u-turn','arrive'])
// Sharp and slight are looked for before the bare side, so "slight left" does
// not read as a square left turn.
function turnFromWords(instruction:string):Turn {
  const text=instruction.toLowerCase()
  if(/u-?turn|turn around/.test(text)) return 'u-turn'
  if(/arrive|arrived|destination|back where you started/.test(text)) return 'arrive'
  for(const side of ['left','right'] as const){
    if(new RegExp(`sharp\\s+${side}`).test(text)) return `sharp-${side}` as Turn
    if(new RegExp(`(slight(ly)?|bear|keep)\\s+${side}`).test(text)) return `slight-${side}` as Turn
    if(new RegExp(`\\b${side}\\b`).test(text)) return side
  }
  return 'straight'
}
export function turnKind(step:{instruction?:string; maneuver?:string|number}|undefined):Turn {
  if(!step) return 'arrive'
  const code=step.maneuver
  if(typeof code==='number') return ORS_TURNS[code]??'straight'
  if(typeof code==='string'){ const named=NAMED_TURNS[code]??(KNOWN.has(code as Turn)?code as Turn:undefined); if(named) return named }
  return turnFromWords(step.instruction||'')
}
export const mirrorTurn = (turn:Turn):Turn => turn.replace(/left|right/,side=>side==='left'?'right':'left') as Turn

// Routers occasionally clip a metre into a side road and straight back out. A
// walker cannot act on that: it calls a turn onto the road already underfoot
// and hides the turn that genuinely comes next. Steps too short to walk are
// folded into the one before, as is any step that rejoins the road already
// being walked — you cannot turn onto the road you are on. The ground covered
// is kept, so the distances still add up to the length of the loop.
const MICRO_STEP_METRES = 10
export function tidySteps(steps:Step[]):Step[] {
  const out:Step[] = []
  for(const step of steps){
    const last=out[out.length-1]
    const rejoins = !!last?.road && last.road===step.road
    if(last && turnKind(step)!=='arrive' && (step.distanceMeters<MICRO_STEP_METRES || rejoins)){
      last.distanceMeters+=step.distanceMeters; last.durationSeconds+=step.durationSeconds; last.endIndex=step.endIndex
      continue
    }
    out.push({...step})
  }
  return out
}

// The router can call a turn where a footpath continues almost straight across
// a road.  The joined route shape tells us what the walker sees, while
// road_class lets the wording describe the road-to-path transition clearly.
const STRAIGHT_AHEAD_DEGREES = 32
const PATH_CLASSES = new Set(['bridleway','cycleway','footway','path','pedestrian','steps','track'])
const bearing = (from:Point,to:Point) => {
  const rad=Math.PI/180, dLng=(to[0]-from[0])*rad
  const y=Math.cos(from[1]*rad)*Math.sin(dLng)
  const x=Math.cos(from[1]*rad)*Math.sin(to[1]*rad)-Math.sin(from[1]*rad)*Math.cos(to[1]*rad)*Math.cos(dLng)
  return (Math.atan2(y,x)*180/Math.PI+360)%360
}
const bearingGap = (a:number,b:number) => Math.abs(((b-a+540)%360)-180)
function routeBearing(coords:Point[], pivot:number, before:boolean):number|undefined {
  if(pivot<0||pivot>=coords.length) return undefined
  let index=pivot, travelled=0
  while(before?index>0:index<coords.length-1){
    const next=before?index-1:index+1
    travelled+=haversine(coords[index],coords[next]); index=next
    if(travelled>=12) break
  }
  return index===pivot?undefined:before?bearing(coords[index],coords[pivot]):bearing(coords[pivot],coords[index])
}
const isPath = (roadClass?:string) => !!roadClass&&PATH_CLASSES.has(roadClass.toLowerCase())
const roadLabel = (road?:string) => road||'the road'
export function normaliseWalkingSteps(route:Route):Route {
  const steps=route.steps.map(step=>({...step}))
  for(let index=1;index<steps.length;index++){
    const step=steps[index], previous=steps[index-1]
    if(step.startIndex===undefined) continue
    const incoming=routeBearing(route.geometry.coordinates,step.startIndex,true)
    const outgoing=routeBearing(route.geometry.coordinates,step.startIndex,false)
    if(incoming===undefined||outgoing===undefined||bearingGap(incoming,outgoing)>STRAIGHT_AHEAD_DEGREES) continue
    const ontoPath=!isPath(previous.roadClass)&&isPath(step.roadClass)
    const ontoRoad=isPath(previous.roadClass)&&!isPath(step.roadClass)
    if(ontoPath){ step.maneuver='continue'; step.instruction=`Carry on across ${roadLabel(previous.road)} onto the pathway` }
    else if(ontoRoad){ step.maneuver='continue'; step.instruction=`Carry on from the pathway onto ${roadLabel(step.road)}` }
  }
  return {...route,steps:tidySteps(steps)}
}

// Walking the loop the other way round. The same roads come in the opposite
// order, so each reversed step walks the road its forward counterpart walked
// and is introduced by the *next* forward turn, mirrored: a right off Main
// Street onto Quay Road going out is a left off Quay Road onto Main Street
// coming back. The walk sets off along the last road and ends where it began.
const mirror = (instruction:string) => instruction.replace(/\bleft\b/gi,'\u0000').replace(/\bright\b/gi,'left').replace(/\u0000/g,'right')
const onto = (instruction:string, road?:string) => { const bare=instruction.replace(/\s+onto\s+.+$/i,''); return road?`${bare} onto ${road}`:bare }
export function reverseRoute(route:Route):Route {
  // Zero-length steps — arriving, and the odd roundabout marker — name no road
  // to walk, so the roads of the walk are the steps that cover ground.
  const walked = route.steps.filter(step=>step.distanceMeters>0)
  const steps:Step[] = walked.map((_,j)=>{
    const road=walked[walked.length-1-j], joins=walked[walked.length-j]
    if(!joins) return { ...road, maneuver:'straight', instruction: road.road?`Head along ${road.road}`:'Set off along the loop' }
    return { ...road, maneuver: mirrorTurn(turnKind(joins)), instruction: onto(mirror(joins.instruction), road.road) }
  })
  steps.push({ instruction:'Arrive at your starting point', maneuver:'arrive', distanceMeters:0, durationSeconds:0 })
  return normaliseWalkingSteps({ ...route, reversed:!route.reversed, steps:tidySteps(steps), geometry:{...route.geometry, coordinates:[...route.geometry.coordinates].reverse()} })
}
// ---- Looper route service ----------------------------------------------
// The app talks to Looper's own API and to nothing else. Where that API lives
// is a build-time setting: blank in development, where Vite proxies /v1 to the
// local route service, and the deployed service's origin in production.
export const apiBase = (import.meta.env?.VITE_LOOPER_API_BASE ?? '').replace(/\/+$/, '')

type LoopRouteResponse = Omit<Route,'name'> & { label:string }

/** Ask for loops. Errors carry a sentence a walker can act on, nothing more. */
export async function requestLoops(input:{ start:Point; mode:LoopMode; distanceKm?:number; durationMinutes?:number; unit:Unit; variation:number; excludeRoutes?:Route[] }):Promise<{ routes:Route[]; warning?:string }> {
  const response = await fetch(`${apiBase}/v1/loops`, {
    method:'POST', headers:{ 'Content-Type':'application/json' },
    body: JSON.stringify({
      start:{ lng:input.start[0], lat:input.start[1] },
      mode:input.mode,
      distanceKm: input.mode==='distance' ? input.distanceKm : undefined,
      durationMinutes: input.mode==='time' ? input.durationMinutes : undefined,
      units: input.unit,
      variation: input.variation,
      exclude: input.excludeRoutes?.map(route=>route.geometry.coordinates),
    }),
  })
  const data = await response.json().catch(()=>({}))
  if (!response.ok) throw new Error(typeof data?.error === 'string' ? data.error : 'Routes are unavailable right now.')
  // The service names a loop for the way it heads; the app has always called
  // that a route's name.
  const routes = (data.routes ?? []).map((route:LoopRouteResponse)=>normaliseWalkingSteps({ ...route, name: route.label }))
  return { routes, warning: typeof data?.warning === 'string' ? data.warning : undefined }
}

// Voice guidance. A turn is announced at most once per band, so walking through
// 150 m → 50 m → the corner itself gives three prompts and no repetition.
export type Band='soon'|'near'|'now'
export const turnBand = (metresAway:number):Band|undefined => metresAway<5?'now':metresAway<50?'near':metresAway<150?'soon':undefined
// Say the distance that is actually left. The bands decide *when* to speak;
// they used to decide what was spoken too, so a turn first picked up part way
// into a band — right after the turn before it — was called out at the band's
// nominal distance: "in one hundred metres" with the corner 45 m away.
const round = (value:number, step:number) => Math.round(value/step)*step
const spokenDistance = (metres:number, unit:'km'|'mi') => unit==='mi'
  ? `${round(metres*1.09361, metres*1.09361<100?10:50)} yards`
  : `${round(metres, metres<100?10:50)} metres`
// Instructions arrive sentence-cased ("Turn left onto…"); lower the first word
// when it follows a lead-in so the sentence reads as one phrase.
const joinCase = (instruction:string) => instruction.replace(/^[A-Z](?![A-Z])/, c=>c.toLowerCase())
export function turnAnnouncement(turn:{index:number; instruction:string; distanceAway:number}|undefined, unit:'km'|'mi') {
  if(!turn) return undefined
  const band=turnBand(turn.distanceAway); if(!band) return undefined
  return { key:`${turn.index}:${band}`, text:band==='now'?turn.instruction:`In ${spokenDistance(turn.distanceAway,unit)}, ${joinCase(turn.instruction)}` }
}


// ---- Compass -----------------------------------------------------------
// Which way the walker is facing, so the map can turn with them. iOS hands us
// a true compass heading and demands permission from a gesture; elsewhere the
// earth-framed alpha counts the other way round, and both need the screen's
// own rotation added back on.
export const compassAvailable = () => typeof window !== 'undefined' && 'DeviceOrientationEvent' in window
export const screenAngle = () => (typeof screen !== 'undefined' && screen.orientation?.angle) || 0
export function headingFrom(event:{alpha?:number|null; absolute?:boolean; webkitCompassHeading?:number}, angle=0):number|undefined {
  const compass = event.webkitCompassHeading
  if (typeof compass === 'number' && Number.isFinite(compass)) return (compass + angle) % 360
  if (typeof event.alpha !== 'number' || !Number.isFinite(event.alpha)) return undefined
  return (360 - event.alpha + angle) % 360
}
// A compass twitches, so each reading is eased toward rather than taken whole,
// the short way round the circle.
export function smoothHeading(previous:number|undefined, next:number, weight=.3):number {
  if (previous === undefined) return next
  return (previous + (((next - previous + 540) % 360) - 180) * weight + 360) % 360
}
export const headingGap = (a:number, b:number) => Math.abs(((a - b + 540) % 360) - 180)

export async function requestCompass():Promise<boolean> {
  if (!compassAvailable()) return false
  const ask = (DeviceOrientationEvent as unknown as { requestPermission?: () => Promise<string> }).requestPermission
  if (typeof ask !== 'function') return true
  try { return await ask.call(DeviceOrientationEvent) === 'granted' } catch { return false }
}
// Only meaningful turns are reported on, so the map is not re-rendered for a
// degree of noise.
export function watchHeading(onHeading:(degrees:number)=>void) {
  const type = 'ondeviceorientationabsolute' in window ? 'deviceorientationabsolute' : 'deviceorientation'
  let smoothed:number|undefined, reported:number|undefined
  const handler = (event:Event) => {
    const heading = headingFrom(event as DeviceOrientationEvent, screenAngle())
    if (heading === undefined) return
    smoothed = smoothHeading(smoothed, heading)
    if (reported !== undefined && headingGap(smoothed, reported) < 2) return
    reported = smoothed
    onHeading(smoothed)
  }
  window.addEventListener(type, handler)
  return () => window.removeEventListener(type, handler)
}

export const speechAvailable = () => typeof window!=='undefined' && 'speechSynthesis' in window
// iOS only lets the synth start from inside a user gesture, so the walk button
// primes it with a silent utterance; later prompts then fire from the GPS watch.
export function primeSpeech(){ if(!speechAvailable()) return; const u=new SpeechSynthesisUtterance(' '); u.volume=0; window.speechSynthesis.speak(u) }
export function speak(text:string){ if(!speechAvailable()) return; const u=new SpeechSynthesisUtterance(text); u.rate=1; u.lang='en-GB'; window.speechSynthesis.cancel(); window.speechSynthesis.speak(u) }
export const stopSpeaking = () => { if(speechAvailable()) window.speechSynthesis.cancel() }
