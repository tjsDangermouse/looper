import type { Turn } from './lib'
// Inline so the UI has no icon-font or sprite dependency, and every glyph
// inherits currentColor from the control it sits in.
const base = { fill: 'none', stroke: 'currentColor', strokeWidth: 2, strokeLinecap: 'round', strokeLinejoin: 'round' } as const

export const LoopIcon = ({ size = 20 }: { size?: number }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true" {...base}>
    <path d="M3.5 9a8.5 8.5 0 0 1 14.2-3.2L21 9" /><path d="M20.5 15a8.5 8.5 0 0 1-14.2 3.2L3 15" />
    <path d="M21 4.5V9h-4.5" /><path d="M3 19.5V15h4.5" />
  </svg>
)

export const WalkIcon = ({ size = 18 }: { size?: number }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true" fill="currentColor">
    <path d="M13.5 5.5c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zM9.8 8.9 7 23h2.1l1.8-8 2.1 2v6h2v-7.5l-2.1-2 .6-3C14.8 12 16.8 13 19 13v-2c-1.9 0-3.5-1-4.3-2.4l-1-1.6c-.4-.6-1-1-1.7-1-.3 0-.5.1-.8.1L6 8.3V13h2V9.6l1.8-.7" />
  </svg>
)

export const ClockIcon = ({ size = 18 }: { size?: number }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true" {...base}>
    <circle cx="12" cy="12" r="8.5" /><path d="M12 7.5V12l3 1.8" />
  </svg>
)

export const LocateIcon = ({ size = 22 }: { size?: number }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true" fill="currentColor">
    <path d="M20.6 3.4 4.1 10.2c-1 .4-.9 1.9.2 2.1l6.3 1.3 1.3 6.3c.2 1.1 1.7 1.2 2.1.2l6.8-16.5c.3-.8-.5-1.5-1.2-1.2z" />
  </svg>
)

export const CloseIcon = ({ size = 20 }: { size?: number }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true" {...base}>
    <path d="M6 6l12 12M18 6L6 18" />
  </svg>
)

export const SoundOnIcon = ({ size = 20 }: { size?: number }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true" {...base}>
    <path d="M4 9.5h3.2L12 5.5v13l-4.8-4H4z" /><path d="M15.8 9a4.2 4.2 0 0 1 0 6" /><path d="M18.4 6.4a7.8 7.8 0 0 1 0 11.2" />
  </svg>
)

export const SoundOffIcon = ({ size = 20 }: { size?: number }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true" {...base}>
    <path d="M4 9.5h3.2L12 5.5v13l-4.8-4H4z" /><path d="M16.5 9.5l4 5M20.5 9.5l-4 5" />
  </svg>
)

export const CompassIcon = ({ size = 19 }: { size?: number }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true" {...base}>
    <circle cx="12" cy="12" r="9" /><path d="M15.6 8.4 13.7 13.7 8.4 15.6 10.3 10.3z" fill="currentColor" />
  </svg>
)

export const CheckIcon = ({ size = 18 }: { size?: number }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true" {...base} strokeWidth={2.6}>
    <path d="M4.5 12.5 9.5 17.5 19.5 6.5" />
  </svg>
)

export const ReverseIcon = ({ size = 20 }: { size?: number }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true" {...base}>
    <path d="M3 7h14" /><path d="M13 3l4 4-4 4" />
    <path d="M21 17H7" /><path d="M11 13l-4 4 4 4" />
  </svg>
)

// The turn arrow is drawn rather than listed: a stem, a bend through the angle
// of the turn, and a head on the straight run out of it. One shape covers
// slight, square and sharp on either side, so the glyph matches the turn being
// called out. Sharp turns bend later and reach further, so the head comes down
// clear of the stem instead of merging with it.
const ANGLES: Record<Turn, number> = { straight: 0, 'slight-right': 45, right: 90, 'sharp-right': 135, 'slight-left': -45, left: -90, 'sharp-left': -135, 'u-turn': 180, arrive: 0 }
const at = (x: number, y: number) => `${x.toFixed(1)} ${y.toFixed(1)}`
function turnPaths(degrees: number) {
  const sharp = Math.abs(degrees) > 90, bendY = sharp ? 8 : 9, bend = sharp ? 5.5 : 4, run = sharp ? 3.5 : 2.5
  const radians = degrees * Math.PI / 180, dx = Math.sin(radians), dy = -Math.cos(radians)
  const mx = 12 + dx * bend, my = bendY + dy * bend, ex = mx + dx * run, ey = my + dy * run
  return {
    stem: degrees ? `M12 21V13.5 Q12 ${bendY} ${at(mx, my)} L${at(ex, ey)}` : `M12 21V${(bendY - bend - run).toFixed(1)}`,
    head: `M${at(ex + dy * 2.2 - dx * 2.2, ey - dx * 2.2 - dy * 2.2)} L${at(ex, ey)} L${at(ex - dy * 2.2 - dx * 2.2, ey + dx * 2.2 - dy * 2.2)}`,
  }
}
export const TurnIcon = ({ turn, size = 40 }: { turn: Turn; size?: number }) => {
  // A U-turn doubles back over its own stem, so it gets a bend of its own.
  const { stem, head } = turn === 'u-turn'
    ? { stem: 'M8.5 21V11.5a3.5 3.5 0 0 1 7 0V17', head: 'M12.6 14.4 15.5 17.4 18.4 14.4' }
    : turnPaths(ANGLES[turn])
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true" {...base} strokeWidth={2.1}>
      <path d={stem} />
      {turn === 'arrive' ? <circle cx="12" cy="4.5" r="2.6" fill="currentColor" stroke="none" /> : <path d={head} />}
    </svg>
  )
}
