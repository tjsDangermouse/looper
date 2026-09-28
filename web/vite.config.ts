import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { mapStyleEditorPlugin } from './dev/mapStyleBackend.ts'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

// This server exists only for the local iOS admin tools. The retired web app
// remains in src for now, but no route-service proxy or consumer app is mounted.
export default defineConfig(() => {
  return {
    server: {
      host: '0.0.0.0',
      // Saving in the editor rewrites this source module. The editor already
      // keeps the saved catalogue in React state, so an HMR reload here is
      // both unnecessary and harmful: it can race Vite's optimized React
      // dependency URLs and leave the page on a 504 Outdated Optimize Dep.
      watch: { ignored: ['**/src/mapStyleConfig.generated.ts'] },
    },
    plugins: [react(), mapStyleEditorPlugin(repositoryRoot)],
  }
})
