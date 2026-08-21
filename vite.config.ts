import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'
import routeHandler from './api/routes'

export default defineConfig(({ mode }) => {
  Object.assign(process.env, loadEnv(mode, '.', ''))
  return {
    server: { host: '0.0.0.0' },
    plugins: [
      react(),
      {
        name: 'local-routes-api',
        configureServer(server) {
          server.middlewares.use('/api/routes', (request, response) => {
            const req = request as unknown as { method?: string; headers: Record<string, string | string[] | undefined>; on: (event: string, listener: (chunk?: Uint8Array) => void) => void }
            if (req.method !== 'POST') { response.statusCode = 405; response.end(JSON.stringify({ error: 'Method not allowed' })); return }
            let raw = ''
            req.on('data', chunk => { raw += new TextDecoder().decode(chunk) })
            req.on('end', () => {
              let body: unknown
              try { body = JSON.parse(raw) } catch { response.statusCode = 400; response.end(JSON.stringify({ error: 'Send a valid route request.' })); return }
              const apiResponse = {
                status(code: number) { response.statusCode = code; return apiResponse },
                json(payload: unknown) { response.setHeader('Content-Type', 'application/json'); response.end(JSON.stringify(payload)) },
              }
              void routeHandler({ method: req.method, headers: req.headers, body: body as never }, apiResponse).catch(() => {
                response.statusCode = 500
                response.end(JSON.stringify({ error: 'Route service is unavailable. Please try again.' }))
              })
            })
          })
        },
      },
    ],
  }
})
