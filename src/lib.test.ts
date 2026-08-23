import { describe, expect, it } from 'vitest'
import { estimateKmFromMinutes, haversine, requestLoops, kmToMiles, milesToKm, headingFrom, headingGap, nearestProgress, nextTurn, turnKind, tidySteps, mirrorTurn, type Point, reverseRoute, smoothHeading, turnAnnouncement, normaliseWalkingSteps, type Route } from './lib'
const sample:Route={id:'a',name:'A',distanceMeters:200,durationSeconds:120,targetDifferencePercent:0,geometry:{type:'LineString',coordinates:[[0,0],[.001,0],[.002,0]]},steps:[{instruction:'Head along Main Street',distanceMeters:100,durationSeconds:60,maneuver:11,road:'Main Street'},{instruction:'Turn left onto Quay Road',distanceMeters:100,durationSeconds:60,maneuver:0,road:'Quay Road'},{instruction:'Arrive',distanceMeters:0,durationSeconds:0,maneuver:10}]}
describe('walking maths',()=>{it('converts units',()=>expect(milesToKm(kmToMiles(5))).toBeCloseTo(5));it('estimates target',()=>expect(estimateKmFromMinutes(60)).toBe(5));it('measures distance',()=>expect(haversine([0,0],[.001,0])).toBeGreaterThan(100));it('calculates progress',()=>expect(nearestProgress([.001,0],sample.geometry.coordinates).index).toBe(1));it('measures how far along the walk has come',()=>expect(nearestProgress([.0015,0],sample.geometry.coordinates).distanceAlong).toBeCloseTo(haversine([0,0],[.0015,0]),0));it('stays on the loop it has already walked',()=>{const loop=[[0,0],[.001,0],[.001,.001],[0,0]] as Point[];expect(nearestProgress([.00001,.00001],loop,300).distanceAlong).toBeGreaterThan(300)});it('reads a numbered turn from ORS',()=>expect(turnKind({instruction:'Turn left',maneuver:0})).toBe('left'));it('reads a named turn from the loop service',()=>expect(turnKind({instruction:'Keep right',maneuver:'keep-right'})).toBe('slight-right'));it('falls back to the wording',()=>expect(turnKind({instruction:'Turn sharp left onto Quay Road'})).toBe('sharp-left'));it('knows the walk is over',()=>expect(turnKind(undefined)).toBe('arrive'));it('mirrors a turn',()=>expect(mirrorTurn('sharp-left')).toBe('sharp-right'));it('folds away a clip into a side road',()=>{const steps=tidySteps([{instruction:'Head along Main Street',distanceMeters:200,durationSeconds:150,road:'Main Street'},{instruction:'Turn right onto Mill Lane',distanceMeters:1,durationSeconds:1,road:'Mill Lane'},{instruction:'Turn left onto Main Street',distanceMeters:150,durationSeconds:110,road:'Main Street'},{instruction:'Turn left onto Quay Road',distanceMeters:90,durationSeconds:70,road:'Quay Road'},{instruction:'Arrive',distanceMeters:0,durationSeconds:0,maneuver:10}]);expect(steps.map(step=>step.instruction)).toEqual(['Head along Main Street','Turn left onto Quay Road','Arrive']);expect(steps.map(step=>step.distanceMeters)).toEqual([351,90,0])});it('never folds away arriving',()=>expect(tidySteps([{instruction:'Head along Main Street',distanceMeters:200,durationSeconds:150,road:'Main Street'},{instruction:'Arrive',distanceMeters:0,durationSeconds:0,maneuver:10}]).length).toBe(2));it('keeps a real turn between two short steps',()=>expect(tidySteps([{instruction:'Head along Main Street',distanceMeters:60,durationSeconds:40,road:'Main Street'},{instruction:'Turn left onto Quay Road',distanceMeters:40,durationSeconds:30,road:'Quay Road'}]).length).toBe(2));it('selects next turn',()=>expect(nextTurn(sample,110)?.instruction).toBe('Arrive'));it('calls the turn onto the road ahead, not the one underfoot',()=>{const ahead=nextTurn(sample,40);expect(ahead?.instruction).toBe('Turn left onto Quay Road');expect(ahead?.distanceAway).toBe(60)});it('never calls setting off a turn',()=>expect(nextTurn(sample,0)?.instruction).toBe('Turn left onto Quay Road'));it('runs out of turns at the end',()=>expect(nextTurn(sample,200)).toBeUndefined());it('stays silent far from a turn',()=>expect(turnAnnouncement({index:0,instruction:'Turn left',distanceAway:900},'km')).toBeUndefined());it('leads in at the distance actually left',()=>expect(turnAnnouncement({index:0,instruction:'Turn left',distanceAway:140},'km')?.text).toBe('In 150 metres, turn left'));it('calls a turn picked up part way into a band at its real distance',()=>expect(turnAnnouncement({index:0,instruction:'Turn left',distanceAway:45},'km')?.text).toBe('In 50 metres, turn left'));it('speaks the bare turn at the corner',()=>expect(turnAnnouncement({index:0,instruction:'Turn left',distanceAway:4},'km')?.text).toBe('Turn left'));it('keys each band once',()=>expect(turnAnnouncement({index:2,instruction:'Turn left',distanceAway:45},'km')?.key).toBe('2:near'));it('speaks imperial',()=>expect(turnAnnouncement({index:0,instruction:'Turn left',distanceAway:80},'mi')?.text).toBe('In 90 yards, turn left'));it('reverses the loop',()=>{const back=reverseRoute({...sample,steps:[{instruction:'Head along Main Street',distanceMeters:100,durationSeconds:60,maneuver:11,road:'Main Street'},{instruction:'Turn right onto Quay Road',distanceMeters:80,durationSeconds:50,maneuver:1,road:'Quay Road'},{instruction:'Arrive',distanceMeters:0,durationSeconds:0,maneuver:10}]});expect(back.geometry.coordinates[0]).toEqual([.002,0]);expect(back.steps.map(step=>step.instruction)).toEqual(['Head along Quay Road','Turn left onto Main Street','Arrive at your starting point']);expect(back.steps.map(step=>step.distanceMeters)).toEqual([80,100,0]);expect(back.steps.map(turnKind)).toEqual(['straight','left','arrive']);expect(back.reversed).toBe(true)});it('calls the reversed turn where the road actually forks',()=>{const back=reverseRoute({...sample,steps:[{instruction:'Head along Main Street',distanceMeters:100,durationSeconds:60,maneuver:11,road:'Main Street'},{instruction:'Turn right onto Quay Road',distanceMeters:80,durationSeconds:50,maneuver:1,road:'Quay Road'},{instruction:'Arrive',distanceMeters:0,durationSeconds:0,maneuver:10}]});expect(nextTurn(back,10)?.instruction).toBe('Turn left onto Main Street');expect(nextTurn(back,10)?.distanceAway).toBe(70)});it('reads an iOS compass heading',()=>expect(headingFrom({webkitCompassHeading:90})).toBe(90));it('adds the screen rotation',()=>expect(headingFrom({webkitCompassHeading:350},90)).toBe(80));it('flips an earth-framed alpha',()=>expect(headingFrom({alpha:90,absolute:true})).toBe(270));it('ignores a reading with no heading in it',()=>expect(headingFrom({alpha:null})).toBeUndefined());it('takes the first heading whole',()=>expect(smoothHeading(undefined,120)).toBe(120));it('eases the short way round zero',()=>expect(smoothHeading(350,10,.5)).toBe(0));it('measures the gap the short way',()=>expect(headingGap(350,10)).toBe(20))})

