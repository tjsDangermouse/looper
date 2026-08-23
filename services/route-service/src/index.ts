import { config } from './config.js'
import { log } from './log.js'
import { createApp } from './server.js'

const server = createApp()
server.listen(config.port, () => {
  log('info', 'listening', { port: config.port, regions: ['isle-of-man', 'england'], profile: config.graphhopperProfile })
})

for (const signal of ['SIGTERM', 'SIGINT'] as const) {
  process.on(signal, () => {
    log('info', 'shutting-down', { signal })
    server.close(() => process.exit(0))
    setTimeout(() => process.exit(0), 5000).unref()
  })
}
