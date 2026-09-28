import { createRoot } from 'react-dom/client'
import './styles.css'
import './mobile.css'
import './mapStyleEditor.css'
import './routeDiagnostics.css'
import './adminIndex.css'
import { AdminIndex } from './AdminIndex'
import { MapStyleEditor } from './MapStyleEditor'
import { RouteDiagnostics } from './RouteDiagnosticViewer'

const pathname = window.location.pathname.replace(/\/$/, '')
const editingMapStyle = pathname === '/map-style-editor'
const viewingRouteDiagnostics = pathname === '/route-diagnostics'

createRoot(document.getElementById('root')!).render(viewingRouteDiagnostics ? <RouteDiagnostics /> : editingMapStyle ? <MapStyleEditor /> : <AdminIndex />)
