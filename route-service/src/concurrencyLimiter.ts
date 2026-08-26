/**
 * A ceiling on concurrent work against one downstream engine, shared across
 * every request the process handles — not per-request, like the routing
 * concurrency in loops/generate.ts. One walker's "Find my loops" already
 * fans out to a few dozen routing calls; without something in front of the
 * engine, N walkers at once means N times that landing on the same small
 * GraphHopper container simultaneously.
 *
 * A queue beyond the concurrency limit absorbs a burst; a queue beyond
 * `maxQueue` is refused outright rather than left to grow — better to tell a
 * walker the engine is busy now than to make every queued request wait
 * longer and longer for an engine that is already behind.
 */
export class LimiterBusyError extends Error {
  constructor() {
    super('Routing engine is at capacity.')
    this.name = 'LimiterBusyError'
  }
}

type Waiter = { resolve: () => void; reject: (error: Error) => void; onAbort?: () => void; signal?: AbortSignal }

export class ConcurrencyLimiter {
  private active = 0
  private readonly queue: Waiter[] = []

  constructor(private readonly limit: number, private readonly maxQueue: number) {}

  async run<T>(fn: () => Promise<T>, signal?: AbortSignal): Promise<T> {
    await this.acquire(signal)
    try {
      return await fn()
    } finally {
      this.release()
    }
  }

  private acquire(signal?: AbortSignal): Promise<void> {
    if (this.active < this.limit) {
      this.active++
      return Promise.resolve()
    }
    if (this.queue.length >= this.maxQueue) throw new LimiterBusyError()

    return new Promise<void>((resolve, reject) => {
      const waiter: Waiter = { resolve, reject, signal }
      if (signal) {
        waiter.onAbort = () => {
          const index = this.queue.indexOf(waiter)
          if (index === -1) return // already dequeued and running
          this.queue.splice(index, 1)
          reject(new LimiterBusyError())
        }
        signal.addEventListener('abort', waiter.onAbort, { once: true })
      }
      this.queue.push(waiter)
    })
  }

  private release(): void {
    const next = this.queue.shift()
    if (!next) {
      this.active--
      return
    }
    if (next.onAbort) next.signal?.removeEventListener('abort', next.onAbort)
    next.resolve() // hands the slot straight to the next waiter; active stays unchanged
  }
}
