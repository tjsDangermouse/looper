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
