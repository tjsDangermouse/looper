import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { MapView } from './MapView'
import { ClockIcon, CloseIcon, LocateIcon, LoopIcon, SoundOffIcon, SoundOnIcon, WalkIcon } from './icons'
import { estimateKmFromMinutes, formatDistance, formatTime, nearestProgress, nextTurn, previewPath, primeSpeech, speak, speechAvailable, stopSpeaking, turnAnnouncement, type Point, type Route } from './lib'
type Screen='welcome'|'planner'|'choices'|'walk'
const DEFAULT:Point=[-4.4816,54.1506] // Douglas, Isle of Man
export function LooperApp(){const [screen,setScreen]=useState<Screen>('welcome'),[start,setStart]=useState<Point>(DEFAULT),[position,setPosition]=useState<Point>(),[locationState,setLocationState]=useState(''),[mode,setMode]=useState<'distance'|'time'>('distance'),[unit,setUnit]=useState<'km'|'mi'>('km'),[amount,setAmount]=useState('4'),[routes,setRoutes]=useState<Route[]>([]),[selected,setSelected]=useState<Route>(),[phase,setPhase]=useState<''|'building'|'checking'>(''),[error,setError]=useState(''),[noClean,setNoClean]=useState(false),[muted,setMuted]=useState(false),[offRoute,setOffRoute]=useState(false),[progress,setProgress]=useState(0),[sheetOpen,setSheetOpen]=useState(true),[padding,setPadding]=useState({bottom:0,right:0})
 // The sheet covers part of the map, so measure it and hand the map the padding
 // that keeps the start marker centred in the *visible* strip, not the viewport.
  const spoken=useRef(''), voice=useMemo(speechAvailable,[])
 const sheetRef=useCallback((el:HTMLElement|null)=>{if(!el){setPadding({bottom:0,right:0});return}
  const measure=()=>{const box=el.getBoundingClientRect();const side=box.height>=window.innerHeight*.9
   ;setPadding(side?{bottom:0,right:Math.round(box.width)}:{bottom:Math.round(box.height),right:0})}
  measure();const observer=new ResizeObserver(measure);observer.observe(el)
  window.addEventListener('resize',measure);window.addEventListener('orientationchange',measure)
  return()=>{observer.disconnect();window.removeEventListener('resize',measure);window.removeEventListener('orientationchange',measure)}},[])
 const requestLocation=()=>{if(!navigator.geolocation){setLocationState('Location is not available in this browser.');return}setLocationState('Finding your location…');(navigator.geolocation.getCurrentPosition as any)((p:any)=>{const point:Point=[p.coords.longitude,p.coords.latitude];setStart(point);setPosition(point);setLocationState('');setScreen('planner')},(e:any)=>setLocationState(e.code===1?'Location permission was declined. Choose a start point on the map.':'We could not get a location. Choose a start point on the map.'),{enableHighAccuracy:true,timeout:12000,maximumAge:15000})}
 const distanceKm=useMemo(()=>mode==='time'?estimateKmFromMinutes(Number(amount)):unit==='mi'?Number(amount)/.621371:Number(amount),[mode,unit,amount])
 const valid=mode==='time'?Number(amount)>=15&&Number(amount)<=240:distanceKm>=1&&distanceKm<=20
 // A second search must not be overtaken by the first: the older request is
 // aborted, and any response that arrives from a superseded search is dropped.
 const search=useRef<AbortController>(undefined), searchId=useRef(0)
 async function findRoutes(){
  if(!valid){setError(mode==='time'?'Choose 15 minutes to 4 hours.':'Choose a loop between 1 and 20 km.');return}
  if(!navigator.onLine){setError('You’re offline. Route generation needs a connection; saved walks are still available.');return}
  search.current?.abort();const controller=search.current=new AbortController(),id=++searchId.current
  setPhase('building');setError('');setNoClean(false)
  // The two phases are honest about what the server is doing: the ORS calls
  // dominate the wait, then scoring runs over the pool that comes back.
  const toChecking=setTimeout(()=>{if(searchId.current===id)setPhase('checking')},2200)
  try{
   const r=await fetch('/api/routes',{method:'POST',signal:controller.signal,headers:{'Content-Type':'application/json'},body:JSON.stringify({start:{lng:start[0],lat:start[1]},inputMode:mode,unit,distanceKm:mode==='distance'?distanceKm:undefined,minutes:mode==='time'?Number(amount):undefined})})
   const data=await r.json()
   if(searchId.current!==id)return
   if(!r.ok)throw new Error(data.error||'Routes are unavailable right now.')
   const choices:Route[]=data.routes||[]
   setRoutes(choices);setSelected(undefined)
   if(!choices.length){setNoClean(true);return}
   setScreen('choices')
   setError(choices.length<3?`We found ${choices.length} clean loop${choices.length===1?'':'s'} from here.`:'')
  }catch(e){
   if(controller.signal.aborted||searchId.current!==id)return
   setError(e instanceof Error?e.message:'Routes are unavailable right now.')
  }finally{clearTimeout(toChecking);if(searchId.current===id)setPhase('')}
 }
 // Nudging the target by a fifth is enough to reach a different part of the
 // path network; anything smaller usually fails for the same reason again.
 function retryAt(factor:number){const next=Number(amount)*factor;setAmount(mode==='time'?String(Math.round(next)):String(Math.round(next*10)/10));setNoClean(false)}
 function beginWalk(r:Route){if(!muted)primeSpeech();spoken.current='';setSelected(r);setScreen('walk');localStorage.setItem('looper-route',JSON.stringify(r))}
 function toggleMute(){const next=!muted;setMuted(next);if(next)stopSpeaking();else{primeSpeech();spoken.current=''}}
 useEffect(()=>{if(screen!=='walk'||!navigator.geolocation||!selected)return;let bad=0;const id=(navigator.geolocation.watchPosition as any)((p:any)=>{if(p.coords.accuracy>100){setLocationState('Waiting for a more accurate location…');return}setLocationState('');const point:Point=[p.coords.longitude,p.coords.latitude];setPosition(point);const match=nearestProgress(point,selected.geometry.coordinates);setProgress(old=>Math.max(old,match.distanceAlong));bad=match.distanceToRoute>55?bad+1:0;setOffRoute(bad>=3)},undefined,{enableHighAccuracy:true,timeout:15000,maximumAge:5000});return()=>navigator.geolocation.clearWatch(id)},[screen,selected])
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
 return <main>{screen==='welcome'&&<section className="welcome"><div className="loop-mark"><LoopIcon size={42}/></div><p className="eyebrow">a walk with a way back</p><h1>Looper</h1><p className="lede">Find a walk that brings you back.</p><div className="welcome-actions"><button className="primary" onClick={requestLocation}><LocateIcon size={20}/>Use my location</button><button className="secondary" onClick={()=>setScreen('planner')}>Choose on map</button></div>{locationState&&<p className="notice">{locationState}</p>}<p className="privacy">Your location stays on your device.</p><p className="credit">Maps © OpenStreetMap contributors</p><button className="help" onClick={()=>setLocationState('Keep Looper open while walking for live guidance. Guidance may pause when your phone is locked.')}>How live guidance works</button></section>}
 {screen!=='welcome'&&<><MapView start={start} routes={routes} selected={selected?.id} position={position} onPoint={setStart} padding={padding}/><div className="brand"><LoopIcon size={17}/><span>Looper</span></div>{screen!=="walk"&&<button className="locate-fab" aria-label="Use my location" style={{bottom:padding.bottom+16,right:padding.right+16}} onClick={requestLocation}><LocateIcon/></button>}{screen==='planner'&&<section ref={sheetRef} className={"sheet planner"+(sheetOpen?"":" collapsed")}><button className="handle" aria-label={sheetOpen?"Collapse panel":"Expand panel"} aria-expanded={sheetOpen} onClick={()=>setSheetOpen(!sheetOpen)}/><div className="sheet-head"><div onClick={()=>setSheetOpen(true)}><p className="eyebrow">start point · tap map to move</p><h2>How far shall we walk?</h2></div><button className="link" onClick={requestLocation}>Use my location</button></div><div className="sheet-body"><div className="seg"><button className={mode==='distance'?'on':''} onClick={()=>setMode('distance')}><WalkIcon/>Distance</button><button className={mode==='time'?'on':''} onClick={()=>setMode('time')}><ClockIcon/>Time</button></div><label className="field-label" htmlFor="amount">{mode==='distance'?'Your distance':'Your time'}</label><div className="value-row"><input id="amount" aria-label={mode==='distance'?'Distance':'Minutes'} value={amount} inputMode="decimal" onChange={e=>setAmount(e.target.value)}/>{mode==='distance'?<div className="unit"><button className={unit==='km'?'on':''} onClick={()=>setUnit('km')}>km</button><button className={unit==='mi'?'on':''} onClick={()=>setUnit('mi')}>mi</button></div>:<span>minutes</span>}</div>{noClean?<div className="no-loop"><p><b>We couldn’t find a clean loop of that length from here.</b></p><div className="no-loop-actions"><button className="text" onClick={()=>retryAt(1.2)}>Try longer</button><button className="text" onClick={()=>retryAt(.8)}>Try shorter</button><button className="text" onClick={()=>setNoClean(false)}>Move the start point</button></div></div>:error?<p className="notice">{error}</p>:<p className="hint">{mode==='distance'?`Enter any distance from 1–20 ${unit}`:'Enter any time from 15 minutes to 4 hours'}</p>}</div><div className="sheet-foot"><button disabled={!!phase} className="primary find" onClick={findRoutes}><LoopIcon size={22}/>{phase==='building'?'Building clean loops around you…':phase==='checking'?'Checking for overlaps and detours…':'Find my loops'}</button></div></section>}
 {screen==='choices'&&<section ref={sheetRef} className="sheet choices"><div className="handle"/><div className="sheet-head sheet-title"><div><p className="eyebrow">your choices</p><h2>Pick a loop</h2></div><button className="text" onClick={()=>setScreen('planner')}>Edit</button></div><div className="sheet-body">{error&&<p className="notice">{error}</p>}{routes.map((r,i)=><article className="route-card" key={r.id} onClick={()=>setSelected(r)}><i style={{background:['#9cc36b','#5fa8d3','#e0a35c'][i]}}/><svg className="shape" viewBox="0 0 40 40" aria-hidden="true"><path d={previewPath(r.geometry.coordinates)} fill="none" stroke={['#9cc36b','#5fa8d3','#e0a35c'][i]} strokeWidth={2.4} strokeLinecap="round" strokeLinejoin="round"/></svg><div><strong>{r.name}</strong>{r.cue&&<em className="cue">{r.cue}</em>}<p>{formatDistance(r.distanceMeters,unit)} · {formatTime(r.durationSeconds)}</p></div><button className="choose" onClick={e=>{e.stopPropagation();beginWalk(r)}}>Choose</button></article>)}</div></section>}
 {screen==='walk'&&selected&&<section className="walk-ui"><header><button className="icon-btn" aria-label="End walk" title="End walk" onClick={()=>setScreen('choices')}><CloseIcon/></button><button className="icon-btn" aria-label="Centre on my location" title="Centre on my location" onClick={requestLocation}><LocateIcon size={19}/></button><button disabled={!voice} className={'icon-btn'+(muted||!voice?'':' on')} aria-label={!voice?'Voice guidance is unavailable in this browser':muted?'Voice guidance off':'Voice guidance on'} aria-pressed={!muted&&voice} title={!voice?'Voice guidance is unavailable in this browser':muted?'Voice guidance off':'Voice guidance on'} onClick={toggleMute}>{muted||!voice?<SoundOffIcon/>:<SoundOnIcon/>}</button></header>{locationState&&<p className="gps">{locationState}</p>}{offRoute?<div className="guidance warning"><b>You’re off the planned loop</b><p>Get back to the route, or finish this walk.</p><button className="primary" onClick={()=>setOffRoute(false)}>Show route from here</button><button className="text" onClick={()=>setScreen('choices')}>End walk</button></div>:<div className={'guidance '+(turn&&turn.distanceAway<20?'close':'')}><span className="arrow">↰</span><div><p className="eyebrow">{turn?`${Math.round(turn.distanceAway)} m ahead`:'Almost home'}</p><h2>{turn?.instruction||'You’re back where you started.'}</h2><p>{formatDistance(remaining,unit)} remaining · about {formatTime(remaining/selected.distanceMeters*selected.durationSeconds)}</p></div></div>}</section>}</>}</main>}
export function App(){return <LooperApp/>}
