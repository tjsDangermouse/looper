import { createRoot } from 'react-dom/client'
import './styles.css'
import './mobile.css'
import { App } from './App'

if ('serviceWorker' in navigator) window.addEventListener('load', async () => {
  // updateViaCache:'none' keeps the browser's HTTP cache from serving a stale
  // sw.js, which would pin the app to an old build.
  const registration = await navigator.serviceWorker.register('/sw.js', { updateViaCache: 'none' })
  registration.update()
  // The new worker calls skipWaiting, so it takes control as soon as it is
  // installed; reload once at that point to swap in the new build.
  let reloading = false
  navigator.serviceWorker.addEventListener('controllerchange', () => {
    if (reloading || !navigator.serviceWorker.controller) return
    reloading = true
    window.location.reload()
  })
  // Catch deploys that land while the app is open in the background.
  document.addEventListener('visibilitychange', () => { if (!document.hidden) registration.update() })
})
createRoot(document.getElementById('root')!).render(<App />)
