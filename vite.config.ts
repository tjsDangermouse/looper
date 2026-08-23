import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'

// The app talks only to Looper's own route service. In development that
// service runs in Docker (or via `npm run dev` inside services/route-service)
// and Vite proxies /v1 to it, so the browser sees one origin and no CORS.
// In production VITE_LOOPER_API_BASE points at the deployed service.
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, '.', '')
  return {
    server: {
      host: '0.0.0.0',
      proxy: {
        '/v1': {
          target: env.LOOPER_API_URL || `http://localhost:${env.ROUTE_SERVICE_PORT || 8988}`,
          changeOrigin: true,
        },
      },
    },
    plugins: [react()],
  }
})
