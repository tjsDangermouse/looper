import { config } from './config.js'

/**
 * Logging.
 *
 * A walker's start point is their front door. It is never written to a log in
 * production; what gets recorded is how the request went, not where it was.
 * Outside production the coordinates are still rounded, to about a kilometre,
 * because a developer debugging loop shapes does not need the doorstep either.
 */
const LEVELS = { error: 0, warn: 1, info: 2, debug: 3 } as const
export type Level = keyof typeof LEVELS

const threshold = LEVELS[(config.logLevel as Level) in LEVELS ? (config.logLevel as Level) : 'info']

export function log(level: Level, message: string, fields: Record<string, unknown> = {}) {
  if (LEVELS[level] > threshold) return
  const line = { at: new Date().toISOString(), level, message, ...fields }
  const write = level === 'error' ? console.error : console.log
  write(JSON.stringify(line))
}

/** Coarse enough to be useless for tracking a person, precise enough to spot a region. */
export const coarseLocation = (lng: number, lat: number) =>
  config.isProduction ? undefined : `${lng.toFixed(2)},${lat.toFixed(2)}`
