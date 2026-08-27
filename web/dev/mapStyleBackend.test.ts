import { describe, expect, it } from 'vitest'
import catalogue from '../../map-styles.json'
import { swiftSource, validateCatalogue, webSource } from './mapStyleBackend'

describe('map style editor backend', () => {
  it('validates the repository catalogue', () => {
    expect(validateCatalogue(catalogue).styles[0].name).toBe('Looper')
  })

  it('rejects duplicate IDs and malformed colours', () => {
    const duplicate = { ...catalogue, styles: [...catalogue.styles, catalogue.styles[0]] }
    expect(() => validateCatalogue(duplicate)).toThrow('must be unique')
    const invalid = structuredClone(catalogue)
    invalid.styles[0].palette.park = 'green'
    expect(() => validateCatalogue(invalid)).toThrow('park must be')
  })

  it('generates both platform configurations', () => {
    const config = validateCatalogue(catalogue)
    expect(webSource(config)).toContain('export const customMapStyles')
    expect(webSource(config)).toContain('export const routeColours')
    expect(swiftSource(config)).toContain('public let customMapStyles')
    expect(swiftSource(config)).toContain(`park: "${config.styles[0].palette.park}"`)
    expect(swiftSource(config)).toContain(`public let routeColours = ${JSON.stringify(config.routeColours)}`)
  })
})
