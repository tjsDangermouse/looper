export type Point = [number, number]
export type Step = { instruction: string; distanceMeters: number; durationSeconds: number; startIndex?: number; endIndex?: number; maneuver?: string|number; road?: string }
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
export function nextTurn(route:Route, progressMeters:number) { let total=0; for(let i=0;i<route.steps.length;i++){ const step=route.steps[i]; total+=step.distanceMeters; if(total>progressMeters) return {...step, index:i, distanceAway:total-progressMeters} } return undefined }
// Walking the loop the other way round. The app reads a step's instruction as
// the turn taken at the *end* of that step, so reversing keeps the segments in
// the opposite order and hands each one the turn it now ends on: the same
// corner, mirrored (a left going one way is a right coming back), naming the
// road the walk is about to join rather than the one it joined before.
const mirror = (instruction:string) => instruction.replace(/\bleft\b/gi,'\u0000').replace(/\bright\b/gi,'left').replace(/\u0000/g,'right')
const onto = (instruction:string, road?:string) => { const bare=instruction.replace(/\s+onto\s+.+$/i,''); return road?`${bare} onto ${road}`:bare }
export function reverseRoute(route:Route):Route {
  const walked = route.steps.filter(step=>step.distanceMeters>0)
  const steps:Step[] = walked.map((_,i)=>{ const index=walked.length-1-i, step=walked[index], joins=walked[index-1]
    return { ...step, maneuver: joins?mirrorTurn(turnKind(step)):'arrive', instruction: joins?onto(mirror(step.instruction), joins.road):'Arrive at your starting point' } })
  return { ...route, reversed:!route.reversed, steps, geometry:{...route.geometry, coordinates:[...route.geometry.coordinates].reverse()} }
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

export function dedupeRoutes(routes:Route[]) { return routes.filter((route,i)=>!routes.slice(0,i).some(other=>{const a=route.geometry.coordinates,b=other.geometry.coordinates; const samples=8; let matches=0; for(let s=0;s<samples;s++){const p=a[Math.floor(s*(a.length-1)/(samples-1))],q=b[Math.floor(s*(b.length-1)/(samples-1))]; if(p&&q&&haversine(p,q)<160) matches++} return matches/samples>.7 })) }

// Voice guidance. A turn is announced at most once per band, so walking through
// 400 m → 100 m → the corner itself gives three prompts and no repetition.
export type Band='soon'|'near'|'now'
export const turnBand = (metresAway:number):Band|undefined => metresAway<30?'now':metresAway<120?'near':metresAway<450?'soon':undefined
const lead = (band:Band, unit:'km'|'mi') => band==='near'?(unit==='mi'?'In one hundred yards, ':'In one hundred metres, '):(unit==='mi'?'In a quarter of a mile, ':'In four hundred metres, ')
// Instructions arrive sentence-cased ("Turn left onto…"); lower the first word
// when it follows a lead-in so the sentence reads as one phrase.
const joinCase = (instruction:string) => instruction.replace(/^[A-Z](?![A-Z])/, c=>c.toLowerCase())
export function turnAnnouncement(turn:{index:number; instruction:string; distanceAway:number}|undefined, unit:'km'|'mi') {
  if(!turn) return undefined
  const band=turnBand(turn.distanceAway); if(!band) return undefined
  return { key:`${turn.index}:${band}`, text:band==='now'?turn.instruction:lead(band,unit)+joinCase(turn.instruction) }
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
