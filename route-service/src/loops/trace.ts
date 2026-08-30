import { AsyncLocalStorage } from 'node:async_hooks'

/**
 * Who asked for a call, and why.
 *
 * Phase 3A's trace says what each engine call carried and what it cost. It
 * cannot say which candidate paid for it, which leg of that candidate it
 * belonged to, or which earlier call it is a fix-up of — and those are exactly
 * the questions Phase 3B has to answer before it can remove a call rather than
 * merely make one cheaper.
 *
 * Threading a context object through `buildLoopIncrementally` →
 * `attemptLeg` → `routeLegAttempt` → `applyJoinPullback` → the router would
 * mean changing six signatures that have nothing else to do with tracing, and
 * would leave the waypoint builder — which calls back into the same routines
 * by a different path — silently unlabelled. An async context flows down every
 * path on its own, including the ones added later.
 *
 * Off unless `LOOPER_TRACE_FILE` is set: `enterX` is a no-op and the store is
 * never entered, so production pays one `AsyncLocalStorage.getStore()` per
 * call and nothing else.
 */

/** A leg's own scope: the base call, then the fix-ups that hang off it. */
export type AttemptScope = {
  /** The first ordinary call of this leg attempt. Fix-ups name it as parent. */
  parentCallId?: number
}

/** One step of a loop: every attempt at it, plus the join fix-up after it. */
export type LegScope = {
  /** The last ordinary leg call of this step, which a join-pullback follows. */
  lastLegCallId?: number
}

export type CallContext = {
  /** Which candidate is paying, stable across its whole build. */
  candidateId?: string
  /** How the candidate was generated: a ring bearing, a waypoint walk, a repair. */
  candidateKind?: string
  /** The corner-count wave this build belongs to, when the sweep is progressive. */
  wave?: number
  cornerCount?: number
  /** Which leg of the loop, 0-based; the closing leg is `cornerCount`. */
  legIndex?: number
  /** Which retry of that leg, 0-based. */
  legAttempt?: number
  /** Metres this leg was planned to cover; absent on a closing leg. */
  plannedMetres?: number
  legScope?: LegScope
  attemptScope?: AttemptScope
  candidateIndex?: number
  bearing?: number
  direction?: string
  targetScale?: number
  bearingShift?: number
  /** Facts the fix-up sites publish about why they are calling. */
  facts?: Record<string, unknown>
}

const storage = new AsyncLocalStorage<CallContext>()

/** Where a decision line is written. Set by metrics.ts, which owns the file. */
let sink: ((record: Record<string, unknown>) => void) | undefined
export const setTraceSink = (write: (record: Record<string, unknown>) => void): void => { sink = write }

export const tracingCalls = Boolean(process.env.LOOPER_TRACE_FILE)

export const callContext = (): CallContext | undefined => storage.getStore()

/** Run `body` under the current context extended by `patch`. */
export function withCallContext<T>(patch: CallContext, body: () => T): T {
  if (!tracingCalls) return body()
  return storage.run({ ...storage.getStore(), ...patch }, body)
}

/** A fresh leg scope for one step of a loop, spanning its retries and its join fix-up. */
export const withLegScope = <T>(patch: CallContext, body: () => T): T =>
  withCallContext({ ...patch, legScope: {} }, body)

/** A fresh attempt scope for one try at a leg, spanning its own fix-ups. */
export const withAttemptScope = <T>(patch: CallContext, body: () => T): T =>
  withCallContext({ ...patch, attemptScope: {} }, body)

/**
 * An attempt scope for a caller that routes legs directly rather than through
 * `attemptLeg` — the waypoint builders do — so their fix-ups find a parent too.
 * A no-op where one is already open, so the ring builder keeps its own labels.
 */
export const withImpliedAttemptScope = <T>(body: () => T): T => {
  if (!tracingCalls) return body()
  const store = storage.getStore()
  if (!store || store.attemptScope) return body()
  return withCallContext({ attemptScope: {} }, body)
}

/** Record something about *why* this call is being made, for the trace line. */
export function noteCall(facts: Record<string, unknown>): void {
  const store = storage.getStore()
  if (!store) return
  store.facts = { ...store.facts, ...facts }
}

/**
 * What the trace line should carry, and the bookkeeping that makes a call a
 * parent. Base leg calls claim the attempt scope; fix-ups inherit it.
 */
const BASE_PURPOSES = new Set(['leg', 'leg-relaxed', 'waypoint-leg', 'waypoint-direct'])

/** The labels a trace line carries, without the bookkeeping that produced them. */
function withoutScopes(store: CallContext): Record<string, unknown> {
  const plain: Record<string, unknown> = { ...store }
  delete plain.legScope
  delete plain.attemptScope
  delete plain.facts
  return plain
}

export function attributeCall(callId: number, purpose: string): Record<string, unknown> {
  const store = storage.getStore()
  if (!store) return {}
  if (BASE_PURPOSES.has(purpose)) {
    if (store.attemptScope && store.attemptScope.parentCallId === undefined) store.attemptScope.parentCallId = callId
    if (store.legScope) store.legScope.lastLegCallId = callId
  }
  const parent = purpose === 'join-pullback'
    ? store.legScope?.lastLegCallId
    : BASE_PURPOSES.has(purpose) ? undefined : store.attemptScope?.parentCallId
  const plain = withoutScopes(store)
  return { ...plain, ...(store.facts ?? {}), ...(parent === undefined || parent === callId ? {} : { parentCallId: parent }) }
}

/**
 * What a fix-up decided, and whether it kept the answer it paid for.
 *
 * Written as its own line rather than folded into the call's, because the
 * decision is only reached after the call has returned — and by then the
 * call's own line, written in its `finally`, has long since been flushed.
 */
export function traceDecision(kind: string, fields: Record<string, unknown>): void {
  if (!sink) return
  const store = storage.getStore()
  if (!store) return
  const plain = withoutScopes(store)
  sink({
    event: 'decision', kind, ...plain, ...(store.facts ?? {}), ...fields,
    anchorCallId: kind === 'join-pullback' ? store.legScope?.lastLegCallId : store.attemptScope?.parentCallId,
  })
}
