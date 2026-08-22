import { useState } from 'react'
import type { LoopOverrides, Diagnostics } from './lib'

/**
 * The route service's tuning knobs, live. Only reachable via ?debug=1: these
 * are internal thresholds, and turning one too far produces genuinely bad
 * routes, not a UI preference a normal walker should be able to stumble into.
 *
 * Each slider's default matches the route service's own default so "0 change"
 * here means "today's behaviour". Ranges are generous enough to find the wall,
 * not so generous a slider is mostly dead space.
 */
type Slider = { key:string; label:string; min:number; max:number; step:number; default:number; hint:string
  get:(o:LoopOverrides)=>number|undefined; set:(o:LoopOverrides,v:number)=>LoopOverrides }

const quality = (key:keyof NonNullable<LoopOverrides['quality']>) => ({
  get:(o:LoopOverrides)=>o.quality?.[key],
  set:(o:LoopOverrides,v:number):LoopOverrides=>({ ...o, quality:{ ...o.quality, [key]:v } }),
})

const SLIDERS:Slider[] = [
  { key:'minCompactness', label:'Roundness floor', min:0.05, max:0.40, step:0.01, default:0.20,
    hint:'How much ground the walk must enclose vs. a circle of the same length. Lower admits more zigzag-shaped loops.',
    ...quality('minCompactness') },
  { key:'maxSharedFraction', label:'Diversity cutoff', min:0.20, max:0.90, step:0.05, default:0.55,
    hint:'How much ground two offered loops may share before the second is dropped as "the same walk". Higher offers more loops that share a bottleneck street.',
    get:o=>o.maxSharedFraction, set:(o,v)=>({ ...o, maxSharedFraction:v }) },
  { key:'maxUTurns', label:'U-turns allowed', min:0, max:5, step:1, default:1,
    hint:'How many genuine turn-arounds a walk may have before it is rejected.',
    ...quality('maxUTurns') },
  { key:'maxOutAndBackSpurMetres', label:'Backtrack floor (m)', min:50, max:1000, step:25, default:150,
    hint:'The flat minimum of doubled-back ground allowed anywhere in the walk, before the length-proportional rule takes over.',
    ...quality('maxOutAndBackSpurMetres') },
  { key:'maxOutAndBackSpurShare', label:'Backtrack share', min:0, max:0.5, step:0.01, default:0.04,
    hint:'Doubled-back ground allowed as a fraction of the whole walk’s length.',
    ...quality('maxOutAndBackSpurShare') },
  { key:'maxStartStubMetres', label:'Doorstep stub floor (m)', min:50, max:1000, step:25, default:150,
    hint:'How far the walk may go out and back along the same street right at the start, before the loop proper begins.',
    ...quality('maxStartStubMetres') },
  { key:'maxRepeatedFraction', label:'Repeated ground', min:0, max:0.5, step:0.01, default:0.12,
    hint:'How much of the whole walk may run over ground it already covered.',
    ...quality('maxRepeatedFraction') },
  { key:'maxDistanceError', label:'Length tolerance', min:0, max:0.5, step:0.01, default:0.12,
    hint:'How far the walk may land from the length asked for.',
    ...quality('maxDistanceError') },
  { key:'maxBoundingBoxRatio', label:'Elongation limit', min:1, max:15, step:0.5, default:4.5,
    hint:'How long and thin the walk’s footprint may be before it reads as a there-and-back rather than a loop.',
    ...quality('maxBoundingBoxRatio') },
  { key:'joinTurnThresholdDegrees', label:'Dead-end angle (°)', min:90, max:180, step:5, default:150,
    hint:'How sharp a turn at a shared waypoint has to be before it is treated as a dead end and the waypoint is pulled back.',
    get:o=>o.joinTurnThresholdDegrees, set:(o,v)=>({ ...o, joinTurnThresholdDegrees:v }) },
  { key:'waypointPullbackScale', label:'Pullback amount', min:0.3, max:0.95, step:0.05, default:0.65,
    hint:'How far a dead-ending waypoint is pulled back toward the start, as a fraction of its original distance.',
    get:o=>o.waypointPullbackScale, set:(o,v)=>({ ...o, waypointPullbackScale:v }) },
  { key:'candidateCount', label:'Candidates tried', min:8, max:64, step:2, default:24,
    hint:'How many candidate shapes are routed and judged per request. More finds more, and costs more.',
    get:o=>o.candidateCount, set:(o,v)=>({ ...o, candidateCount:v }) },
]

/**
 * A slide-out drawer, not part of the route-picker sheet: the sheet's rows
 * are sized to fit a fixed budget with nothing to scroll, and twelve sliders
 * have no honest way to fit that budget alongside the map and the route
 * cards. Living on its own, fixed to the side and independent of whatever
 * screen is showing, it can open over the map without disturbing either.
 */
export function DebugPanel({ overrides, onChange, diagnostics }:{
  overrides:LoopOverrides; onChange:(o:LoopOverrides)=>void; diagnostics?:Diagnostics
}) {
  const [open,setOpen]=useState(false)
  const changed = SLIDERS.filter(s => { const v = s.get(overrides); return v !== undefined && v !== s.default })
  return <>
    <button className={'debug-tab'+(changed.length?' changed':'')} aria-expanded={open} aria-label={open?'Close tuning panel':'Open tuning panel'} onClick={()=>setOpen(o=>!o)}>{open?'✕':'⚙'}</button>
    <div className={'debug-scrim'+(open?' open':'')} onClick={()=>setOpen(false)} aria-hidden="true"/>
    <aside className={'debug-drawer'+(open?' open':'')} aria-hidden={!open}>
      <div className="debug-head">
        <p className="eyebrow">tuning panel · debug</p>
        {changed.length > 0 && <button className="text" onClick={() => onChange({})}>Reset {changed.length}</button>}
      </div>
      {diagnostics && <div className="debug-diagnostics">
        <p><b>{diagnostics.passed}</b>/{diagnostics.candidates} candidates passed cleanly · <b>{diagnostics.offered}</b> offered
          {diagnostics.retracing && <span className="debug-warn"> · falling back to retracing walks</span>}</p>
        {Object.keys(diagnostics.rejections).length > 0 && <p className="debug-rejections">
          {Object.entries(diagnostics.rejections).sort((a,b)=>b[1]-a[1]).map(([reason,count]) => `${reason} ×${count}`).join('  ·  ')}
        </p>}
      </div>}
      <div className="debug-sliders">
        {SLIDERS.map(s => {
          const value = s.get(overrides) ?? s.default
          return <label key={s.key} className="debug-slider" title={s.hint}>
            <div className="debug-slider-head"><span>{s.label}</span><span>{value}</span></div>
            <input type="range" min={s.min} max={s.max} step={s.step} value={value}
              onChange={e => onChange(s.set(overrides, Number(e.target.value)))} />
          </label>
        })}
      </div>
    </aside>
  </>
}
