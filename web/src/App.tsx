import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { MapView } from './MapView'
import { CheckIcon, ClockIcon, CloseIcon, CompassIcon, LocateIcon, LoopIcon, ReverseIcon, SoundOffIcon, SoundOnIcon, TurnIcon, WalkIcon } from './icons'
import { compassAvailable, requestCompass, watchHeading, routeColours, estimateKmFromMinutes, requestLoops, reverseRoute, formatDistance, formatTime, nearestProgress, nextTurn, primeSpeech, speak, speechAvailable, stopSpeaking, turnAnnouncement, turnKind, type Point, type Route } from './lib'
// Generating a set of loops means routing dozens of candidates and measuring
// every one, which takes a few seconds. Saying what is being done beats a
// spinner that could mean anything.
const FINDING=['Building clean loops around you…','Checking for overlaps and detours…']
// The service explores up to three adjacent variations for one search. Leave
// that space between requests so refresh begins with genuinely new bearings.
const VARIATION_STRIDE=3
const freshVariation = () => Math.floor(Math.random()*300)*VARIATION_STRIDE
type Screen='welcome'|'planner'|'choices'|'walk'
const DEFAULT:Point=[-4.517837412123816,54.15767997688426] // Home
export function LooperApp(){const [screen,setScreen]=useState<Screen>('welcome'),[start,setStart]=useState<Point>(DEFAULT),[position,setPosition]=useState<Point>(),[locationState,setLocationState]=useState(''),[mode,setMode]=useState<'distance'|'time'>('distance'),[unit,setUnit]=useState<'km'|'mi'>('km'),[amount,setAmount]=useState('4'),[routes,setRoutes]=useState<Route[]>([]),[selected,setSelected]=useState<Route>(),[busy,setBusy]=useState(false),[error,setError]=useState(''),[muted,setMuted]=useState(false),[offRoute,setOffRoute]=useState(false),[progress,setProgress]=useState(0),[following,setFollowing]=useState(false),[courseUp,setCourseUp]=useState(false),[heading,setHeading]=useState<number>(),[reversed,setReversed]=useState(false),[sheetOpen,setSheetOpen]=useState(true),[padding,setPadding]=useState({bottom:0,right:0}),[stage,setStage]=useState(0)
 // A second "find new loops" tap before the first has answered means two
 // requests can finish out of order. Only the most recently *started* one
 // is allowed to write its result.
 const requestSeq=useRef(0)
 // The sheet covers part of the map, so measure it and hand the map the padding
 // that keeps the start marker centred in the *visible* strip, not the viewport.
  const spoken=useRef(''), walked=useRef(0), voice=useMemo(speechAvailable,[]), compass=useMemo(compassAvailable,[])
 // Discovery favours variety.  A new app session starts from a fresh candidate
 // set, while refresh skips the variations the previous request explored.
 const lastAsk=useRef({key:'',variation:freshVariation()})
 useEffect(()=>{if(!busy){setStage(0);return}const timer=setTimeout(()=>setStage(1),2500);return()=>clearTimeout(timer)},[busy])
 const sheetRef=useCallback((el:HTMLElement|null)=>{if(!el){setPadding({bottom:0,right:0});return}
  const measure=()=>{const box=el.getBoundingClientRect();const side=box.height>=window.innerHeight*.9
   ;setPadding(side?{bottom:0,right:Math.round(box.width)}:{bottom:Math.round(box.height),right:0})}
  measure();const observer=new ResizeObserver(measure);observer.observe(el)
  window.addEventListener('resize',measure);window.addEventListener('orientationchange',measure)
  return()=>{observer.disconnect();window.removeEventListener('resize',measure);window.removeEventListener('orientationchange',measure)}},[])
 const requestLocation=()=>{if(!navigator.geolocation){setLocationState('Location is not available in this browser.');return}setLocationState('Finding your location…');(navigator.geolocation.getCurrentPosition as any)((p:any)=>{const point:Point=[p.coords.longitude,p.coords.latitude];setStart(point);setPosition(point);setLocationState('');setScreen('planner')},(e:any)=>setLocationState(e.code===1?'Location permission was declined. Choose a start point on the map.':'We could not get a location. Choose a start point on the map.'),{enableHighAccuracy:true,timeout:12000,maximumAge:15000})}
 const distanceKm=useMemo(()=>mode==='time'?estimateKmFromMinutes(Number(amount)):unit==='mi'?Number(amount)/.621371:Number(amount),[mode,unit,amount])
 const valid=mode==='time'?Number(amount)>=15&&Number(amount)<=240:distanceKm>=1&&distanceKm<=20
 // Either way round the loop is the same streets, so a reversal is derived
 // from the fetched routes rather than asked of the router again.
 const shown=useMemo(()=>reversed?routes.map(reverseRoute):routes,[routes,reversed])
 const toggleReversed=()=>{setReversed(r=>!r);setSelected(s=>s&&reverseRoute(s))}
 // Every ordinary search asks the discovery engine for a fresh set. The
 // variation is still stable throughout one request, so its internal quality
 // decisions remain reproducible while the next search explores elsewhere.
 async function findRoutes(){if(!valid){setError(mode==='time'?'Choose 15 minutes to 4 hours.':'Choose a loop between 1 and 20 km.');return}if(!navigator.onLine){setError('You’re offline. Route generation needs a connection; saved walks are still available.');return}
  const key=`${start[0].toFixed(5)},${start[1].toFixed(5)}|${mode}|${amount}|${unit}`
  const sameSpot=lastAsk.current.key===key
  const variation=sameSpot?(lastAsk.current.variation+VARIATION_STRIDE)%900:freshVariation()
  lastAsk.current={key,variation}
  const seq=++requestSeq.current
  setBusy(true);setStage(0);setError('');setReversed(false)
  try{const {routes:choices,warning}=await requestLoops({start,mode,distanceKm:mode==='distance'?distanceKm:undefined,durationMinutes:mode==='time'?Number(amount):undefined,unit,variation,excludeRoutes:sameSpot?routes:undefined})
   if(seq!==requestSeq.current)return // a later request already started; its result is the one that counts
   if(!choices.length)throw new Error(warning||'We couldn’t find a clean loop of that length from here. Try a different distance or move the start point.')
   setRoutes(choices);setSelected(choices[0]);setScreen('choices')
   setError(warning||'')
  }catch(e){if(seq===requestSeq.current)setError(e instanceof Error?e.message:'Routes are unavailable right now.')}finally{if(seq===requestSeq.current)setBusy(false)}}
 function beginWalk(r:Route){if(!muted)primeSpeech();spoken.current='';walked.current=0;setProgress(0);setFollowing(true);setSelected(r);setScreen('walk');localStorage.setItem('looper-route',JSON.stringify(r))}
 // The compass is only read while it is being used, and iOS only grants it
 // from inside the tap that asks for it.
 useEffect(()=>{if(!courseUp||screen!=='walk')return;return watchHeading(setHeading)},[courseUp,screen])
 async function toggleCourseUp(){if(courseUp){setCourseUp(false);return}
  if(!await requestCompass()){setLocationState('Compass access was declined, so the map stays north-up.');return}
  setLocationState('');setCourseUp(true)}
 function toggleMute(){const next=!muted;setMuted(next);if(next)stopSpeaking();else{primeSpeech();spoken.current=''}}
 useEffect(()=>{if(screen!=='walk'||!navigator.geolocation||!selected)return;let bad=0;walked.current=0;setProgress(0);const id=(navigator.geolocation.watchPosition as any)((p:any)=>{if(p.coords.accuracy>100){setLocationState('Waiting for a more accurate location…');return}setLocationState('');const point:Point=[p.coords.longitude,p.coords.latitude];setPosition(point);const match=nearestProgress(point,selected.geometry.coordinates,walked.current);walked.current=match.distanceAlong;setProgress(match.distanceAlong);bad=match.distanceToRoute>55?bad+1:0;setOffRoute(bad>=3)},undefined,{enableHighAccuracy:true,timeout:15000,maximumAge:5000});return()=>navigator.geolocation.clearWatch(id)},[screen,selected])
 const turn=selected&&nextTurn(selected,progress), remaining=selected?Math.max(0,selected.distanceMeters-progress):0
 // Speak each turn once per distance band, plus one warning when the walk
 // strays off the loop. Falling silent on mute or on leaving the walk screen.
 useEffect(()=>{if(screen!=='walk'||muted)return
  if(offRoute){if(spoken.current!=='off'){spoken.current='off';speak('You are off the planned loop. Head back to the route.')}return}
  if(spoken.current==='off')spoken.current=''
  const announcement=turnAnnouncement(turn||undefined,unit)
  if(announcement){if(spoken.current!==announcement.key){spoken.current=announcement.key;speak(announcement.text)}return}
  if(!turn&&spoken.current!=='home'){spoken.current='home';speak('You are back where you started.')}},[screen,muted,offRoute,turn?.index,turn&&turnAnnouncement(turn,unit)?.key,unit])
 useEffect(()=>()=>stopSpeaking(),[])
 useEffect(()=>{if(screen!=='walk')stopSpeaking()},[screen])
 return <main>{screen==='welcome'&&<section className="welcome"><div className="loop-mark"><LoopIcon size={42}/></div><p className="eyebrow">a route with a way back</p><h1>Looper</h1><p className="lede">Find your route. Make it loop.</p><div className="welcome-actions"><button className="primary" onClick={requestLocation}><LocateIcon size={20}/>Use my location</button><button className="secondary" onClick={()=>setScreen('planner')}>Choose on map</button></div>{locationState&&<p className="notice">{locationState}</p>}<p className="privacy">Your location stays on your device.</p><p className="credit">OpenFreeMap © OpenMapTiles · data © OpenStreetMap contributors</p><button className="help" onClick={()=>setLocationState('Keep Looper open while walking for live guidance. Guidance may pause when your phone is locked.')}>How live guidance works</button></section>}
 {screen!=='welcome'&&<><MapView start={start} routes={shown} selected={selected?.id} position={position} follow={following&&screen==='walk'} walking={screen==='walk'} heading={heading} courseUp={courseUp&&screen==='walk'} onFollowChange={setFollowing} onPoint={screen==='planner'?setStart:()=>{}} padding={padding}/><div className="brand"><LoopIcon size={17}/><span>Looper</span></div>{screen!=="walk"&&<button className="locate-fab" aria-label="Use my location" style={{bottom:padding.bottom+16,right:padding.right+16}} onClick={requestLocation}><LocateIcon/></button>}{screen==='planner'&&<section ref={sheetRef} className={"sheet planner"+(sheetOpen?"":" collapsed")}><button className="handle" aria-label={sheetOpen?"Collapse panel":"Expand panel"} aria-expanded={sheetOpen} onClick={()=>setSheetOpen(!sheetOpen)}/><div className="sheet-head"><div onClick={()=>setSheetOpen(true)}><p className="eyebrow">start point · tap map to move</p><h2>How far shall we walk?</h2></div><button className="link" onClick={requestLocation}>Use my location</button></div><div className="sheet-body"><div className="seg"><button className={mode==='distance'?'on':''} onClick={()=>setMode('distance')}><WalkIcon/>Distance</button><button className={mode==='time'?'on':''} onClick={()=>setMode('time')}><ClockIcon/>Time</button></div><label className="field-label" htmlFor="amount">{mode==='distance'?'Your distance':'Your time'}</label><div className="value-row"><input id="amount" aria-label={mode==='distance'?'Distance':'Minutes'} value={amount} inputMode="decimal" onChange={e=>setAmount(e.target.value)}/>{mode==='distance'?<div className="unit"><button className={unit==='km'?'on':''} onClick={()=>setUnit('km')}>km</button><button className={unit==='mi'?'on':''} onClick={()=>setUnit('mi')}>mi</button></div>:<span>minutes</span>}</div>{error?<p className="notice">{error}</p>:<p className="hint">{mode==='distance'?`Enter any distance from 1–20 ${unit}`:'Enter any time from 15 minutes to 4 hours'}</p>}</div><div className="sheet-foot"><button disabled={busy} className="primary find" onClick={()=>findRoutes()}><LoopIcon size={22}/>{busy?FINDING[stage]:'Find my loops'}</button></div></section>}
 {screen==='choices'&&<section ref={sheetRef} className="sheet choices"><div className="handle"/><div className="sheet-head sheet-title"><div><p className="eyebrow">your choices</p><h2>Pick a loop</h2></div><div className="head-actions"><button className={'icon-btn'+(busy?' busy':'')} aria-label="Find three new loops" title="Find three new loops" disabled={busy} onClick={()=>findRoutes()}><LoopIcon size={18}/></button><button className={'icon-btn'+(reversed?' on':'')} aria-label="Walk the loop the other way round" aria-pressed={reversed} title="Walk the loop the other way round" onClick={toggleReversed}><ReverseIcon size={18}/></button><button className="text" onClick={()=>setScreen('planner')}>Edit</button></div></div><div className="sheet-body">{error&&<p className="notice">{error}</p>}{shown.map((r,i)=><button className={'route-card'+(selected?.id===r.id?' on':'')} aria-pressed={selected?.id===r.id} key={r.id} onClick={()=>setSelected(r)}><i style={{background:routeColours[i%routeColours.length]}}/><div><strong>{r.name}</strong><p>{formatDistance(r.distanceMeters,unit)} · {formatTime(r.durationSeconds)} · {Math.abs(r.targetDifferencePercent)}% {r.targetDifferencePercent<0?'shorter':'longer'}</p></div>{selected?.id===r.id&&<span className="tick"><CheckIcon/></span>}</button>)}</div></section>}
 {screen==='choices'&&selected&&<button className="primary start-fab" style={{bottom:padding.bottom+16,left:`calc((100% - ${padding.right}px) / 2)`}} onClick={()=>beginWalk(selected)}><WalkIcon size={20}/>Start walk</button>}
 {screen==='walk'&&selected&&<section className="walk-ui"><header><button className="icon-btn" aria-label="End walk" title="End walk" onClick={()=>{setFollowing(false);setCourseUp(false);setScreen('choices')}}><CloseIcon/></button><button className={'icon-btn'+(following?' on':'')} aria-label="Follow my location" aria-pressed={following} title="Follow my location" onClick={()=>setFollowing(true)}><LocateIcon size={19}/></button><button disabled={!compass} className={'icon-btn'+(courseUp?' on':'')} aria-label={!compass?'A compass is not available in this browser':courseUp?'Map turns with you':'Map faces north'} aria-pressed={courseUp&&compass} title={!compass?'A compass is not available in this browser':courseUp?'Map turns with you':'Map faces north'} onClick={toggleCourseUp}><CompassIcon/></button><button disabled={!voice} className={'icon-btn'+(muted||!voice?'':' on')} aria-label={!voice?'Voice guidance is unavailable in this browser':muted?'Voice guidance off':'Voice guidance on'} aria-pressed={!muted&&voice} title={!voice?'Voice guidance is unavailable in this browser':muted?'Voice guidance off':'Voice guidance on'} onClick={toggleMute}>{muted||!voice?<SoundOffIcon/>:<SoundOnIcon/>}</button></header>{locationState&&<p className="gps">{locationState}</p>}{offRoute?<div ref={sheetRef} className="guidance warning"><b>You’re off the planned loop</b><p>Get back to the route, or finish this walk.</p><button className="primary" onClick={()=>setOffRoute(false)}>Show route from here</button><button className="text" onClick={()=>{setFollowing(false);setScreen('choices')}}>End walk</button></div>:<div ref={sheetRef} className={'guidance '+(turn&&turn.distanceAway<20?'close':'')}><span className="arrow"><TurnIcon turn={turnKind(turn||undefined)}/></span><div><p className="eyebrow">{turn?`${Math.round(turn.distanceAway)} m ahead`:'Almost home'}</p><h2>{turn?.instruction||'You’re back where you started.'}</h2><p>{formatDistance(remaining,unit)} remaining · about {formatTime(remaining/selected.distanceMeters*selected.durationSeconds)}</p></div></div>}</section>}</>}</main>}
export function App(){return <LooperApp/>}
