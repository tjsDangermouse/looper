import { describe, expect, it } from 'vitest'
import { estimateKmFromMinutes, haversine, kmToMiles, milesToKm, nearestProgress, nextTurn, previewPath, turnAnnouncement, type Route } from './lib'
const sample:Route={id:'a',name:'A',distanceMeters:200,durationSeconds:120,targetDifferencePercent:0,geometry:{type:'LineString',coordinates:[[0,0],[.001,0],[.002,0]]},steps:[{instruction:'Turn left',distanceMeters:100,durationSeconds:60},{instruction:'Arrive',distanceMeters:100,durationSeconds:60}]}
describe('walking maths',()=>{it('converts units',()=>expect(milesToKm(kmToMiles(5))).toBeCloseTo(5));it('estimates target',()=>expect(estimateKmFromMinutes(60)).toBe(5));it('measures distance',()=>expect(haversine([0,0],[.001,0])).toBeGreaterThan(100));it('calculates progress',()=>expect(nearestProgress([.001,0],sample.geometry.coordinates).index).toBe(1));it('selects next turn',()=>expect(nextTurn(sample,110)?.instruction).toBe('Arrive'));it('stays silent far from a turn',()=>expect(turnAnnouncement({index:0,instruction:'Turn left',distanceAway:900},'km')).toBeUndefined());it('leads in at distance',()=>expect(turnAnnouncement({index:0,instruction:'Turn left',distanceAway:300},'km')?.text).toBe('In four hundred metres, turn left'));it('speaks the bare turn at the corner',()=>expect(turnAnnouncement({index:0,instruction:'Turn left',distanceAway:10},'km')?.text).toBe('Turn left'));it('keys each band once',()=>expect(turnAnnouncement({index:2,instruction:'Turn left',distanceAway:80},'km')?.key).toBe('2:near'));it('speaks imperial',()=>expect(turnAnnouncement({index:0,instruction:'Turn left',distanceAway:80},'mi')?.text).toBe('In one hundred yards, turn left'))})
describe('route shape preview',()=>{
 // A true circle on the ground: at 54°N a degree of longitude is cos(54°) as long.
 const ring:[number,number][]=Array.from({length:33},(_,i)=>[.004/Math.cos(54*Math.PI/180)*Math.sin(i*Math.PI/16),54+.004*Math.cos(i*Math.PI/16)])
 it('draws nothing for an empty route',()=>expect(previewPath([])).toBe(''))
 it('starts with a move and then draws',()=>expect(previewPath(ring)).toMatch(/^M[\d. ]+L/))
 it('fits inside the box',()=>{for(const n of previewPath(ring).match(/[\d.]+/g)!){expect(Number(n)).toBeGreaterThanOrEqual(0);expect(Number(n)).toBeLessThanOrEqual(40)}})
 it('keeps a round loop round rather than squashing it at 54°N',()=>{
  const xs=previewPath(ring).split(/[ML]/).filter(Boolean).map(p=>Number(p.trim().split(' ')[0]))
  const ys=previewPath(ring).split(/[ML]/).filter(Boolean).map(p=>Number(p.trim().split(' ')[1]))
  expect((Math.max(...xs)-Math.min(...xs))/(Math.max(...ys)-Math.min(...ys))).toBeCloseTo(1,1)})
 it('thins a dense route down for a 40 px box',()=>{
  const dense:[number,number][]=Array.from({length:5000},(_,i)=>[i/1e6,54+i/1e6])
  expect(previewPath(dense).split('L').length).toBeLessThan(70)})
})
