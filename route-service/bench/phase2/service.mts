/**
 * Starting and stopping a route service, safely enough to do it fifty times.
 *
 * Two things here are not incidental. The child is started in its own process
 * group and killed by group: `npx tsx` is three processes deep, and killing
 * only the one we spawned orphans a live service that keeps holding the port
 * and — worse — keeps writing to the trace file the next run is about to
 * treat as its own. That failure is silent and it corrupts the corpus, so the
 * port is also asserted free before starting and after stopping.
 */
import { spawn } from 'node:child_process'
import { createConnection } from 'node:net'
import { START_SERVICE_ENV } from './fixtures.mjs'

const ROOT = new URL('../..', import.meta.url).pathname
export const sleep = (ms: number) => new Promise(r => setTimeout(r, ms))

const portInUse = (port: number) => new Promise<boolean>(resolve => {
  const socket = createConnection({ port, host: '127.0.0.1' })
  socket.on('connect', () => { socket.destroy(); resolve(true) })
  socket.on('error', () => resolve(false))
})

export type Service = { port: number; stop: () => Promise<void>; generate: (body: unknown) => Promise<{ wallMs: number; payload: any; headers: Headers }> }

export async function startService(port: number, env: Record<string, string>): Promise<Service> {
  if (await portInUse(port)) throw new Error(`port ${port} is already in use — a previous run is still alive`)
  const child = spawn('npx', ['tsx', 'src/index.ts'], {
    cwd: ROOT,
    detached: true,
    env: { ...process.env, ...START_SERVICE_ENV, ...env, PORT: String(port) },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  child.stderr.on('data', d => { const s = String(d); if (/error/i.test(s)) process.stderr.write(s) })

  const stop = async () => {
    try { process.kill(-child.pid!, 'SIGKILL') } catch { /* already gone */ }
    for (let i = 0; i < 40; i++) {
      if (!(await portInUse(port))) return
      await sleep(100)
    }
    throw new Error(`port ${port} never freed`)
  }

  for (let i = 0; i < 120; i++) {
    await sleep(500)
    try {
      if ((await fetch(`http://localhost:${port}/health`)).ok) {
        return {
          port,
          stop,
          generate: async (body: unknown) => {
            const began = Date.now()
            const response = await fetch(`http://localhost:${port}/v1/loops`, {
              method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
            })
            return { wallMs: Date.now() - began, payload: (await response.json()) as any, headers: response.headers }
          },
        }
      }
    } catch { /* not up yet */ }
  }
  await stop()
  throw new Error(`route service on :${port} never became healthy`)
}
