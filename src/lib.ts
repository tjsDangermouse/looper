export type Point = [number, number]
export type Step = { instruction: string; distanceMeters: number; durationSeconds: number; startIndex?: number; endIndex?: number; maneuver?: string }
export type Route = { id: string; name: string; distanceMeters: number; durationSeconds: number; targetDifferencePercent: number; geometry: {type:'LineString'; coordinates: Point[]}; steps: Step[] }
export const kmToMiles = (km:number) => km * 0.621371
export const milesToKm = (mi:number) => mi / 0.621371
export const estimateKmFromMinutes = (minutes:number) => minutes / 12
export const formatDistance = (meters:number, unit:'km'|'mi'='km') => unit === 'km' ? `${(meters/1000).toFixed(1)} km` : `${kmToMiles(meters/1000).toFixed(1)} mi`
export const formatTime = (seconds:number) => `${Math.round(seconds / 60)} min`
export const haversine = (a:Point,b:Point) => { const r=6371000, rad=Math.PI/180, dLat=(b[1]-a[1])*rad,dLng=(b[0]-a[0])*rad; const x=Math.sin(dLat/2)**2+Math.cos(a[1]*rad)*Math.cos(b[1]*rad)*Math.sin(dLng/2)**2; return 2*r*Math.atan2(Math.sqrt(x),Math.sqrt(1-x)) }
export function nearestProgress(point:Point, coords:Point[]) { let best=Infinity, index=0, before=0; for(let i=0;i<coords.length;i++){ const d=haversine(point,coords[i]); if(d<best){best=d;index=i} if(i<index) before+=haversine(coords[i],coords[i+1]||coords[i]) } return { distanceToRoute:best, index, distanceAlong:before } }
export function nextTurn(route:Route, progressMeters:number) { let total=0; for(const step of route.steps){ total+=step.distanceMeters; if(total>progressMeters) return {...step, distanceAway:total-progressMeters} } return undefined }
export function dedupeRoutes(routes:Route[]) { return routes.filter((route,i)=>!routes.slice(0,i).some(other=>{const a=route.geometry.coordinates,b=other.geometry.coordinates; const samples=8; let matches=0; for(let s=0;s<samples;s++){const p=a[Math.floor(s*(a.length-1)/(samples-1))],q=b[Math.floor(s*(b.length-1)/(samples-1))]; if(p&&q&&haversine(p,q)<160) matches++} return matches/samples>.7 })) }