describe('road and path instructions',()=>{
 it('calls a shallow road-to-path transition a continuation',()=>{
  const route:Route={...sample,geometry:{type:'LineString',coordinates:[[0,0],[.0001,0],[.0002,.00001]]},steps:[
   {instruction:'Head along Annacur Lane',distanceMeters:11,durationSeconds:8,road:'Annacur Lane',roadClass:'residential',startIndex:0,endIndex:1},
   {instruction:'Turn right',distanceMeters:11,durationSeconds:8,maneuver:'turn-right',roadClass:'footway',startIndex:1,endIndex:2},
  ]}
  const step=normaliseWalkingSteps(route).steps[1]
  expect(step.instruction).toBe('Carry on across Annacur Lane onto the pathway')
  expect(turnKind(step)).toBe('straight')
 })
 it('calls a shallow path-to-road transition a continuation',()=>{
  const route:Route={...sample,geometry:{type:'LineString',coordinates:[[0,0],[.0001,0],[.0002,.00001]]},steps:[
   {instruction:'Head along path',distanceMeters:11,durationSeconds:8,roadClass:'path',startIndex:0,endIndex:1},
   {instruction:'Turn left onto Annacur Lane',distanceMeters:11,durationSeconds:8,maneuver:'turn-left',road:'Annacur Lane',roadClass:'residential',startIndex:1,endIndex:2},
  ]}
  expect(normaliseWalkingSteps(route).steps[1].instruction).toBe('Carry on from the pathway onto Annacur Lane')
 })
})

