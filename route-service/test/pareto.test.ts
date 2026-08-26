import { describe, expect, it } from 'vitest'
import { OBJECTIVE_EPSILON, dominates, paretoArchive, type Objectives } from '../src/loops/pareto.js'

const costs = (overrides: Partial<Objectives> = {}): Objectives => ({
  targetError: 0.05,
  repeatedFraction: 0.02,
  shapePenalty: 0.6,
  legImbalance: 0.2,
  manoeuvrePenalty: 0,
  ...overrides,
})

describe('when one candidate beats another outright', () => {
  it('beats it when it is better on one count and no worse on the rest', () => {
    expect(dominates(costs({ targetError: 0.01 }), costs())).toBe(true)
    expect(dominates(costs(), costs({ targetError: 0.01 }))).toBe(false)
  })

  it('does not beat it when the two have traded', () => {
    const closer = costs({ targetError: 0.01, shapePenalty: 0.8 })
    const tidier = costs({ targetError: 0.09, shapePenalty: 0.3 })
    expect(dominates(closer, tidier)).toBe(false)
    expect(dominates(tidier, closer)).toBe(false)
  })

  it('does not beat an identical candidate in either direction', () => {
    expect(dominates(costs(), costs())).toBe(false)
  })

  it('treats a difference too small to be a difference as a tie', () => {
    const hair = costs({ targetError: 0.05 - OBJECTIVE_EPSILON / 2 })
    expect(dominates(hair, costs())).toBe(false)
    expect(dominates(costs(), hair)).toBe(false)
  })

  it('needs every count to be at least as good, not most of them', () => {
    const mixed = costs({ targetError: 0.01, manoeuvrePenalty: 1 })
    expect(dominates(mixed, costs())).toBe(false)
  })
})

describe('the archive', () => {
  const item = (name: string, objectives: Partial<Objectives>, score: number) => ({ name, objectives: costs(objectives), score })
  const archive = (items: ReturnType<typeof item>[], limit = 12) =>
    paretoArchive(items, { limit, objectives: entry => entry.objectives, rank: entry => entry.score }).map(entry => entry.name)

  it('keeps whatever is best at something and drops what is beaten outright', () => {
    const kept = archive([
      item('closest', { targetError: 0.01 }, 70),
      item('tidiest', { shapePenalty: 0.1 }, 68),
      item('beaten', { targetError: 0.09, shapePenalty: 0.9, repeatedFraction: 0.1 }, 90),
    ])
    expect(kept).toEqual(['closest', 'tidiest'])
  })

  it('gives the same answer whatever order the candidates arrived in', () => {
    const items = [
      item('a', { targetError: 0.01 }, 70),
      item('b', { shapePenalty: 0.1 }, 80),
      item('c', { repeatedFraction: 0 }, 60),
      item('d', { targetError: 0.2, shapePenalty: 0.95, repeatedFraction: 0.3 }, 95),
    ]
    const forwards = archive(items)
    const backwards = archive([...items].reverse())
    expect([...backwards].sort()).toEqual([...forwards].sort())
  })

  it('never grows past its limit', () => {
    const many = Array.from({ length: 40 }, (_, index) =>
      item(`c${index}`, { targetError: index / 100, shapePenalty: (40 - index) / 100 }, index))
    expect(archive(many, 5)).toHaveLength(5)
  })

  it('drops the lowest-ranked first when it has to drop something', () => {
    const many = Array.from({ length: 6 }, (_, index) =>
      item(`c${index}`, { targetError: index / 10, shapePenalty: (6 - index) / 10 }, index))
    // Every one of these trades against every other, so all six are on the
    // front and the rank is the only thing that can decide.
    expect(archive(many, 2).sort()).toEqual(['c4', 'c5'])
  })

  it('breaks a rank tie by arrival, so it never depends on the sort being stable', () => {
    const tied = Array.from({ length: 4 }, (_, index) =>
      item(`c${index}`, { targetError: index / 10, shapePenalty: (4 - index) / 10 }, 50))
    expect(archive(tied, 2)).toEqual(['c0', 'c1'])
  })

  it('keeps the caller’s own order, because it is a filter and not a ranking', () => {
    const kept = archive([
      item('first', { targetError: 0.01 }, 10),
      item('second', { shapePenalty: 0.1 }, 90),
    ])
    expect(kept).toEqual(['first', 'second'])
  })

  it('has nothing to do with one candidate or none', () => {
    expect(archive([])).toEqual([])
    expect(archive([item('only', {}, 1)])).toEqual(['only'])
  })
})
