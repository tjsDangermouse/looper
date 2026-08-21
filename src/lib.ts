export type Point = [number, number]
export type Step = { instruction: string; distanceMeters: number; durationSeconds: number; startIndex?: number; endIndex?: number; maneuver?: string }
export type Route = { id: string; name: string; cue?: string; distanceMeters: number; durationSeconds: number; targetDifferencePercent: number; geometry: {type:'LineString'; coordinates: Point[]}; steps: Step[] }
export const kmToMiles = (km:number) => km * 0.621371
export const milesToKm = (mi:number) => mi / 0.621371
export const estimateKmFromMinutes = (minutes:number) => minutes / 12
export const formatDistance = (meters:number, unit:'km'|'mi'='km') => unit === 'km' ? `${(meters/1000).toFixed(1)} km` : `${kmToMiles(meters/1000).toFixed(1)} mi`
export const formatTime = (seconds:number) => `${Math.round(seconds / 60)} min`
export const haversine = (a:Point,b:Point) => { const r=6371000, rad=Math.PI/180, dLat=(b[1]-a[1])*rad,dLng=(b[0]-a[0])*rad; const x=Math.sin(dLat/2)**2+Math.cos(a[1]*rad)*Math.cos(b[1]*rad)*Math.sin(dLng/2)**2; return 2*r*Math.atan2(Math.sqrt(x),Math.sqrt(1-x)) }
export function nearestProgress(point:Point, coords:Point[]) { let best=Infinity, index=0, before=0; for(let i=0;i<coords.length;i++){ const d=haversine(point,coords[i]); if(d<best){best=d;index=i} if(i<index) before+=haversine(coords[i],coords[i+1]||coords[i]) } return { distanceToRoute:best, index, distanceAlong:before } }
export function nextTurn(route:Route, progressMeters:number) { let total=0; for(let i=0;i<route.steps.length;i++){ const step=route.steps[i]; total+=step.distanceMeters; if(total>progressMeters) return {...step, index:i, distanceAway:total-progressMeters} } return undefined }
/** An SVG path for the little route-shape thumbnail on each card. The loop is
 *  flattened to metres first — using raw degrees would squash every shape at
 *  British latitudes — then fitted to the box with its aspect ratio intact, so
 *  a round loop looks round and a thin one looks thin. */
export function previewPath(coords:Point[], size=40, pad=3) {
  if (coords.length < 2) return ''
  const rad=Math.PI/180, scale=Math.cos(coords[0][1]*rad)
  const flat=coords.map(([lng,lat])=>[lng*scale,lat] as Point)
  const xs=flat.map(p=>p[0]), ys=flat.map(p=>p[1])
  const minX=Math.min(...xs), maxX=Math.max(...xs), minY=Math.min(...ys), maxY=Math.max(...ys)
  const span=Math.max(maxX-minX, maxY-minY) || 1, box=size-pad*2
  const x=(v:number)=>pad+box/2+(v-(minX+maxX)/2)/span*box
  const y=(v:number)=>pad+box/2-(v-(minY+maxY)/2)/span*box
  // A 20 km loop can carry thousands of vertices; ~64 is plenty at 40 px.
  const step=Math.max(1, Math.floor(flat.length/64))
  const points=flat.filter((_,i)=>i%step===0||i===flat.length-1)
  return points.map((p,i)=>`${i?'L':'M'}${x(p[0]).toFixed(1)} ${y(p[1]).toFixed(1)}`).join(' ')
}

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

export const speechAvailable = () => typeof window!=='undefined' && 'speechSynthesis' in window
// iOS only lets the synth start from inside a user gesture, so the walk button
// primes it with a silent utterance; later prompts then fire from the GPS watch.
export function primeSpeech(){ if(!speechAvailable()) return; const u=new SpeechSynthesisUtterance(' '); u.volume=0; window.speechSynthesis.speak(u) }
export function speak(text:string){ if(!speechAvailable()) return; const u=new SpeechSynthesisUtterance(text); u.rate=1; u.lang='en-GB'; window.speechSynthesis.cancel(); window.speechSynthesis.speak(u) }
export const stopSpeaking = () => { if(speechAvailable()) window.speechSynthesis.cancel() }