describe('asking Looper for loops',()=>{
 const start:[number,number]=[-4.4816,54.1506]
 const answer=(body:unknown,ok=true)=>{const calls:any[]=[];(globalThis as any).fetch=async(url:string,init:any)=>{calls.push({url,body:JSON.parse(init.body)});return{ok,json:async()=>body}};return calls}
 const route={id:'r1',label:'North loop',distanceMeters:4000,durationSeconds:2880,targetDifferencePercent:0,geometry:{type:'LineString',coordinates:[[0,0],[.001,0]]},steps:[],quality:{score:70,repeatedMeters:0,repeatedPercent:0,uTurnCount:0,compactness:.4}}

 it('sends the walker’s own numbers to Looper and nowhere else',async()=>{
  const calls=answer({routes:[]})
  await requestLoops({start,mode:'distance',distanceKm:4,unit:'km',variation:0})
  expect(calls[0].url).toBe('/v1/loops')
  expect(calls[0].body).toEqual({start:{lng:-4.4816,lat:54.1506},mode:'distance',distanceKm:4,units:'km',variation:0})
 })
 it('sends minutes in time mode and no distance',async()=>{
  const calls=answer({routes:[]})
  await requestLoops({start,mode:'time',durationMinutes:45,unit:'mi',variation:2})
  expect(calls[0].body).toEqual({start:{lng:-4.4816,lat:54.1506},mode:'time',durationMinutes:45,units:'mi',variation:2})
 })
 it('excludes the loops already offered when refreshing',async()=>{
  const calls=answer({routes:[]})
  await requestLoops({start,mode:'distance',distanceKm:4,unit:'km',variation:3,excludeRoutes:[route]})
  expect(calls[0].body.exclude).toEqual([[[0,0],[.001,0]]])
 })
 it('names each loop for the walker',async()=>{
  answer({routes:[route]})
  const {routes}=await requestLoops({start,mode:'distance',distanceKm:4,unit:'km',variation:0})
  expect(routes[0].name).toBe('North loop')
  expect(routes[0].geometry.coordinates).toHaveLength(2)
 })
 it('passes on the message when there is no clean loop',async()=>{
  answer({routes:[],warning:'We couldn’t find a clean loop of that length from here. Try a different distance or move the start point.'})
  const result=await requestLoops({start,mode:'distance',distanceKm:4,unit:'km',variation:0})
  expect(result.routes).toHaveLength(0)
  expect(result.warning).toMatch(/couldn’t find a clean loop/)
 })
 it('shows the service’s own words when it refuses',async()=>{
  answer({error:'Please wait a moment before finding more loops.'},false)
  await expect(requestLoops({start,mode:'distance',distanceKm:4,unit:'km',variation:0})).rejects.toThrow('Please wait a moment before finding more loops.')
 })
 it('says something plain when the answer is not readable',async()=>{
  (globalThis as any).fetch=async()=>({ok:false,json:async()=>{throw new Error('bad json')}})
  await expect(requestLoops({start,mode:'distance',distanceKm:4,unit:'km',variation:0})).rejects.toThrow('Routes are unavailable right now.')
 })
})
