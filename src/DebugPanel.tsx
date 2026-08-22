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

// Every max/min here is the actual edge the route service will accept (see
// OVERRIDE_RANGES in the service's http/validate.ts), not a "sensible-looking"
// round number — a slider that stops short of the real edge is a slider that
// can never actually turn its rule off, whatever it looks like it's doing.
const SLIDERS:Slider[] = [
  { key:'minCompactness', label:'Roundness floor', min:0, max:1, step:0.01, default:0.20,
    hint:'How much ground the walk must enclose vs. a circle of the same length. Lower admits more zigzag-shaped loops; 0 turns this rule off.',
    ...quality('minCompactness') },
  { key:'maxSharedFraction', label:'Diversity cutoff', min:0, max:1, step:0.05, default:0.55,
    hint:'How much ground two offered loops may share before the second is dropped as "the same walk". 1 turns this rule off.',
    get:o=>o.maxSharedFraction, set:(o,v)=>({ ...o, maxSharedFraction:v }) },
  { key:'maxUTurns', label:'U-turns allowed', min:0, max:10, step:1, default:1,
    hint:'How many genuine turn-arounds a walk may have before it is rejected. 10 is effectively no limit.',
    ...quality('maxUTurns') },
  { key:'maxLegShare', label:'Longest leg share', min:0, max:1, step:0.01, default:0.45,
    hint:'How much of the whole walk one leg of the ring may be, before it reads as a trudge with three corners rather than a loop. 1 turns this rule off.',
    ...quality('maxLegShare') },
  { key:'minLegShare', label:'Shortest leg share', min:0, max:1, step:0.01, default:0.08,
    hint:'How little of the whole walk one of the two outer-ring legs may be. 0 turns this rule off.',
    ...quality('minLegShare') },
  { key:'minBacktrackMetres', label:'Backtrack minimum (m)', min:0, max:3000, step:50, default:500,
    hint:'A short doubled-back stretch out in the walk reads as a dead end given up on, so it is always rejected. A stretch at least this long is judged a real feature — a pier, a promenade — instead, however long it runs. 0 turns this rule off.',
    ...quality('minBacktrackMetres') },
  { key:'maxStartStubMetres', label:'Doorstep stub floor (m)', min:0, max:3000, step:50, default:150,
    hint:'How far the walk may go out and back along the same street right at the start, before the loop proper begins.',
    ...quality('maxStartStubMetres') },
  { key:'startStubShare', label:'Doorstep stub share', min:0, max:1, step:0.01, default:0.04,
    hint:'The doorstep stub allowed as a fraction of the whole walk’s length, past the flat floor above. 1 turns this rule off.',
    ...quality('startStubShare') },
  { key:'maxRepeatedFraction', label:'Repeated ground', min:0, max:1, step:0.01, default:0.12,
    hint:'How much of the whole walk may run over ground it already covered. 1 turns this rule off.',
    ...quality('maxRepeatedFraction') },
  { key:'maxDistanceError', label:'Length tolerance', min:0, max:2, step:0.02, default:0.12,
    hint:'How far the walk may land from the length asked for, as a fraction of it. 2 is effectively no limit.',
    ...quality('maxDistanceError') },
  { key:'maxDurationError', label:'Time tolerance', min:0, max:2, step:0.02, default:0.15,
    hint:'How far the walk may land from the time asked for, in Time mode, as a fraction of it. 2 is effectively no limit.',
    ...quality('maxDurationError') },
  { key:'maxBoundingBoxRatio', label:'Elongation limit', min:1, max:30, step:0.5, default:4.5,
    hint:'How long and thin the walk’s footprint may be before it reads as a there-and-back rather than a loop. 30 is effectively no limit.',
    ...quality('maxBoundingBoxRatio') },
  { key:'joinTurnThresholdDegrees', label:'Dead-end angle (°)', min:0, max:180, step:5, default:150,
    hint:'How sharp a turn at a shared waypoint has to be before it is treated as a dead end and the waypoint is pulled back. 180 turns this rule off.',
    get:o=>o.joinTurnThresholdDegrees, set:(o,v)=>({ ...o, joinTurnThresholdDegrees:v }) },
  { key:'waypointPullbackScale', label:'Pullback amount', min:0.1, max:1, step:0.05, default:0.65,
    hint:'How far a dead-ending waypoint is pulled back toward the start, as a fraction of its original distance.',
    get:o=>o.waypointPullbackScale, set:(o,v)=>({ ...o, waypointPullbackScale:v }) },
  { key:'candidateCount', label:'Candidates tried', min:2, max:96, step:2, default:24,
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
export function DebugPanel({ overrides, onChange, diagnostics, busy }:{
  overrides:LoopOverrides; onChange:(o:LoopOverrides)=>void; diagnostics?:Diagnostics; busy:boolean
}) {
  const [open,setOpen]=useState(false)
  const changed = SLIDERS.filter(s => { const v = s.get(overrides); return v !== undefined && v !== s.default })
  return <>
    <button className={'debug-tab'+(changed.length?' changed':'')+(busy?' busy':'')} aria-expanded={open} aria-label={open?'Close tuning panel':'Open tuning panel'} onClick={()=>setOpen(o=>!o)}>{open?'✕':'⚙'}</button>
    <div className={'debug-scrim'+(open?' open':'')} onClick={()=>setOpen(false)} aria-hidden="true"/>
    <aside className={'debug-drawer'+(open?' open':'')} aria-hidden={!open}>
      <div className="debug-head">
        <p className="eyebrow">tuning panel · debug</p>
        {changed.length > 0 && <button className="text" onClick={() => onChange({})}>Reset {changed.length}</button>}
      </div>
      <p className="debug-status">{busy?'Searching…':'Idle'}</p>
      {diagnostics && <div className={'debug-diagnostics'+(busy?' stale':'')}>
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
