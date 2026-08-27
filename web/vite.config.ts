import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { mapStyleEditorPlugin } from './dev/mapStyleBackend.ts'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

// The app talks only to Looper's own route service. In development that
// service runs in Docker (or via `npm run dev` inside ../route-service)
// and Vite proxies /v1 to it, so the browser sees one origin and no CORS.
// In production VITE_LOOPER_API_BASE points at the deployed service.
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, '.', '')
  return {
    server: {
      host: '0.0.0.0',
      // Saving in the editor rewrites this source module. The editor already
      // keeps the saved catalogue in React state, so an HMR reload here is
      // both unnecessary and harmful: it can race Vite's optimized React
      // dependency URLs and leave the page on a 504 Outdated Optimize Dep.
      watch: { ignored: ['**/src/mapStyleConfig.generated.ts'] },
      proxy: {
        '/v1': {
          target: env.LOOPER_API_URL || `http://localhost:${env.ROUTE_SERVICE_PORT || 8988}`,
          changeOrigin: true,
        },
      },
    },
    plugins: [react(), mapStyleEditorPlugin(repositoryRoot)],
  }
})
