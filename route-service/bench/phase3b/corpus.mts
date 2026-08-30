/**
 * One traced generation per fixture, read back.
 *
 * Two kinds of line share the file: a call, written in the router's `finally`,
 * and a decision, written where a fix-up or a candidate was judged. They are
 * separated here so no reader has to remember which fields belong to which.
 */
import { readFileSync } from 'node:fs'

const FIXTURES = ['douglas-3km', 'douglas-5km', 'onchan-5km', 'peel-5km', 'wp-one', 'wp-two']
const dir = new URL(process.env.CORPUS ? `${process.env.CORPUS}/` : '../phase3a/corpus/', import.meta.url)

export type Call = {
  fixture: string; callId: number; parentCallId?: number
  purpose: string; class: string; ms: number; areas: number
  candidateId?: string; candidateKind?: string; candidateIndex?: number
  bearing?: number; direction?: string; cornerCount?: number
  legIndex?: number; legAttempt?: number; plannedMetres?: number
  askMetres?: number; resultMetres?: number; visitedNodes?: number
  memo?: 'hit' | 'join' | 'miss'; modelId?: string
  trigger?: string; joinTurn?: number; moved?: number; fromStart?: number
  budgetMetres?: number; strongDistance?: number; straightLine?: number
  requestBytes?: number
}
export type Decision = {
  fixture: string; event: 'decision'; kind: string; kept?: boolean
  candidateId?: string; candidateKind?: string; candidateIndex?: number; legIndex?: number
  attempt?: number; planned?: number; got?: number; fitsBudget?: boolean
  shortBacktrack?: boolean; last?: boolean
  joinTurn?: number; redoneTurn?: number; spikeCleared?: boolean
  before?: number; after?: number; stillSpiked?: boolean
  outcome?: string; rejections?: string[]; distance?: number; target?: number
  quality?: number; repeatedPercent?: number; uTurns?: number
  distanceErrorFraction?: number; legs?: number; trigger?: string
}

export function load(): { calls: Call[]; decisions: Decision[] } {
  const calls: Call[] = []
  const decisions: Decision[] = []
  for (const fixture of FIXTURES) {
    for (const line of readFileSync(new URL(`${fixture}.jsonl`, dir), 'utf8').trim().split('\n')) {
      if (!line) continue
      const record = JSON.parse(line)
      if (record.event === 'decision') decisions.push({ ...record, fixture })
      else calls.push({ ...record, fixture })
    }
  }
  return { calls, decisions }
}

