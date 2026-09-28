import { useEffect } from 'react'
import { LoopIcon } from './icons'

const MapStyleMark = () => (
  <svg viewBox="0 0 48 48" aria-hidden="true">
    <path d="M8 12.5 19 8l10 4.5L40 8v27.5L29 40l-10-4.5L8 40Z" />
    <path d="M19 8v27.5M29 12.5V40" />
    <path className="admin-mark-accent" d="m12 29 5-6 5 3 6-8 7 5" />
  </svg>
)

const RouteEvidenceMark = () => (
  <svg viewBox="0 0 48 48" aria-hidden="true">
    <path d="M11 37c1-10 5-15 12-15 8 0 5-11 14-11" />
    <circle cx="11" cy="37" r="3" />
    <circle cx="37" cy="11" r="3" />
    <path className="admin-mark-accent" d="M14 11h11M14 16h7M30 32h7M27 37h10" />
  </svg>
)

export function AdminIndex() {
  useEffect(() => {
    document.body.classList.add('admin-index-body')
    document.title = 'Looper admin'
    return () => document.body.classList.remove('admin-index-body')
  }, [])

  return <main className="admin-index">
    <div className="admin-contours" aria-hidden="true">
      <i /><i /><i /><i />
    </div>

    <header className="admin-index-header">
      <a className="admin-wordmark" href="/" aria-label="Looper admin home">
        <span><LoopIcon size={22} /></span>
        Looper
      </a>
      <p>iOS workshop</p>
    </header>

    <section className="admin-index-intro">
      <h1>Tools for the trail.</h1>
      <p>Maintain the maps that walkers see and inspect what happened when a route was followed.</p>
    </section>

    <nav className="admin-tool-list" aria-label="Admin tools">
      <a href="/map-style-editor" className="admin-tool admin-tool-style">
        <span className="admin-tool-mark"><MapStyleMark /></span>
        <span className="admin-tool-copy">
          <strong>Map style manager</strong>
          <span>Edit the shared map themes and route colours, then save them into the iOS app.</span>
        </span>
        <span className="admin-tool-action">Manage styles</span>
      </a>

      <a href="/route-diagnostics" className="admin-tool admin-tool-evidence">
        <span className="admin-tool-mark"><RouteEvidenceMark /></span>
        <span className="admin-tool-copy">
          <strong>Route evidence</strong>
          <span>Open an iOS navigation export to compare planned routes, GPS fixes and guidance.</span>
        </span>
        <span className="admin-tool-action">Inspect a route</span>
      </a>
    </nav>

    <footer>Local tools · files stay on this machine</footer>
  </main>
}
