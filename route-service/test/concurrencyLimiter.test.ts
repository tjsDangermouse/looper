import { describe, expect, it } from 'vitest'
import { ConcurrencyLimiter, LimiterBusyError } from '../src/concurrencyLimiter.js'

function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>(r => { resolve = r })
  return { promise, resolve }
}

describe('ConcurrencyLimiter', () => {
  it('runs work up to the limit without queueing', async () => {
    const limiter = new ConcurrencyLimiter(2, 10)
    let active = 0
    let maxActive = 0
    const gate = deferred<void>()
    const run = () => limiter.run(async () => {
      active++
      maxActive = Math.max(maxActive, active)
      await gate.promise
      active--
    })
    const calls = [run(), run(), run()]
    // Give the first two a tick to start; the third must still be queued.
    await new Promise(r => setTimeout(r, 10))
    expect(active).toBe(2)
    gate.resolve()
    await Promise.all(calls)
    expect(maxActive).toBe(2)
  })

  it('queues beyond the limit and runs them once a slot frees up', async () => {
    const limiter = new ConcurrencyLimiter(1, 10)
    const order: number[] = []
    const gate = deferred<void>()
    const first = limiter.run(async () => { await gate.promise; order.push(1) })
    const second = limiter.run(async () => { order.push(2) })
    await new Promise(r => setTimeout(r, 10))
    gate.resolve()
    await Promise.all([first, second])
    expect(order).toEqual([1, 2])
  })

  it('refuses work once the queue is full', async () => {
    const limiter = new ConcurrencyLimiter(1, 1)
    const gate = deferred<void>()
    const running = limiter.run(() => gate.promise)
    const queued = limiter.run(async () => {})
    await expect(limiter.run(async () => {})).rejects.toBeInstanceOf(LimiterBusyError)
    gate.resolve()
    await Promise.all([running, queued])
  })

  it('drops a queued call when its signal aborts, without disturbing the running one', async () => {
    const limiter = new ConcurrencyLimiter(1, 10)
    const gate = deferred<void>()
    const controller = new AbortController()
    const running = limiter.run(() => gate.promise)
    const queued = limiter.run(async () => 'should not run', controller.signal)
    controller.abort()
    await expect(queued).rejects.toBeInstanceOf(LimiterBusyError)
    gate.resolve()
    await expect(running).resolves.toBeUndefined()
  })
})

/**
 * A permit that is taken and never given back is a service that answers
 * quickly for an hour and then answers nothing at all. Failures, abandoned
 * requests and full queues are the ordinary weather here, so each of them gets
 * checked rather than assumed.
 */
describe('never leaking a permit', () => {
  /** How many slots the limiter will still hand out, measured by using them. */
  const availableSlots = async (limiter: ConcurrencyLimiter, limit: number) => {
    const gate = deferred<void>()
    let running = 0
    const held = Array.from({ length: limit }, () => limiter.run(async () => {
      running++
      await gate.promise
    }))
    await new Promise(r => setTimeout(r, 10))
    const seen = running
    gate.resolve()
    await Promise.all(held)
    return seen
  }

  it('gives the permit back when the work throws', async () => {
    const limiter = new ConcurrencyLimiter(2, 10)
    for (let attempt = 0; attempt < 5; attempt++) {
      await expect(limiter.run(async () => { throw new Error('engine said no') })).rejects.toThrow('engine said no')
    }
    expect(await availableSlots(limiter, 2)).toBe(2)
  })

  it('gives it back when the work is a mixture of failures and successes', async () => {
    const limiter = new ConcurrencyLimiter(3, 20)
    const work = Array.from({ length: 30 }, (_, index) => limiter
      .run(async () => { if (index % 3 === 0) throw new Error('no') })
      .catch(() => undefined))
    await Promise.all(work)
    expect(await availableSlots(limiter, 3)).toBe(3)
  })

  it('gives it back when a waiting caller gives up', async () => {
    const limiter = new ConcurrencyLimiter(1, 10)
    const gate = deferred<void>()
    const holding = limiter.run(() => gate.promise)
    const controller = new AbortController()
    const waiting = limiter.run(async () => undefined, controller.signal)
    await new Promise(r => setTimeout(r, 5))
    controller.abort()
    await expect(waiting).rejects.toBeInstanceOf(LimiterBusyError)
    gate.resolve()
    await holding
    expect(await availableSlots(limiter, 1)).toBe(1)
  })

  it('gives it back when the queue was full and callers were turned away', async () => {
    const limiter = new ConcurrencyLimiter(1, 1)
    const gate = deferred<void>()
    const holding = limiter.run(() => gate.promise)
    const queued = limiter.run(async () => undefined)
    for (let attempt = 0; attempt < 5; attempt++) {
      await expect(limiter.run(async () => undefined)).rejects.toBeInstanceOf(LimiterBusyError)
    }
    gate.resolve()
    await Promise.all([holding, queued])
    expect(await availableSlots(limiter, 1)).toBe(1)
  })

  it('leaves nobody waiting forever after a burst', async () => {
    const limiter = new ConcurrencyLimiter(4, 200)
    const settled = await Promise.allSettled(Array.from({ length: 200 }, (_, index) =>
      limiter.run(async () => {
        await new Promise(r => setTimeout(r, index % 3))
        if (index % 7 === 0) throw new Error('engine said no')
      })))
    expect(settled).toHaveLength(200)
    expect(settled.every(outcome => outcome.status === 'fulfilled' || outcome.status === 'rejected')).toBe(true)
    expect(await availableSlots(limiter, 4)).toBe(4)
  })
})
