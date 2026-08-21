import { createRoot } from 'react-dom/client'
import './styles.css'
import './mobile.css'
import { App } from './App'

if ('serviceWorker' in navigator) window.addEventListener('load', () => navigator.serviceWorker.register('/sw.js'))
createRoot(document.getElementById('root')!).render(<App />)
