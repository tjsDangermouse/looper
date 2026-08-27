import { promises as fs } from 'node:fs'
import path from 'node:path'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { paletteKeys, type MapStyleCatalogue } from '../src/mapStyleTypes.ts'

const endpoint = '/__looper-style-editor/config'
const hex = /^#[0-9a-f]{6}$/i
const styleID = /^[a-z][a-z0-9-]{0,31}$/

export function validateCatalogue(value: unknown): MapStyleCatalogue {
  if (!value || typeof value !== 'object') throw new Error('The style catalogue must be an object.')
  const candidate = value as Partial<MapStyleCatalogue>
  if (candidate.version !== 1) throw new Error('Unsupported style catalogue version.')
  if (!Array.isArray(candidate.styles) || candidate.styles.length < 1 || candidate.styles.length > 20) {
    throw new Error('Create between 1 and 20 custom map styles.')
  }
  const ids = new Set<string>()
  for (const style of candidate.styles) {
    if (!style || typeof style !== 'object') throw new Error('Every style must be an object.')
    if (!styleID.test(style.id)) throw new Error(`“${style.id || 'Untitled'}” needs a lowercase ID using letters, numbers and hyphens.`)
    if (ids.has(style.id) || style.id === 'default') throw new Error(`Style ID “${style.id}” must be unique.`)
    ids.add(style.id)
    if (typeof style.name !== 'string' || !style.name.trim() || style.name.trim().length > 40) {
      throw new Error(`Style “${style.id}” needs a name of 1–40 characters.`)
    }
    if (!style.palette || typeof style.palette !== 'object') throw new Error(`Style “${style.id}” has no palette.`)
    for (const key of paletteKeys) {
      if (!hex.test(style.palette[key])) throw new Error(`${style.name}: ${key} must be a six-digit hex colour.`)
    }
    const extra = Object.keys(style.palette).filter(key => !paletteKeys.includes(key as never))
    if (extra.length) throw new Error(`${style.name} contains unknown palette fields: ${extra.join(', ')}.`)
  }
  if (!Array.isArray(candidate.routeColours) || candidate.routeColours.length < 1 || candidate.routeColours.length > 8 || candidate.routeColours.some(colour => !hex.test(colour))) {
    throw new Error('Choose between 1 and 8 six-digit route colours.')
  }
  return {
    version: 1,
    styles: candidate.styles.map(style => ({ ...style, name: style.name.trim(), palette: { ...style.palette } })),
    routeColours: [...candidate.routeColours],
  }
}

const swiftString = (value: string) => `"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"`

export function webSource(config: MapStyleCatalogue) {
  return `// Generated from map-styles.json by the local map style editor. Do not edit by hand.\nimport type { CustomMapStyle } from './mapStyleTypes'\n\nexport const customMapStyles: CustomMapStyle[] = ${JSON.stringify(config.styles, null, 2)}\n\nexport const routeColours = ${JSON.stringify(config.routeColours)}\n`
}

export function swiftSource(config: MapStyleCatalogue) {
  const paletteProperties = paletteKeys.map(key => `    public let ${key}: String`).join('\n')
  const definitions = config.styles.map(style => `    MapStyleDefinition(\n        id: ${swiftString(style.id)},\n        name: ${swiftString(style.name)},\n        palette: MapStylePalette(\n${paletteKeys.map((key, index) => `            ${key}: ${swiftString(style.palette[key])}${index === paletteKeys.length - 1 ? '' : ','}`).join('\n')}\n        )\n    )`).join(',\n')
  return `// Generated from map-styles.json by the local map style editor. Do not edit by hand.\nimport Foundation\n\npublic struct MapStylePalette: Hashable, Sendable {\n${paletteProperties}\n}\n\npublic struct MapStyleDefinition: Hashable, Identifiable, Sendable {\n    public let id: String\n    public let name: String\n    public let palette: MapStylePalette\n}\n\npublic let customMapStyles: [MapStyleDefinition] = [\n${definitions}\n]\n\npublic let routeColours = ${JSON.stringify(config.routeColours).replaceAll('"', '\"')}\n`
}

export async function loadCatalogue(repositoryRoot: string) {
  return validateCatalogue(JSON.parse(await fs.readFile(path.join(repositoryRoot, 'map-styles.json'), 'utf8')))
}

async function replaceFile(file: string, contents: string) {
  const temporary = `${file}.saving`
  await fs.writeFile(temporary, contents, 'utf8')
  await fs.rename(temporary, file)
}

export async function saveCatalogue(repositoryRoot: string, input: unknown) {
  const config = validateCatalogue(input)
  const files = [
    [path.join(repositoryRoot, 'web/src/mapStyleConfig.generated.ts'), webSource(config)],
    [path.join(repositoryRoot, 'ios/LooperKit/Sources/LooperKit/MapStyleConfig.generated.swift'), swiftSource(config)],
    [path.join(repositoryRoot, 'map-styles.json'), `${JSON.stringify(config, null, 2)}\n`],
  ] as const
  for (const [file, contents] of files) await replaceFile(file, contents)
  return config
}

async function requestBody(request: IncomingMessage) {
  const chunks: Buffer[] = []
  let size = 0
  for await (const chunk of request) {
    const buffer = Buffer.from(chunk)
    size += buffer.length
    if (size > 256_000) throw new Error('The style catalogue is too large.')
    chunks.push(buffer)
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8'))
}

function json(response: ServerResponse, status: number, value: unknown) {
  response.statusCode = status
  response.setHeader('Content-Type', 'application/json')
  response.end(JSON.stringify(value))
}

export function mapStyleEditorPlugin(repositoryRoot: string) {
  return {
    name: 'looper-map-style-editor',
    configureServer(server: { middlewares: { use: (handler: (request: IncomingMessage, response: ServerResponse, next: () => void) => void) => void } }) {
      server.middlewares.use(async (request, response, next) => {
        if (request.url?.split('?')[0] !== endpoint) return next()
        const address = request.socket.remoteAddress ?? ''
        if (!['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(address)) {
          return json(response, 403, { error: 'The style editor can only write files from this computer.' })
        }
        try {
          if (request.method === 'GET') return json(response, 200, await loadCatalogue(repositoryRoot))
          if (request.method === 'PUT') return json(response, 200, await saveCatalogue(repositoryRoot, await requestBody(request)))
          json(response, 405, { error: 'Method not allowed.' })
        } catch (error) {
          json(response, error instanceof SyntaxError ? 400 : 422, { error: error instanceof Error ? error.message : 'Unable to save map styles.' })
        }
      })
    },
  }
}
