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
  <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true" {...base}>
    <circle cx="13" cy="4" r="1.8" fill="currentColor" stroke="none" />
    <path d="M11 21l1.8-5.4L10 13.2V9l3.4-1.4 2.4 3.1 2.7 1.1" /><path d="M10 13.2 7.6 17" />
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
